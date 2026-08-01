defmodule Spectre.Instance.Canonical.Snapshot do
  @moduledoc false

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Sections

  @schema_version 1

  defstruct schema_version: @schema_version,
            id: nil,
            base_revision: 0,
            sections: %{},
            section_revisions: %{},
            readable: [],
            writable: [],
            correlation_id: nil,
            causation_id: nil,
            issued_at: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          base_revision: non_neg_integer(),
          sections: %{optional(Sections.name()) => term()},
          section_revisions: %{optional(Sections.name()) => non_neg_integer()},
          readable: [Sections.name()],
          writable: [Sections.name()],
          correlation_id: String.t(),
          causation_id: String.t() | nil,
          issued_at: integer()
        }

  @spec new(Canonical.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%Canonical{} = state, opts) when is_list(opts) do
    with {:ok, readable} <- section_names(Keyword.get(opts, :read, []), :read),
         {:ok, writable} <- section_names(Keyword.get(opts, :write, []), :write),
         :ok <- ensure_writable_is_readable(readable, writable),
         {:ok, id} <- identifier(Keyword.get(opts, :id), :snapshot),
         {:ok, correlation_id} <-
           identifier(Keyword.get(opts, :correlation_id), :correlation),
         {:ok, causation_id} <- optional_identifier(Keyword.get(opts, :causation_id)) do
      selected = MapSet.new(readable)

      {sections, revisions} =
        Enum.reduce(Sections.names(), {%{}, %{}}, fn name, {values, revisions} ->
          if MapSet.member?(selected, name) do
            {:ok, section} = Sections.fetch(state.sections, name)

            {
              Map.put(values, name, section.value),
              Map.put(revisions, name, section.revision)
            }
          else
            {values, revisions}
          end
        end)

      {:ok,
       %__MODULE__{
         id: id,
         base_revision: state.revision,
         sections: sections,
         section_revisions: revisions,
         readable: readable,
         writable: writable,
         correlation_id: correlation_id,
         causation_id: causation_id,
         issued_at: System.system_time(:millisecond)
       }}
    end
  end

  def new(%Canonical{}, opts), do: {:error, {:invalid_snapshot_options, shape(opts)}}

  @spec fetch(t(), Sections.name()) :: {:ok, term()} | {:error, term()}
  def fetch(%__MODULE__{} = snapshot, name) do
    if name in snapshot.readable do
      Map.fetch(snapshot.sections, name)
    else
      {:error, {:snapshot_section_not_readable, name}}
    end
  end

  @spec writable?(t(), term()) :: boolean()
  def writable?(%__MODULE__{writable: writable}, name), do: name in writable

  @spec read_only?(t()) :: boolean()
  def read_only?(%__MODULE__{writable: writable}), do: writable == []

  @spec section_names(term(), :read | :write) ::
          {:ok, [Sections.name()]} | {:error, term()}
  defp section_names(names, mode) when is_list(names) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, normalized} ->
      cond do
        not Sections.valid_name?(name) ->
          {:halt, {:error, {:unknown_snapshot_section, mode, name}}}

        name in normalized ->
          {:halt, {:error, {:duplicate_snapshot_section, mode, name}}}

        true ->
          {:cont, {:ok, [name | normalized]}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp section_names(names, mode), do: {:error, {:invalid_snapshot_sections, mode, shape(names)}}

  @spec ensure_writable_is_readable([Sections.name()], [Sections.name()]) ::
          :ok | {:error, term()}
  defp ensure_writable_is_readable(readable, writable) do
    case Enum.find(writable, &(&1 not in readable)) do
      nil -> :ok
      name -> {:error, {:snapshot_write_without_read, name}}
    end
  end

  @spec identifier(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp identifier(nil, _kind), do: {:ok, Spectre.Identity.uuid7()}
  defp identifier(value, _kind) when is_binary(value) and value != "", do: {:ok, value}
  defp identifier(value, kind), do: {:error, {:invalid_snapshot_identifier, kind, shape(value)}}

  @spec optional_identifier(term()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_identifier(nil), do: {:ok, nil}
  defp optional_identifier(value) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_identifier(value), do: {:error, {:invalid_snapshot_causation_id, shape(value)}}

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
