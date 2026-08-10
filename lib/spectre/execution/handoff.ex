defmodule Spectre.Execution.Handoff do
  @moduledoc """
  Typed Flow/Work exchange carried as portable data.

  A handoff names stable Flow or Work IDs and an exact Definition Ref. It
  cannot contain modules, callbacks or MFAs and does not start anything by
  itself. The host admits it through the appropriate runtime API.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref
  alias Spectre.Execution.Expression
  alias Spectre.Execution.Materialization

  @schema_version 1
  @kinds [:flow, :work]
  @fields [
    :schema_version,
    :id,
    :definition_ref,
    :source,
    :target,
    :input,
    :parent_loop_id,
    :correlation_id,
    :causation_id,
    :provenance,
    :metadata,
    :digest
  ]

  @enforce_keys [
    :id,
    :definition_ref,
    :source,
    :target,
    :input,
    :correlation_id,
    :provenance,
    :metadata,
    :digest
  ]
  defstruct schema_version: @schema_version,
            id: nil,
            definition_ref: nil,
            source: nil,
            target: nil,
            input: nil,
            parent_loop_id: nil,
            correlation_id: nil,
            causation_id: nil,
            provenance: %{},
            metadata: %{},
            digest: nil

  @type endpoint :: %{required(:kind) => :flow | :work, required(:ref) => String.t()}
  @type t :: %__MODULE__{}

  @doc "Builds a closed typed handoff."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = handoff), do: handoff |> to_data() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_execution_handoff, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- reject_ambiguous_keys(attrs, @fields),
         attrs <- atomize(attrs, @fields),
         :ok <- exact_keys(attrs),
         :ok <- schema(Map.get(attrs, :schema_version, @schema_version)),
         {:ok, definition_ref} <- definition_ref(Map.get(attrs, :definition_ref)),
         {:ok, source} <- endpoint(Map.get(attrs, :source), :source),
         {:ok, target} <- endpoint(Map.get(attrs, :target), :target),
         :ok <- distinct_endpoints(source, target),
         {:ok, input} <- closed_input(Map.get(attrs, :input)),
         {:ok, parent_loop_id} <- optional_id(Map.get(attrs, :parent_loop_id), :parent_loop_id),
         {:ok, causation_id} <- optional_id(Map.get(attrs, :causation_id), :causation_id),
         {:ok, provenance} <- portable_map(Map.get(attrs, :provenance, %{}), :provenance),
         {:ok, metadata} <- portable_map(Map.get(attrs, :metadata, %{}), :metadata) do
      identity = %{
        schema_version: @schema_version,
        definition_ref: definition_ref,
        source: source,
        target: target,
        input_evidence_digest: Value.digest!(input),
        parent_loop_id: parent_loop_id,
        causation_id: causation_id,
        provenance: provenance,
        metadata: metadata
      }

      derived = derived_id(identity)

      with {:ok, id} <- authored_or_derived_id(Map.get(attrs, :id), derived),
           {:ok, correlation_id} <-
             authored_or_derived_id(Map.get(attrs, :correlation_id), "correlation:" <> id),
           data <-
             identity
             |> Map.delete(:input_evidence_digest)
             |> Map.put(:id, id)
             |> Map.put(:input, input)
             |> Map.put(:correlation_id, correlation_id),
           digest <- Value.digest!(data),
           :ok <- declared_digest(Map.get(attrs, :digest), digest) do
        {:ok, struct!(__MODULE__, Map.put(data, :digest, digest))}
      end
    end
  end

  def new(value), do: {:error, {:invalid_execution_handoff, shape(value)}}

  @doc "Builds a typed Flow-to-Work handoff."
  @spec flow_to_work(String.t() | Ref.t(), term(), term(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def flow_to_work(definition_ref, flow_ref, work_ref, input, opts \\ []) do
    handoff(:flow, flow_ref, :work, work_ref, definition_ref, input, opts)
  end

  @doc "Builds a typed Work-to-Work handoff."
  @spec work_to_work(String.t() | Ref.t(), term(), term(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def work_to_work(definition_ref, source_work, target_work, input, opts \\ []) do
    handoff(:work, source_work, :work, target_work, definition_ref, input, opts)
  end

  @doc "Builds a typed Work-to-Flow handoff event."
  @spec work_to_flow(String.t() | Ref.t(), term(), term(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def work_to_flow(definition_ref, work_ref, flow_ref, input, opts \\ []) do
    handoff(:work, work_ref, :flow, flow_ref, definition_ref, input, opts)
  end

  @doc "Verifies that a Work-target handoff addresses an exact materialization."
  @spec validate_target(t(), Materialization.t()) :: :ok | {:error, term()}
  def validate_target(%__MODULE__{} = handoff, %Materialization{} = materialization) do
    with {:ok, handoff} <- new(handoff) do
      cond do
        handoff.target.kind != :work ->
          {:error, {:execution_handoff_target_kind_mismatch, handoff.target.kind, :work}}

        handoff.definition_ref != materialization.definition_ref ->
          {:error, :execution_handoff_definition_mismatch}

        handoff.target.ref != materialization.program.id ->
          {:error, :execution_handoff_work_mismatch}

        handoff.input != materialization.input ->
          {:error, :execution_handoff_input_mismatch}

        true ->
          :ok
      end
    end
  end

  def validate_target(handoff, materialization),
    do: {:error, {:invalid_execution_handoff_target, shape(handoff), shape(materialization)}}

  @doc "Returns a portable event for a Flow-target handoff."
  @spec event(t()) :: {:ok, map()} | {:error, term()}
  def event(%__MODULE__{} = handoff) do
    with {:ok, handoff} <- new(handoff),
         true <- handoff.target.kind == :flow do
      {:ok,
       %{
         schema_version: 1,
         type: :execution_handoff,
         handoff_id: handoff.id,
         handoff_digest: handoff.digest,
         definition_ref: handoff.definition_ref,
         source: handoff.source,
         target: handoff.target,
         input: handoff.input,
         correlation_id: handoff.correlation_id,
         causation_id: handoff.causation_id,
         provenance: handoff.provenance
       }}
    else
      false -> {:error, {:execution_handoff_target_kind_mismatch, handoff.target.kind, :flow}}
      {:error, _reason} = error -> error
    end
  end

  def event(value), do: {:error, {:invalid_execution_handoff, shape(value)}}

  @doc "Returns the complete portable handoff representation."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = handoff), do: Map.from_struct(handoff)

  @doc "Restores a handoff and verifies its digest."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data), do: new(data)

  @spec handoff(atom(), term(), atom(), term(), term(), term(), keyword()) ::
          {:ok, t()} | {:error, term()}
  defp handoff(source_kind, source_ref, target_kind, target_ref, definition_ref, input, opts)
       when is_list(opts) do
    if Keyword.keyword?(opts) do
      opts
      |> Map.new()
      |> Map.merge(%{
        definition_ref: definition_ref,
        source: %{kind: source_kind, ref: source_ref},
        target: %{kind: target_kind, ref: target_ref},
        input: input
      })
      |> new()
    else
      {:error, :invalid_execution_handoff_options}
    end
  end

  defp handoff(
         _source_kind,
         _source_ref,
         _target_kind,
         _target_ref,
         _definition_ref,
         _input,
         _opts
       ),
       do: {:error, :invalid_execution_handoff_options}

  @spec endpoint(term(), atom()) :: {:ok, endpoint()} | {:error, term()}
  defp endpoint(value, field) when is_map(value) and not is_struct(value) do
    with :ok <- reject_ambiguous_keys(value, [:kind, :ref]),
         value <- atomize(value, [:kind, :ref]),
         [] <- Map.keys(value) -- [:kind, :ref],
         {:ok, kind} <- enum(Map.get(value, :kind), @kinds, field),
         {:ok, ref} <- stable_ref(Map.get(value, :ref), field) do
      {:ok, %{kind: kind, ref: ref}}
    else
      [_unknown | _rest] = unknown ->
        {:error, {:unknown_execution_handoff_endpoint_fields, field, Enum.sort(unknown)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp endpoint(value, field),
    do: {:error, {:invalid_execution_handoff_endpoint, field, shape(value)}}

  @spec stable_ref(term(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp stable_ref(value, field) when is_atom(value) and not is_nil(value) do
    name = Atom.to_string(value)

    if String.starts_with?(name, "Elixir.") or Code.ensure_loaded?(value),
      do: {:error, {:execution_handoff_code_reference_forbidden, field}},
      else: {:ok, name}
  end

  defp stable_ref(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp stable_ref(value, field), do: {:error, {:invalid_execution_handoff_ref, field, value}}

  @spec closed_input(term()) :: {:ok, term()} | {:error, term()}
  defp closed_input(value) do
    case Expression.normalize({:fixed, value}) do
      {:ok, %{value: normalized}} -> {:ok, normalized}
      {:error, reason} -> {:error, {:invalid_execution_handoff_input, reason}}
    end
  end

  @spec definition_ref(term()) :: {:ok, String.t()} | {:error, term()}
  defp definition_ref(%Ref{} = ref) do
    if Ref.valid?(ref),
      do: {:ok, Ref.to_string(ref)},
      else: {:error, :invalid_execution_handoff_ref}
  end

  defp definition_ref(value) when is_binary(value) do
    with {:ok, ref} <- Ref.parse(value), do: {:ok, Ref.to_string(ref)}
  end

  defp definition_ref(value), do: {:error, {:invalid_execution_handoff_definition_ref, value}}

  @spec distinct_endpoints(endpoint(), endpoint()) :: :ok | {:error, term()}
  defp distinct_endpoints(endpoint, endpoint), do: {:error, :execution_handoff_self_reference}
  defp distinct_endpoints(_source, _target), do: :ok

  @spec portable_map(term(), atom()) :: {:ok, map()} | {:error, term()}
  defp portable_map(value, field) when is_map(value) and not is_struct(value) do
    case Value.validate(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, {:nonportable_execution_handoff_field, field, reason}}
    end
  end

  defp portable_map(value, field),
    do: {:error, {:invalid_execution_handoff_field, field, shape(value)}}

  @spec optional_id(term(), atom()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_id(nil, _field), do: {:ok, nil}
  defp optional_id(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp optional_id(value, field), do: {:error, {:invalid_execution_handoff_id, field, value}}

  @spec authored_or_derived_id(term(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp authored_or_derived_id(nil, derived), do: {:ok, derived}

  defp authored_or_derived_id(value, _derived) when is_binary(value) and value != "",
    do: {:ok, value}

  defp authored_or_derived_id(value, _derived),
    do: {:error, {:invalid_execution_handoff_id, value}}

  @spec derived_id(map()) :: String.t()
  defp derived_id(identity) do
    digest = Value.digest!(identity)
    "execution-handoff:" <> binary_part(digest, 0, 32)
  end

  @spec declared_digest(term(), String.t()) :: :ok | {:error, term()}
  defp declared_digest(nil, _digest), do: :ok
  defp declared_digest(digest, digest), do: :ok

  defp declared_digest(declared, actual),
    do: {:error, {:execution_handoff_digest_mismatch, declared, actual}}

  @spec schema(term()) :: :ok | {:error, term()}
  defp schema(@schema_version), do: :ok
  defp schema(value), do: {:error, {:unsupported_execution_handoff_schema, value}}

  @spec enum(term(), [atom()], atom()) :: {:ok, atom()} | {:error, term()}
  defp enum(value, allowed, field) when is_atom(value) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_execution_handoff_kind, field, value}}
  end

  defp enum(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_execution_handoff_kind, field, value}}
      kind -> {:ok, kind}
    end
  end

  defp enum(value, _allowed, field),
    do: {:error, {:invalid_execution_handoff_kind, field, value}}

  @spec exact_keys(map()) :: :ok | {:error, term()}
  defp exact_keys(attrs) do
    case Map.keys(attrs) -- @fields do
      [] -> :ok
      unknown -> {:error, {:unknown_execution_handoff_fields, Enum.sort_by(unknown, &inspect/1)}}
    end
  end

  @spec atomize(map(), [atom()]) :: map()
  defp atomize(value, fields) do
    Enum.reduce(fields, value, fn field, acc ->
      string = Atom.to_string(field)

      case Map.fetch(acc, string) do
        {:ok, item} -> acc |> Map.delete(string) |> Map.put_new(field, item)
        :error -> acc
      end
    end)
  end

  @spec reject_ambiguous_keys(map(), [atom()]) :: :ok | {:error, term()}
  defp reject_ambiguous_keys(value, fields) do
    case Enum.find(fields, fn field ->
           Map.has_key?(value, field) and Map.has_key?(value, Atom.to_string(field))
         end) do
      nil -> :ok
      field -> {:error, {:ambiguous_execution_handoff_field, field}}
    end
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
