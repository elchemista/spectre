defmodule Spectre.State.Codec do
  @moduledoc """
  Strict, versioned serialization for durable Spectre state.

  The codec accepts JSON text or database-style maps with string keys. It
  validates state, effect, and awaitable lifecycle enums and rejects unknown
  fields instead of silently dropping them. Arbitrary nested terms are encoded
  through explicit tagged JSON values; decoding never creates atoms.
  """

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.State

  @state_version 3
  @max_json_bytes 2_000_000
  @max_pending_effects 1
  @max_planned_effects 32
  @max_awaitables 64
  @max_memory_refs 256
  @max_trace_entries 256
  @supported_versions [2, 3]
  @effect_statuses [:pending, :waiting_policy, :approved, :completed, :failed, :cancelled]
  @awaitable_statuses [:open, :accepted, :rejected, :cancelled, :expired]
  @effect_kinds [:action]
  @awaitable_kinds [:policy]

  @state_keys ~w(
    state_version revision conversation_id current_flow current_scope
    pending_effects planned_effects awaitables memory_refs data trace
  )

  @effect_keys ~w(
    id idempotency_key kind name mode policy result error args status payload metadata
  )

  @awaitable_keys ~w(
    id kind name subject_id label max_attempts status attempts metadata
  )

  @doc """
  Encodes state into a JSON-safe map whose public schema uses string keys.
  """
  @spec encode(State.t()) :: {:ok, map()} | {:error, term()}
  def encode(%State{} = state) do
    with :ok <- validate_state(state),
         {:ok, conversation_id} <- encode_value(state.conversation_id),
         {:ok, current_flow} <- encode_value(state.current_flow),
         {:ok, current_scope} <- encode_value(state.current_scope),
         {:ok, pending_effects} <- encode_list(state.pending_effects, &encode_effect/1),
         {:ok, planned_effects} <- encode_list(state.planned_effects, &encode_effect/1),
         {:ok, awaitables} <- encode_list(state.awaitables, &encode_awaitable/1),
         {:ok, memory_refs} <- encode_value(state.memory_refs),
         {:ok, data} <- encode_value(state.data),
         {:ok, trace} <- encode_value(state.trace) do
      {:ok,
       %{
         "state_version" => @state_version,
         "revision" => state.revision,
         "conversation_id" => conversation_id,
         "current_flow" => current_flow,
         "current_scope" => current_scope,
         "pending_effects" => pending_effects,
         "planned_effects" => planned_effects,
         "awaitables" => awaitables,
         "memory_refs" => memory_refs,
         "data" => data,
         "trace" => trace
       }}
    end
  end

  def encode(other), do: {:error, {:invalid_state, value_shape(other)}}

  @doc """
  Encodes state as JSON.
  """
  @spec encode_json(State.t()) :: {:ok, String.t()} | {:error, term()}
  def encode_json(%State{} = state) do
    with {:ok, encoded} <- encode(state), do: Jason.encode(encoded)
  end

  @doc """
  Decodes JSON text or a string/atom-keyed persistence map into validated state.
  """
  @spec decode(String.t() | map()) :: {:ok, State.t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    if byte_size(json) <= @max_json_bytes do
      with {:ok, decoded} <- Jason.decode(json), do: decode(decoded)
    else
      {:error, {:state_payload_too_large, byte_size(json), @max_json_bytes}}
    end
  end

  def decode(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_schema_map(attrs, @state_keys, :state),
         {:ok, version} <- required_integer(attrs, "state_version"),
         :ok <- validate_version(version),
         {:ok, revision} <- decode_revision(attrs, version),
         {:ok, conversation_id} <- decode_field(attrs, "conversation_id", nil),
         {:ok, current_flow} <- decode_field(attrs, "current_flow", nil),
         {:ok, current_scope} <- decode_field(attrs, "current_scope", nil),
         {:ok, pending_effects} <- decode_collection(attrs, "pending_effects", &decode_effect/1),
         {:ok, planned_effects} <- decode_collection(attrs, "planned_effects", &decode_effect/1),
         {:ok, awaitables} <- decode_collection(attrs, "awaitables", &decode_awaitable/1),
         {:ok, memory_refs} <- decode_field(attrs, "memory_refs", []),
         {:ok, data} <- decode_field(attrs, "data", %{}),
         :ok <- validate_state_data(data),
         {:ok, trace} <- decode_field(attrs, "trace", []) do
      build_state(%{
        state_version: @state_version,
        revision: revision,
        conversation_id: conversation_id,
        current_flow: current_flow,
        current_scope: current_scope,
        pending_effects: pending_effects,
        planned_effects: planned_effects,
        awaitables: awaitables,
        memory_refs: memory_refs,
        data: data,
        trace: trace
      })
    end
  end

  def decode(other), do: {:error, {:invalid_state_payload, value_shape(other)}}

  @doc """
  Decodes state or raises for trusted boot-time configuration paths.
  """
  @spec decode!(String.t() | map()) :: State.t()
  def decode!(payload) do
    case decode(payload) do
      {:ok, state} -> state
      {:error, reason} -> raise ArgumentError, "invalid Spectre state: #{inspect(reason)}"
    end
  end

  @spec encode_effect(Effect.t()) :: {:ok, map()} | {:error, term()}
  defp encode_effect(%Effect{} = effect) do
    with :ok <- validate_effect(effect),
         {:ok, id} <- encode_value(effect.id),
         {:ok, name} <- encode_value(effect.name),
         {:ok, policy} <- encode_value(effect.policy),
         {:ok, result} <- encode_value(effect.result),
         {:ok, error} <- encode_value(effect.error),
         {:ok, args} <- encode_value(effect.args),
         {:ok, payload} <- encode_value(effect.payload),
         {:ok, metadata} <- encode_value(effect.metadata) do
      {:ok,
       %{
         "id" => id,
         "idempotency_key" => effect.idempotency_key,
         "kind" => Atom.to_string(effect.kind),
         "name" => name,
         "mode" => encode_optional_atom(effect.mode),
         "policy" => policy,
         "result" => result,
         "error" => error,
         "args" => args,
         "status" => Atom.to_string(effect.status),
         "payload" => payload,
         "metadata" => metadata
       }}
    end
  end

  defp encode_effect(other), do: {:error, {:invalid_effect, value_shape(other)}}

  @spec decode_effect(term()) :: {:ok, Effect.t()} | {:error, term()}
  defp decode_effect(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_schema_map(attrs, @effect_keys, :effect),
         {:ok, id} <- decode_required_field(attrs, "id"),
         {:ok, key} <- required_binary(attrs, "idempotency_key"),
         {:ok, kind} <- decode_enum(attrs, "kind", @effect_kinds),
         {:ok, name} <- decode_field(attrs, "name", nil),
         {:ok, mode} <- decode_optional_enum(attrs, "mode", [:read, :write, :destructive]),
         {:ok, policy} <- decode_field(attrs, "policy", nil),
         {:ok, result} <- decode_field(attrs, "result", nil),
         {:ok, error} <- decode_field(attrs, "error", nil),
         {:ok, args} <- decode_field(attrs, "args", %{}),
         {:ok, status} <- decode_enum(attrs, "status", @effect_statuses),
         {:ok, payload} <- decode_field(attrs, "payload", %{}),
         {:ok, metadata} <- decode_field(attrs, "metadata", %{}),
         :ok <- require_map(args, :effect_args),
         :ok <- require_map(payload, :effect_payload),
         :ok <- require_map(metadata, :effect_metadata) do
      {:ok,
       %Effect{
         id: id,
         idempotency_key: key,
         kind: kind,
         name: name,
         mode: mode,
         policy: policy,
         result: result,
         error: error,
         args: args,
         status: status,
         payload: payload,
         metadata: metadata
       }}
    end
  end

  defp decode_effect(other), do: {:error, {:invalid_effect_payload, value_shape(other)}}

  @spec encode_awaitable(Awaitable.t()) :: {:ok, map()} | {:error, term()}
  defp encode_awaitable(%Awaitable{} = awaitable) do
    with :ok <- validate_awaitable(awaitable),
         {:ok, id} <- encode_value(awaitable.id),
         {:ok, name} <- encode_value(awaitable.name),
         {:ok, subject_id} <- encode_value(awaitable.subject_id),
         {:ok, label} <- encode_value(awaitable.label),
         {:ok, metadata} <- encode_value(awaitable.metadata) do
      {:ok,
       %{
         "id" => id,
         "kind" => Atom.to_string(awaitable.kind),
         "name" => name,
         "subject_id" => subject_id,
         "label" => label,
         "max_attempts" => awaitable.max_attempts,
         "status" => Atom.to_string(awaitable.status),
         "attempts" => awaitable.attempts,
         "metadata" => metadata
       }}
    end
  end

  defp encode_awaitable(other), do: {:error, {:invalid_awaitable, value_shape(other)}}

  @spec decode_awaitable(term()) :: {:ok, Awaitable.t()} | {:error, term()}
  defp decode_awaitable(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_schema_map(attrs, @awaitable_keys, :awaitable),
         {:ok, id} <- decode_required_field(attrs, "id"),
         {:ok, kind} <- decode_enum(attrs, "kind", @awaitable_kinds),
         {:ok, name} <- decode_required_field(attrs, "name"),
         {:ok, subject_id} <- decode_required_field(attrs, "subject_id"),
         {:ok, label} <- decode_field(attrs, "label", nil),
         {:ok, max_attempts} <- optional_positive_integer(attrs, "max_attempts"),
         {:ok, status} <- decode_enum(attrs, "status", @awaitable_statuses),
         {:ok, attempts} <- optional_non_neg_integer(attrs, "attempts", 0),
         {:ok, metadata} <- decode_field(attrs, "metadata", %{}),
         :ok <- require_map(metadata, :awaitable_metadata) do
      {:ok,
       %Awaitable{
         id: id,
         kind: kind,
         name: name,
         subject_id: subject_id,
         label: label,
         max_attempts: max_attempts,
         status: status,
         attempts: attempts,
         metadata: metadata
       }}
    end
  end

  defp decode_awaitable(other),
    do: {:error, {:invalid_awaitable_payload, value_shape(other)}}

  @spec validate_state(State.t()) :: :ok | {:error, term()}
  defp validate_state(%State{} = state) do
    with :ok <- validate_revision(state.revision),
         :ok <- validate_state_collections(state),
         :ok <-
           validate_collection_size(state.pending_effects, :pending_effects, @max_pending_effects),
         :ok <-
           validate_collection_size(state.planned_effects, :planned_effects, @max_planned_effects),
         :ok <- validate_collection_size(state.awaitables, :awaitables, @max_awaitables),
         :ok <- validate_collection_size(state.memory_refs, :memory_refs, @max_memory_refs) do
      validate_collection_size(state.trace, :trace, @max_trace_entries)
    end
  end

  @spec validate_revision(term()) :: :ok | {:error, term()}
  defp validate_revision(revision) when is_integer(revision) and revision >= 0, do: :ok
  defp validate_revision(revision), do: {:error, {:invalid_state_revision, revision}}

  @spec validate_state_data(term()) :: :ok | {:error, term()}
  defp validate_state_data(data) do
    if is_map(data),
      do: :ok,
      else: {:error, {:invalid_state_data, value_shape(data)}}
  end

  @spec validate_state_collections(State.t()) :: :ok | {:error, term()}
  defp validate_state_collections(%State{} = state) do
    cond do
      not is_list(state.pending_effects) or not is_list(state.planned_effects) ->
        {:error, :invalid_effect_collections}

      not is_list(state.awaitables) or not is_list(state.memory_refs) or
          not is_list(state.trace) ->
        {:error, :invalid_state_collections}

      true ->
        :ok
    end
  end

  @spec validate_collection_size(list(), atom(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_collection_size(values, name, max) do
    size = length(values)

    if size <= max,
      do: :ok,
      else: {:error, {:state_collection_too_large, name, size, max}}
  end

  @spec validate_effect(Effect.t()) :: :ok | {:error, term()}
  defp validate_effect(%Effect{} = effect) do
    cond do
      effect.kind not in @effect_kinds -> {:error, {:invalid_effect_kind, effect.kind}}
      effect.status not in @effect_statuses -> {:error, {:invalid_effect_status, effect.status}}
      not is_binary(effect.idempotency_key) -> {:error, :invalid_idempotency_key}
      not is_map(effect.args) -> {:error, :invalid_effect_args}
      not is_map(effect.payload) -> {:error, :invalid_effect_payload}
      not is_map(effect.metadata) -> {:error, :invalid_effect_metadata}
      true -> :ok
    end
  end

  @spec validate_awaitable(Awaitable.t()) :: :ok | {:error, term()}
  defp validate_awaitable(%Awaitable{} = awaitable) do
    cond do
      awaitable.kind not in @awaitable_kinds ->
        {:error, {:invalid_awaitable_kind, awaitable.kind}}

      awaitable.status not in @awaitable_statuses ->
        {:error, {:invalid_awaitable_status, awaitable.status}}

      not is_integer(awaitable.attempts) or awaitable.attempts < 0 ->
        {:error, {:invalid_awaitable_attempts, awaitable.attempts}}

      not is_map(awaitable.metadata) ->
        {:error, :invalid_awaitable_metadata}

      true ->
        :ok
    end
  end

  @spec build_state(map()) :: {:ok, State.t()} | {:error, term()}
  defp build_state(attrs) do
    state = struct(State, attrs)

    with :ok <- validate_state(state),
         true <- Enum.all?(state.pending_effects ++ state.planned_effects, &match?(%Effect{}, &1)),
         true <- Enum.all?(state.awaitables, &match?(%Awaitable{}, &1)) do
      {:ok, state}
    else
      false -> {:error, :invalid_nested_state}
      {:error, _reason} = error -> error
    end
  end

  @spec encode_value(term()) :: {:ok, term()} | {:error, term()}
  defp encode_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, value}

  defp encode_value(value) when is_atom(value) do
    {:ok, %{"$spectre" => "atom", "value" => Atom.to_string(value)}}
  end

  defp encode_value(%DateTime{} = value) do
    {:ok, %{"$spectre" => "datetime", "value" => DateTime.to_iso8601(value)}}
  end

  defp encode_value(%{__struct__: module} = value) do
    with {:ok, fields} <- value |> Map.from_struct() |> encode_value() do
      {:ok,
       %{
         "$spectre" => "struct",
         "module" => Atom.to_string(module),
         "fields" => fields
       }}
    end
  end

  defp encode_value(value) when is_tuple(value) do
    with {:ok, values} <- value |> Tuple.to_list() |> encode_list(&encode_value/1) do
      {:ok, %{"$spectre" => "tuple", "values" => values}}
    end
  end

  defp encode_value(value) when is_list(value), do: encode_list(value, &encode_value/1)

  defp encode_value(value) when is_map(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn {key, entry}, {:ok, entries} ->
      with {:ok, encoded_key} <- encode_value(key),
           {:ok, encoded_entry} <- encode_value(entry) do
        {:cont, {:ok, [[encoded_key, encoded_entry] | entries]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, %{"$spectre" => "map", "entries" => Enum.reverse(entries)}}
      {:error, _reason} = error -> error
    end
  end

  defp encode_value(value), do: {:error, {:unsupported_state_value, value_shape(value)}}

  @spec decode_value(term()) :: {:ok, term()} | {:error, term()}
  defp decode_value(value)
       when is_nil(value) or is_boolean(value) or is_number(value) or is_binary(value),
       do: {:ok, value}

  defp decode_value(values) when is_list(values), do: decode_list(values, &decode_value/1)

  defp decode_value(%{"$spectre" => "atom", "value" => value}) when is_binary(value) do
    existing_atom(value)
  end

  defp decode_value(%{"$spectre" => "datetime", "value" => value}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_datetime, reason}}
    end
  end

  defp decode_value(%{"$spectre" => "tuple", "values" => values}) when is_list(values) do
    with {:ok, decoded} <- decode_list(values, &decode_value/1), do: {:ok, List.to_tuple(decoded)}
  end

  defp decode_value(%{"$spectre" => "map", "entries" => entries}) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      [key, value], {:ok, decoded} ->
        with {:ok, key} <- decode_value(key),
             {:ok, value} <- decode_value(value) do
          {:cont, {:ok, Map.put(decoded, key, value)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_encoded_map_entry}}
    end)
  end

  defp decode_value(%{
         "$spectre" => "struct",
         "module" => module_name,
         "fields" => encoded_fields
       })
       when is_binary(module_name) do
    with {:ok, module} <- existing_atom(module_name),
         true <- Code.ensure_loaded?(module),
         {:ok, fields} <- decode_value(encoded_fields),
         true <- is_map(fields) do
      {:ok, struct(module, fields)}
    else
      false -> {:error, {:unknown_state_struct, module_name}}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, {:invalid_state_struct, module_name, exception.__struct__}}
  end

  defp decode_value(%{"$spectre" => tag}), do: {:error, {:unknown_state_value_tag, tag}}

  defp decode_value(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, entry}, {:ok, decoded} ->
      case decode_value(entry) do
        {:ok, entry} -> {:cont, {:ok, Map.put(decoded, key, entry)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_value(value), do: {:error, {:invalid_encoded_state_value, value_shape(value)}}

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
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  @spec decode_list(list(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  defp decode_list(values, decoder), do: encode_list(values, decoder)

  @spec normalize_schema_map(map(), [String.t()], atom()) :: {:ok, map()} | {:error, term()}
  defp normalize_schema_map(attrs, allowed, schema) do
    attrs
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, key} <- schema_key(key),
           true <- key in allowed,
           false <- Map.has_key?(normalized, key) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        false -> {:halt, {:error, {:duplicate_or_unknown_field, schema, key}}}
        true -> {:halt, {:error, {:duplicate_or_unknown_field, schema, key}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec schema_key(term()) :: {:ok, String.t()} | {:error, term()}
  defp schema_key(key) when is_binary(key), do: {:ok, key}
  defp schema_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp schema_key(key), do: {:error, {:invalid_schema_key, value_shape(key)}}

  @spec decode_collection(map(), String.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  defp decode_collection(attrs, key, decoder) do
    case Map.get(attrs, key, []) do
      values when is_list(values) -> decode_list(values, decoder)
      value -> {:error, {:invalid_collection, key, value_shape(value)}}
    end
  end

  @spec decode_field(map(), String.t(), term()) :: {:ok, term()} | {:error, term()}
  defp decode_field(attrs, key, default), do: attrs |> Map.get(key, default) |> decode_value()

  @spec decode_required_field(map(), String.t()) :: {:ok, term()} | {:error, term()}
  defp decode_required_field(attrs, key) do
    if Map.has_key?(attrs, key),
      do: decode_value(Map.fetch!(attrs, key)),
      else: {:error, {:missing_field, key}}
  end

  @spec required_integer(map(), String.t()) :: {:ok, integer()} | {:error, term()}
  defp required_integer(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_integer, key, value}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  @spec required_binary(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp required_binary(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_binary, key, value_shape(value)}}
      :error -> {:error, {:missing_field, key}}
    end
  end

  @spec decode_enum(map(), String.t(), [atom()]) :: {:ok, atom()} | {:error, term()}
  defp decode_enum(attrs, key, allowed) do
    with {:ok, value} <- required_binary(attrs, key) do
      case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
        nil -> {:error, {:invalid_enum, key, value}}
        enum -> {:ok, enum}
      end
    end
  end

  @spec decode_optional_enum(map(), String.t(), [atom()]) ::
          {:ok, atom() | nil} | {:error, term()}
  defp decode_optional_enum(attrs, key, allowed) do
    case Map.get(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
          nil -> {:error, {:invalid_enum, key, value}}
          enum -> {:ok, enum}
        end

      value ->
        {:error, {:invalid_enum, key, value}}
    end
  end

  @spec optional_positive_integer(map(), String.t()) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  defp optional_positive_integer(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_positive_integer, key, value}}
    end
  end

  @spec optional_non_neg_integer(map(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp optional_non_neg_integer(attrs, key, default) do
    case Map.get(attrs, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value -> {:error, {:invalid_non_neg_integer, key, value}}
    end
  end

  @spec decode_revision(map(), integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp decode_revision(attrs, 2), do: optional_non_neg_integer(attrs, "revision", 0)
  defp decode_revision(attrs, _version), do: optional_non_neg_integer(attrs, "revision", 0)

  @spec validate_version(integer()) :: :ok | {:error, term()}
  defp validate_version(version) when version in @supported_versions, do: :ok
  defp validate_version(version), do: {:error, {:unsupported_state_version, version}}

  @spec require_map(term(), atom()) :: :ok | {:error, term()}
  defp require_map(value, _field) when is_map(value), do: :ok
  defp require_map(value, field), do: {:error, {:invalid_map, field, value_shape(value)}}

  @spec encode_optional_atom(atom() | nil) :: String.t() | nil
  defp encode_optional_atom(nil), do: nil
  defp encode_optional_atom(value) when is_atom(value), do: Atom.to_string(value)

  @spec existing_atom(String.t()) :: {:ok, atom()} | {:error, term()}
  defp existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, value}}
  end

  @spec value_shape(term()) :: term()
  defp value_shape(value) when is_atom(value), do: :atom
  defp value_shape(value) when is_binary(value), do: :binary
  defp value_shape(value) when is_list(value), do: :list
  defp value_shape(value) when is_map(value), do: :map
  defp value_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp value_shape(value) when is_pid(value), do: :pid
  defp value_shape(value) when is_reference(value), do: :reference
  defp value_shape(value) when is_function(value), do: :function
  defp value_shape(_value), do: :other
end
