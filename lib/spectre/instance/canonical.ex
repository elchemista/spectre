defmodule Spectre.Instance.Canonical do
  @moduledoc false

  alias Spectre.Instance.Canonical.Change
  alias Spectre.Instance.Canonical.Section
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Instance.Canonical.Snapshot
  alias Spectre.Instance.Canonical.Transition
  alias Spectre.Run.Value

  @schema_version 1
  @journal_limit 512
  @applied_change_limit 1_024

  defstruct schema_version: @schema_version,
            revision: 0,
            sections: %Sections{},
            journal: [],
            applied_changes: %{}

  @type applied_change :: %{
          required(:revision) => non_neg_integer(),
          required(:digest) => binary()
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          revision: non_neg_integer(),
          sections: Sections.t(),
          journal: [Transition.t()],
          applied_changes: %{optional(String.t()) => applied_change()}
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(initial) when is_list(initial) do
    if Keyword.keyword?(initial) do
      new(Map.new(initial))
    else
      {:error, {:invalid_canonical_initial_sections, :list}}
    end
  end

  def new(initial) when is_map(initial) and not is_struct(initial) do
    Enum.reduce_while(initial, {:ok, new()}, fn {name, value}, {:ok, state} ->
      with true <- Sections.valid_name?(name),
           :ok <- validate_portable(value, [:canonical, name]) do
        {:ok, section} = Sections.fetch(state.sections, name)
        sections = Sections.put(state.sections, name, %{section | value: value})
        {:cont, {:ok, %{state | sections: sections}}}
      else
        false -> {:halt, {:error, {:unknown_canonical_section, name}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def new(initial), do: {:error, {:invalid_canonical_initial_sections, shape(initial)}}

  @spec fetch(t(), Sections.name()) :: {:ok, term()} | {:error, term()}
  def fetch(%__MODULE__{sections: sections}, name) do
    case Sections.fetch(sections, name) do
      {:ok, section} -> {:ok, section.value}
      _invalid -> {:error, {:unknown_canonical_section, name}}
    end
  end

  @spec section_revision(t(), Sections.name()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def section_revision(%__MODULE__{sections: sections}, name) do
    case Sections.fetch(sections, name) do
      {:ok, section} -> {:ok, section.revision}
      _invalid -> {:error, {:unknown_canonical_section, name}}
    end
  end

  @spec snapshot(t(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def snapshot(%__MODULE__{} = state, opts), do: Snapshot.new(state, opts)

  @spec change(Snapshot.t(), map() | keyword(), keyword()) ::
          {:ok, Change.t()} | {:error, term()}
  def change(%Snapshot{} = snapshot, writes, opts \\ []),
    do: Change.new(snapshot, writes, opts)

  @spec commit(t(), Change.t()) :: {:ok, t(), Transition.t()} | {:error, term()}
  def commit(%__MODULE__{} = state, %Change{} = change) do
    with :ok <- validate(state),
         :ok <- validate_change(change),
         {:new, digest} <- change_status(state, change),
         :ok <- validate_base_revision(state, change),
         :ok <- validate_section_revisions(state, change) do
      next_revision = state.revision + 1

      sections =
        Enum.reduce(change.writes, state.sections, fn {name, value}, sections ->
          {:ok, section} = Sections.fetch(sections, name)
          Sections.put(sections, name, Section.replace(section, value, next_revision))
        end)

      transition = Transition.committed(change, state.revision, next_revision)

      applied_changes =
        state.applied_changes
        |> Map.put(change.id, %{
          revision: next_revision,
          digest: digest
        })
        |> trim_applied_changes()

      next = %{
        state
        | revision: next_revision,
          sections: sections,
          journal: Enum.take([transition | state.journal], @journal_limit),
          applied_changes: applied_changes
      }

      {:ok, next, transition}
    else
      {:duplicate, _revision} ->
        {:ok, state, Transition.duplicate(change, state.revision)}

      {:conflict, id} ->
        {:error, {:canonical_change_id_conflict, id}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = state) do
    with :ok <- validate_schema_version(state.schema_version),
         :ok <- validate_revision(state.revision, :canonical_revision),
         :ok <- validate_sections(state.sections, state.revision),
         :ok <- validate_journal(state.journal, state.revision) do
      validate_applied_changes(state.applied_changes, state.revision)
    end
  end

  @spec change_status(t(), Change.t()) ::
          {:new, binary()} | {:duplicate, non_neg_integer()} | {:conflict, String.t()}
  defp change_status(state, change) do
    digest = change_digest(change)

    case Map.fetch(state.applied_changes, change.id) do
      :error -> {:new, digest}
      {:ok, %{digest: ^digest, revision: revision}} -> {:duplicate, revision}
      {:ok, _different} -> {:conflict, change.id}
    end
  end

  @spec validate_change(Change.t()) :: :ok | {:error, term()}
  defp validate_change(%Change{} = change) do
    names = Map.keys(change.writes)

    cond do
      change.schema_version != 1 ->
        {:error, {:unsupported_canonical_change_version, change.schema_version}}

      not (is_binary(change.id) and change.id != "") ->
        {:error, :invalid_canonical_change_id}

      not (is_binary(change.snapshot_id) and change.snapshot_id != "") ->
        {:error, :invalid_canonical_snapshot_id}

      not (is_binary(change.correlation_id) and change.correlation_id != "") ->
        {:error, :invalid_canonical_correlation_id}

      not is_nil(change.causation_id) and
          not (is_binary(change.causation_id) and change.causation_id != "") ->
        {:error, :invalid_canonical_causation_id}

      not is_integer(change.base_revision) or change.base_revision < 0 ->
        {:error, {:invalid_canonical_base_revision, change.base_revision}}

      map_size(change.writes) == 0 ->
        {:error, :empty_canonical_change}

      Enum.any?(names, &(not Sections.valid_name?(&1))) ->
        {:error, {:unknown_canonical_section, Enum.find(names, &(not Sections.valid_name?(&1)))}}

      MapSet.new(names) != MapSet.new(Map.keys(change.section_revisions)) ->
        {:error, :canonical_change_revision_scope_mismatch}

      true ->
        with :ok <- validate_change_revisions(change.section_revisions),
             :ok <- validate_portable(change.writes, [:canonical, :writes]),
             :ok <- validate_plain_portable_map(change.provenance, :provenance) do
          validate_plain_portable_map(change.metadata, :metadata)
        end
    end
  end

  @spec validate_base_revision(t(), Change.t()) :: :ok | {:error, term()}
  defp validate_base_revision(state, change) do
    if change.base_revision <= state.revision do
      :ok
    else
      {:error, {:future_canonical_revision, change.base_revision, state.revision}}
    end
  end

  @spec validate_section_revisions(t(), Change.t()) :: :ok | {:error, term()}
  defp validate_section_revisions(state, change) do
    Enum.reduce_while(change.section_revisions, :ok, fn {name, expected}, :ok ->
      {:ok, section} = Sections.fetch(state.sections, name)

      if section.revision == expected do
        {:cont, :ok}
      else
        {:halt,
         {:error, {:stale_canonical_section, name, expected, section.revision, state.revision}}}
      end
    end)
  end

  @spec validate_sections(term(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_sections(%Sections{} = sections, canonical_revision) do
    Enum.reduce_while(Sections.names(), :ok, fn name, :ok ->
      case Sections.fetch(sections, name) do
        {:ok, %Section{revision: revision, value: value}}
        when is_integer(revision) and revision >= 0 and revision <= canonical_revision ->
          case validate_portable(value, [:canonical, name]) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        {:ok, %Section{revision: revision}} ->
          {:halt,
           {:error, {:invalid_canonical_section_revision, name, revision, canonical_revision}}}

        _invalid ->
          {:halt, {:error, {:invalid_canonical_section, name}}}
      end
    end)
  end

  defp validate_sections(value, _revision),
    do: {:error, {:invalid_canonical_sections, shape(value)}}

  @spec validate_journal(term(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_journal(journal, canonical_revision) when is_list(journal) do
    if length(journal) > @journal_limit do
      {:error, {:canonical_journal_too_large, length(journal), @journal_limit}}
    else
      with :ok <- validate_journal_entries(journal, canonical_revision) do
        validate_journal_order(journal)
      end
    end
  end

  defp validate_journal(value, _revision),
    do: {:error, {:invalid_canonical_journal, shape(value)}}

  @spec validate_transition(Transition.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_transition(%Transition{} = transition, canonical_revision) do
    cond do
      transition.schema_version != 1 ->
        {:error, {:unsupported_canonical_transition_version, transition.schema_version}}

      transition.status != :committed ->
        {:error, {:invalid_persisted_transition_status, transition.status}}

      not valid_binary?(transition.id) or not valid_binary?(transition.change_id) or
        not valid_binary?(transition.snapshot_id) or not valid_binary?(transition.correlation_id) ->
        {:error, :invalid_canonical_transition_identity}

      not is_nil(transition.causation_id) and not valid_binary?(transition.causation_id) ->
        {:error, :invalid_canonical_transition_causation}

      not is_integer(transition.from_revision) or transition.from_revision < 0 ->
        {:error, {:invalid_transition_revision, :from, transition.from_revision}}

      not is_integer(transition.to_revision) or
          transition.to_revision != transition.from_revision + 1 ->
        {:error, {:invalid_transition_revision, :to, transition.to_revision}}

      transition.to_revision > canonical_revision ->
        {:error, {:future_transition_revision, transition.to_revision, canonical_revision}}

      not is_integer(transition.base_revision) or transition.base_revision < 0 or
          transition.base_revision > transition.from_revision ->
        {:error, {:invalid_transition_revision, :base, transition.base_revision}}

      not is_list(transition.changed_sections) or
        transition.changed_sections == [] or
        Enum.any?(transition.changed_sections, &(not Sections.valid_name?(&1))) or
          Enum.uniq(transition.changed_sections) != transition.changed_sections ->
        {:error, :invalid_transition_sections}

      not is_integer(transition.committed_at) or transition.committed_at < 0 ->
        {:error, :invalid_canonical_transition_timestamp}

      true ->
        with :ok <- validate_plain_portable_map(transition.provenance, :provenance) do
          validate_plain_portable_map(transition.metadata, :metadata)
        end
    end
  end

  @spec validate_applied_changes(term(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_applied_changes(changes, canonical_revision)
       when is_map(changes) and not is_struct(changes) do
    if map_size(changes) > @applied_change_limit do
      {:error, {:applied_canonical_changes_too_large, map_size(changes), @applied_change_limit}}
    else
      Enum.reduce_while(changes, :ok, fn
        {id, %{revision: revision, digest: digest}}, :ok
        when is_binary(id) and id != "" and is_integer(revision) and revision > 0 and
               revision <= canonical_revision and is_binary(digest) and digest != "" ->
          {:cont, :ok}

        {id, value}, :ok ->
          {:halt, {:error, {:invalid_applied_canonical_change, id, shape(value)}}}
      end)
    end
  end

  defp validate_applied_changes(value, _revision),
    do: {:error, {:invalid_applied_canonical_changes, shape(value)}}

  @spec validate_change_revisions(map()) :: :ok | {:error, term()}
  defp validate_change_revisions(revisions) do
    Enum.reduce_while(revisions, :ok, fn
      {_name, revision}, :ok when is_integer(revision) and revision >= 0 ->
        {:cont, :ok}

      {name, revision}, :ok ->
        {:halt, {:error, {:invalid_change_section_revision, name, revision}}}
    end)
  end

  @spec validate_plain_portable_map(term(), atom()) :: :ok | {:error, term()}
  defp validate_plain_portable_map(value, field)
       when is_map(value) and not is_struct(value),
       do: validate_portable(value, [:canonical, field])

  defp validate_plain_portable_map(value, field),
    do: {:error, {:invalid_canonical_field, field, shape(value)}}

  @spec validate_schema_version(term()) :: :ok | {:error, term()}
  defp validate_schema_version(@schema_version), do: :ok
  defp validate_schema_version(version), do: {:error, {:unsupported_canonical_version, version}}

  @spec validate_revision(term(), atom()) :: :ok | {:error, term()}
  defp validate_revision(revision, _field) when is_integer(revision) and revision >= 0, do: :ok
  defp validate_revision(revision, field), do: {:error, {:invalid_revision, field, revision}}

  @spec validate_portable(term(), [term()]) :: :ok | {:error, term()}
  defp validate_portable(value, path) do
    case Value.validate(value, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_canonical_value, reason}}
    end
  end

  @spec change_digest(Change.t()) :: binary()
  defp change_digest(change) do
    {
      change.snapshot_id,
      change.base_revision,
      change.section_revisions,
      change.writes,
      change.correlation_id,
      change.causation_id,
      change.provenance,
      change.metadata
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp trim_applied_changes(changes) when map_size(changes) <= @applied_change_limit,
    do: changes

  defp trim_applied_changes(changes) do
    changes
    |> Enum.sort_by(fn {_id, value} -> value.revision end, :desc)
    |> Enum.take(@applied_change_limit)
    |> Map.new()
  end

  defp validate_journal_entries(journal, canonical_revision) do
    Enum.reduce_while(journal, :ok, fn
      %Transition{} = transition, :ok ->
        case validate_transition(transition, canonical_revision) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      value, :ok ->
        {:halt, {:error, {:invalid_canonical_transition, shape(value)}}}
    end)
  end

  defp validate_journal_order(journal) do
    ids = Enum.map(journal, & &1.id)
    change_ids = Enum.map(journal, & &1.change_id)
    revisions = Enum.map(journal, & &1.to_revision)

    cond do
      Enum.uniq(ids) != ids -> {:error, :duplicate_canonical_transition_id}
      Enum.uniq(change_ids) != change_ids -> {:error, :duplicate_canonical_transition_change_id}
      revisions != Enum.sort(revisions, :desc) -> {:error, :canonical_journal_out_of_order}
      Enum.uniq(revisions) != revisions -> {:error, :duplicate_canonical_transition_revision}
      true -> :ok
    end
  end

  defp valid_binary?(value), do: is_binary(value) and value != ""

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
