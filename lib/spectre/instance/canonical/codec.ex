defmodule Spectre.Instance.Canonical.Codec do
  @moduledoc false

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Section
  alias Spectre.Instance.Canonical.Sections
  alias Spectre.Instance.Canonical.Transition
  alias Spectre.Run.Value

  @format "spectre/instance-checkpoint"
  @checkpoint_version 2
  @max_json_bytes 8_000_000

  @checkpoint_keys ~w(
    format checkpoint_version state_schema_version revision sections journal applied_changes
  )
  @section_keys ~w(revision value)
  @applied_change_keys ~w(revision digest)
  @transition_keys ~w(
    schema_version id change_id snapshot_id status from_revision to_revision base_revision
    changed_sections correlation_id causation_id provenance metadata committed_at
  )

  @section_names %{
    "flow" => :flow,
    "work" => :work,
    "vigil" => :vigil,
    "directive" => :directive,
    "control" => :control,
    "correlations" => :correlations,
    "events" => :events,
    "activation" => :activation,
    "runs" => :runs,
    "lifecycles" => :lifecycles,
    "event_admissions" => :event_admissions,
    "event_quarantine" => :event_quarantine,
    "skill_states" => :skill_states
  }

  @spec encode(Canonical.t()) :: {:ok, map()} | {:error, term()}
  def encode(%Canonical{} = state) do
    with :ok <- Canonical.validate(state),
         {:ok, sections} <- encode_sections(state.sections),
         {:ok, journal} <- encode_journal(state.journal),
         {:ok, applied_changes} <- encode_applied_changes(state.applied_changes) do
      {:ok,
       %{
         "format" => @format,
         "checkpoint_version" => @checkpoint_version,
         "state_schema_version" => state.schema_version,
         "revision" => state.revision,
         "sections" => sections,
         "journal" => journal,
         "applied_changes" => applied_changes
       }}
    end
  end

  def encode(value), do: {:error, {:invalid_canonical_state, shape(value)}}

  @spec encode_json(Canonical.t()) :: {:ok, String.t()} | {:error, term()}
  def encode_json(%Canonical{} = state) do
    with {:ok, encoded} <- encode(state), do: Jason.encode(encoded)
  end

  @spec decode(String.t() | map()) :: {:ok, Canonical.t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    if byte_size(json) <= @max_json_bytes do
      with {:ok, decoded} <- Jason.decode(json), do: decode(decoded)
    else
      {:error, {:canonical_checkpoint_too_large, byte_size(json), @max_json_bytes}}
    end
  end

  def decode(checkpoint) when is_map(checkpoint) and not is_struct(checkpoint) do
    with {:ok, checkpoint_version} <- non_negative_integer(checkpoint, "checkpoint_version"),
         :ok <- checkpoint_version(checkpoint_version),
         @format <- Map.get(checkpoint, "format"),
         :ok <- exact_keys(checkpoint, @checkpoint_keys, :checkpoint),
         {:ok, state_version} <- non_negative_integer(checkpoint, "state_schema_version"),
         :ok <- state_schema_version(checkpoint_version, state_version),
         {:ok, revision} <- non_negative_integer(checkpoint, "revision"),
         {:ok, sections} <-
           decode_sections(Map.fetch!(checkpoint, "sections"), checkpoint_version),
         {:ok, journal} <- decode_journal(Map.fetch!(checkpoint, "journal")),
         {:ok, applied_changes} <-
           decode_applied_changes(Map.fetch!(checkpoint, "applied_changes")) do
      state = %Canonical{
        schema_version: 2,
        revision: revision,
        sections: sections,
        journal: journal,
        applied_changes: applied_changes
      }

      with :ok <- Canonical.validate(state), do: {:ok, state}
    else
      format when is_binary(format) ->
        {:error, {:unsupported_canonical_checkpoint_format, format}}

      {:error, _reason} = error ->
        error

      format ->
        {:error, {:invalid_canonical_checkpoint_format, format}}
    end
  end

  def decode(value), do: {:error, {:invalid_canonical_checkpoint, shape(value)}}

  @spec decode!(String.t() | map()) :: Canonical.t()
  def decode!(checkpoint) do
    case decode(checkpoint) do
      {:ok, state} ->
        state

      {:error, reason} ->
        raise ArgumentError, "invalid canonical Agent checkpoint: #{inspect(reason)}"
    end
  end

  @spec encode_sections(Sections.t()) :: {:ok, map()} | {:error, term()}
  defp encode_sections(%Sections{} = sections) do
    Enum.reduce_while(Sections.names(), {:ok, %{}}, fn name, {:ok, encoded} ->
      {:ok, section} = Sections.fetch(sections, name)

      case Value.encode(section.value) do
        {:ok, value} ->
          section = %{"revision" => section.revision, "value" => value}
          {:cont, {:ok, Map.put(encoded, section_name(name), section)}}

        {:error, reason} ->
          {:halt, {:error, {:canonical_section_encode_failed, name, reason}}}
      end
    end)
  end

  @spec decode_sections(term(), pos_integer()) :: {:ok, Sections.t()} | {:error, term()}
  defp decode_sections(sections, checkpoint_version)
       when is_map(sections) and not is_struct(sections) do
    section_names = section_names(checkpoint_version)
    expected = Map.keys(section_names)

    with :ok <- exact_keys(sections, expected, :sections) do
      Enum.reduce_while(sections, {:ok, %Sections{}}, fn
        {name, encoded}, {:ok, decoded} ->
          section_name = Map.fetch!(section_names, name)

          case decode_section(encoded, section_name) do
            {:ok, section} ->
              {:cont, {:ok, Sections.put(decoded, section_name, section)}}

            {:error, _reason} = error ->
              {:halt, error}
          end
      end)
    end
  end

  defp decode_sections(value, _checkpoint_version),
    do: {:error, {:invalid_canonical_sections, shape(value)}}

  @spec decode_section(term(), Sections.name()) :: {:ok, Section.t()} | {:error, term()}
  defp decode_section(section, name) when is_map(section) and not is_struct(section) do
    with :ok <- exact_keys(section, @section_keys, {:section, name}),
         {:ok, revision} <- non_negative_integer(section, "revision"),
         {:ok, value} <- decode_value(Map.fetch!(section, "value"), [:canonical, name]) do
      {:ok, %Section{revision: revision, value: value}}
    end
  end

  defp decode_section(value, name),
    do: {:error, {:invalid_canonical_section, name, shape(value)}}

  @spec encode_journal([Transition.t()]) :: {:ok, [map()]} | {:error, term()}
  defp encode_journal(journal) do
    encode_list(journal, &encode_transition/1)
  end

  @spec encode_transition(Transition.t()) :: {:ok, map()} | {:error, term()}
  defp encode_transition(%Transition{} = transition) do
    with {:ok, provenance} <- Value.encode(transition.provenance),
         {:ok, metadata} <- Value.encode(transition.metadata) do
      {:ok,
       %{
         "schema_version" => transition.schema_version,
         "id" => transition.id,
         "change_id" => transition.change_id,
         "snapshot_id" => transition.snapshot_id,
         "status" => "committed",
         "from_revision" => transition.from_revision,
         "to_revision" => transition.to_revision,
         "base_revision" => transition.base_revision,
         "changed_sections" => Enum.map(transition.changed_sections, &section_name/1),
         "correlation_id" => transition.correlation_id,
         "causation_id" => transition.causation_id,
         "provenance" => provenance,
         "metadata" => metadata,
         "committed_at" => transition.committed_at
       }}
    end
  end

  defp encode_transition(value),
    do: {:error, {:invalid_canonical_transition, shape(value)}}

  @spec decode_journal(term()) :: {:ok, [Transition.t()]} | {:error, term()}
  defp decode_journal(journal) when is_list(journal),
    do: decode_list(journal, &decode_transition/1)

  defp decode_journal(value), do: {:error, {:invalid_canonical_journal, shape(value)}}

  @spec decode_transition(term()) :: {:ok, Transition.t()} | {:error, term()}
  defp decode_transition(transition)
       when is_map(transition) and not is_struct(transition) do
    with :ok <- exact_keys(transition, @transition_keys, :transition),
         {:ok, schema_version} <- non_negative_integer(transition, "schema_version"),
         {:ok, id} <- non_empty_binary(transition, "id"),
         {:ok, change_id} <- non_empty_binary(transition, "change_id"),
         {:ok, snapshot_id} <- non_empty_binary(transition, "snapshot_id"),
         {:ok, status} <- transition_status(Map.fetch!(transition, "status")),
         {:ok, from_revision} <- non_negative_integer(transition, "from_revision"),
         {:ok, to_revision} <- non_negative_integer(transition, "to_revision"),
         {:ok, base_revision} <- non_negative_integer(transition, "base_revision"),
         {:ok, changed_sections} <-
           decode_section_names(Map.fetch!(transition, "changed_sections")),
         {:ok, correlation_id} <- non_empty_binary(transition, "correlation_id"),
         {:ok, causation_id} <- optional_binary(Map.fetch!(transition, "causation_id")),
         {:ok, provenance} <- decode_value(Map.fetch!(transition, "provenance"), [:provenance]),
         {:ok, metadata} <- decode_value(Map.fetch!(transition, "metadata"), [:metadata]),
         {:ok, committed_at} <- non_negative_integer(transition, "committed_at") do
      {:ok,
       %Transition{
         schema_version: schema_version,
         id: id,
         change_id: change_id,
         snapshot_id: snapshot_id,
         status: status,
         from_revision: from_revision,
         to_revision: to_revision,
         base_revision: base_revision,
         changed_sections: changed_sections,
         correlation_id: correlation_id,
         causation_id: causation_id,
         provenance: provenance,
         metadata: metadata,
         committed_at: committed_at
       }}
    end
  end

  defp decode_transition(value),
    do: {:error, {:invalid_canonical_transition, shape(value)}}

  @spec encode_applied_changes(map()) :: {:ok, map()} | {:error, term()}
  defp encode_applied_changes(changes) do
    {:ok,
     Map.new(changes, fn {id, change} ->
       {id, %{"revision" => change.revision, "digest" => change.digest}}
     end)}
  end

  @spec decode_applied_changes(term()) :: {:ok, map()} | {:error, term()}
  defp decode_applied_changes(changes)
       when is_map(changes) and not is_struct(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn
      {id, value}, {:ok, decoded} when is_binary(id) and id != "" ->
        with true <- is_map(value) and not is_struct(value),
             :ok <- exact_keys(value, @applied_change_keys, {:applied_change, id}),
             {:ok, revision} <- non_negative_integer(value, "revision"),
             {:ok, digest} <- non_empty_binary(value, "digest") do
          {:cont, {:ok, Map.put(decoded, id, %{revision: revision, digest: digest})}}
        else
          false -> {:halt, {:error, {:invalid_applied_canonical_change, id, shape(value)}}}
          {:error, _reason} = error -> {:halt, error}
        end

      {id, _value}, _decoded ->
        {:halt, {:error, {:invalid_applied_canonical_change_id, shape(id)}}}
    end)
  end

  defp decode_applied_changes(value),
    do: {:error, {:invalid_applied_canonical_changes, shape(value)}}

  @spec decode_value(term(), [term()]) :: {:ok, term()} | {:error, term()}
  defp decode_value(value, path) do
    with :ok <- Value.prepare(value),
         {:ok, decoded} <- Value.decode(value),
         :ok <- Value.validate(decoded, path) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:canonical_value_decode_failed, path, reason}}
    end
  end

  @spec decode_section_names(term()) :: {:ok, [Sections.name()]} | {:error, term()}
  defp decode_section_names(names) when is_list(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, decoded} ->
      case Map.fetch(@section_names, name) do
        {:ok, section_name} ->
          if section_name in decoded do
            {:halt, {:error, {:duplicate_canonical_transition_section, section_name}}}
          else
            {:cont, {:ok, [section_name | decoded]}}
          end

        :error ->
          {:halt, {:error, {:unknown_canonical_transition_section, name}}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp decode_section_names(value),
    do: {:error, {:invalid_canonical_transition_sections, shape(value)}}

  @spec exact_keys(map(), [String.t()], term()) :: :ok | {:error, term()}
  defp exact_keys(value, expected, scope) do
    keys = Map.keys(value)

    cond do
      Enum.any?(keys, &(not is_binary(&1))) ->
        {:error,
         {:invalid_canonical_checkpoint_key, scope, shape(Enum.find(keys, &(not is_binary(&1))))}}

      MapSet.new(keys) != MapSet.new(expected) ->
        {:error,
         {:invalid_canonical_checkpoint_fields, scope, Enum.sort(keys), Enum.sort(expected)}}

      true ->
        :ok
    end
  end

  @spec checkpoint_version(term()) :: :ok | {:error, term()}
  defp checkpoint_version(@checkpoint_version), do: :ok
  defp checkpoint_version(version), do: {:error, {:unsupported_canonical_checkpoint, version}}

  defp section_names(@checkpoint_version), do: @section_names

  defp state_schema_version(@checkpoint_version, 2), do: :ok

  defp state_schema_version(_checkpoint_version, version),
    do: {:error, {:unsupported_canonical_version, version}}

  @spec transition_status(term()) :: {:ok, :committed} | {:error, term()}
  defp transition_status("committed"), do: {:ok, :committed}
  defp transition_status(value), do: {:error, {:invalid_canonical_transition_status, value}}

  @spec non_negative_integer(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp non_negative_integer(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_canonical_checkpoint_integer, key, value}}
      :error -> {:error, {:missing_canonical_checkpoint_field, key}}
    end
  end

  @spec non_empty_binary(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp non_empty_binary(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_canonical_checkpoint_binary, key, shape(value)}}
      :error -> {:error, {:missing_canonical_checkpoint_field, key}}
    end
  end

  @spec optional_binary(term()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_binary(nil), do: {:ok, nil}
  defp optional_binary(value) when is_binary(value) and value != "", do: {:ok, value}

  defp optional_binary(value),
    do: {:error, {:invalid_canonical_checkpoint_optional_binary, shape(value)}}

  @spec encode_list(list(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  defp encode_list(values, encoder) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, encoded} ->
      case encoder.(value) do
        {:ok, value} -> {:cont, {:ok, [value | encoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, Enum.reverse(encoded)}
      {:error, _reason} = error -> error
    end
  end

  @spec decode_list(list(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  defp decode_list(values, decoder), do: encode_list(values, decoder)

  defp section_name(:flow), do: "flow"
  defp section_name(:work), do: "work"
  defp section_name(:vigil), do: "vigil"
  defp section_name(:directive), do: "directive"
  defp section_name(:control), do: "control"
  defp section_name(:correlations), do: "correlations"
  defp section_name(:events), do: "events"
  defp section_name(:activation), do: "activation"
  defp section_name(:runs), do: "runs"
  defp section_name(:lifecycles), do: "lifecycles"
  defp section_name(:event_admissions), do: "event_admissions"
  defp section_name(:event_quarantine), do: "event_quarantine"
  defp section_name(:skill_states), do: "skill_states"

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
