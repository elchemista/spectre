defmodule Spectre.Receipt.Sink do
  @moduledoc """
  Adapter boundary for portable boundary receipts.

  `:disabled`, `:observational`, and `:required` are orchestration policies;
  adapters only implement idempotent append and lookup. Any exception during
  append is classified as ambiguous because the write may have committed.
  """

  alias Spectre.Receipt.Envelope

  @type config :: module() | {module(), keyword()} | nil | false
  @type normalized :: nil | {module(), keyword()}

  @callback append(Envelope.t(), keyword()) ::
              {:ok, :appended | :idempotent} | {:error, :ambiguous | term()}
  @callback lookup(String.t(), keyword()) ::
              {:ok, Envelope.t()} | :not_found | {:error, term()}
  @callback put_payload(Envelope.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback get_payload(String.t(), keyword()) ::
              {:ok, Envelope.t()} | :not_found | {:error, term()}

  @optional_callbacks put_payload: 2, get_payload: 2

  @spec normalize(config()) :: {:ok, normalized()} | {:error, term()}
  def normalize(value) when value in [nil, false], do: {:ok, nil}

  def normalize(module)
      when is_atom(module) and not is_nil(module) and not is_boolean(module),
      do: {:ok, {module, []}}

  def normalize({module, opts})
      when is_atom(module) and not is_nil(module) and not is_boolean(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, {module, opts}},
      else: {:error, {:invalid_receipt_sink, :options}}
  end

  def normalize(value), do: {:error, {:invalid_receipt_sink, value_class(value)}}

  @spec append(normalized(), Envelope.t(), keyword()) ::
          {:ok, :appended | :idempotent} | {:error, term()}
  def append(nil, _envelope, _opts), do: {:error, :receipt_sink_disabled}

  def append({module, sink_opts}, %Envelope{} = envelope, opts) do
    with :ok <- validate_envelope(envelope),
         :ok <- callback(module, :append, 2) do
      module.append(envelope, Keyword.merge(sink_opts, opts))
      |> normalize_append(module)
    end
  rescue
    _exception -> {:error, {:ambiguous, :receipt_append_exception}}
  catch
    _kind, _reason -> {:error, {:ambiguous, :receipt_append_failure}}
  end

  @spec lookup(normalized(), String.t(), keyword()) ::
          {:ok, Envelope.t()} | :not_found | {:error, term()}
  def lookup(nil, _id, _opts), do: :not_found

  def lookup({module, sink_opts}, id, opts) when is_binary(id) and id != "" do
    with :ok <- callback(module, :lookup, 2) do
      module.lookup(id, Keyword.merge(sink_opts, opts))
      |> normalize_lookup(module, id)
    end
  rescue
    _exception -> {:error, {:receipt_sink_error, :receipt_lookup_exception}}
  catch
    _kind, _reason -> {:error, {:receipt_sink_error, :receipt_lookup_failure}}
  end

  @spec payload_capable?(normalized()) :: boolean()
  def payload_capable?({module, _opts}) do
    Code.ensure_loaded?(module) and function_exported?(module, :put_payload, 2) and
      function_exported?(module, :get_payload, 2)
  end

  def payload_capable?(_sink), do: false

  @spec put_payload(normalized(), Envelope.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def put_payload({module, sink_opts} = sink, %Envelope{} = envelope, opts) do
    with :ok <- validate_envelope(envelope) do
      expected_ref = payload_ref(envelope)
      merged_opts = Keyword.merge(sink_opts, opts)

      result =
        try do
          with :ok <- callback(module, :put_payload, 2) do
            case module.put_payload(envelope, merged_opts) do
              {:ok, ^expected_ref} -> {:ok, expected_ref}
              {:ok, _different_ref} -> {:error, :receipt_payload_ref_mismatch}
              {:error, reason} -> {:error, external_error(reason)}
              _reply -> {:error, {:ambiguous, :invalid_receipt_payload_reply}}
            end
          end
        rescue
          _exception ->
            {:error, {:ambiguous, :receipt_payload_exception}}
        catch
          _kind, _reason ->
            {:error, {:ambiguous, :receipt_payload_failure}}
        end

      reconcile_payload_put(sink, envelope, expected_ref, result, opts)
    end
  end

  def put_payload(nil, _envelope, _opts), do: {:error, :receipt_sink_disabled}

  @spec get_payload(normalized(), String.t(), keyword()) ::
          {:ok, Envelope.t()} | :not_found | {:error, term()}
  def get_payload({module, sink_opts}, ref, opts) when is_binary(ref) and ref != "" do
    with :ok <- callback(module, :get_payload, 2) do
      case module.get_payload(ref, Keyword.merge(sink_opts, opts)) do
        {:ok, %Envelope{} = envelope} -> normalize_payload_lookup(envelope, ref)
        :not_found -> :not_found
        {:error, reason} -> {:error, external_error(reason)}
        _reply -> {:error, {:receipt_sink_error, :invalid_receipt_payload_lookup_reply}}
      end
    end
  rescue
    _exception -> {:error, {:receipt_sink_error, :receipt_payload_lookup_exception}}
  catch
    _kind, _reason -> {:error, {:receipt_sink_error, :receipt_payload_lookup_failure}}
  end

  def get_payload(nil, _ref, _opts), do: :not_found

  @doc "Returns the mandatory content-addressed reference for a receipt payload."
  @spec payload_ref(Envelope.t()) :: String.t()
  def payload_ref(%Envelope{} = envelope),
    do: "receipt-payload:" <> Envelope.digest(envelope)

  defp reconcile_payload_put(_sink, _envelope, _expected_ref, {:ok, _ref} = ok, _opts),
    do: ok

  defp reconcile_payload_put(sink, envelope, ref, {:error, :ambiguous} = error, opts) do
    reconcile_ambiguous_payload_put(sink, envelope, ref, error, opts)
  end

  defp reconcile_payload_put(
         sink,
         envelope,
         ref,
         {:error, {:ambiguous, _reason}} = error,
         opts
       ) do
    reconcile_ambiguous_payload_put(sink, envelope, ref, error, opts)
  end

  defp reconcile_payload_put(_sink, _envelope, _ref, result, _opts), do: result

  # Content-addressing makes a lost acknowledgement reconcilable without a
  # second identity or a mutable staging record in canonical state.
  defp reconcile_ambiguous_payload_put(sink, envelope, ref, error, opts) do
    case get_payload(sink, ref, opts) do
      {:ok, ^envelope} -> {:ok, ref}
      {:ok, _different} -> {:error, :receipt_payload_reconciliation_conflict}
      :not_found -> error
      {:error, reason} -> {:error, {:receipt_payload_reconciliation_failed, reason}}
    end
  end

  defp callback(module, function, arity) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:receipt_sink_not_loaded, module}}

      not function_exported?(module, function, arity) ->
        {:error, {:receipt_sink_callback_missing, module, function, arity}}

      true ->
        :ok
    end
  end

  defp normalize_append({:ok, status}, _module) when status in [:appended, :idempotent],
    do: {:ok, status}

  defp normalize_append({:error, reason}, _module), do: {:error, external_error(reason)}

  defp normalize_append(_reply, _module),
    do: {:error, {:ambiguous, :invalid_receipt_append_reply}}

  defp normalize_lookup({:ok, %Envelope{id: id} = envelope}, _module, id) do
    case validate_envelope(envelope) do
      :ok -> {:ok, envelope}
      {:error, _reason} -> {:error, {:receipt_sink_error, :invalid_receipt_envelope}}
    end
  end

  defp normalize_lookup({:ok, %Envelope{}}, _module, _id),
    do: {:error, :receipt_lookup_id_mismatch}

  defp normalize_lookup(:not_found, _module, _id), do: :not_found

  defp normalize_lookup({:error, reason}, _module, _id),
    do: {:error, external_error(reason)}

  defp normalize_lookup(_reply, _module, _id),
    do: {:error, {:receipt_sink_error, :invalid_receipt_lookup_reply}}

  defp normalize_payload_lookup(envelope, ref) do
    with :ok <- validate_envelope(envelope),
         true <- payload_ref(envelope) == ref do
      {:ok, envelope}
    else
      false -> {:error, :receipt_payload_lookup_ref_mismatch}
      {:error, _reason} -> {:error, {:receipt_sink_error, :invalid_receipt_envelope}}
    end
  end

  # Sink failures are external data. Preserve only the ambiguity bit and a
  # bounded class so provider messages, response bodies, or credentials can
  # never cross into a canonical Run error or telemetry metadata.
  defp external_error(:ambiguous), do: :ambiguous
  defp external_error({:ambiguous, reason}), do: {:ambiguous, reason_class(reason)}
  defp external_error(reason), do: {:receipt_sink_error, reason_class(reason)}

  defp reason_class(reason) when is_atom(reason) and not is_nil(reason), do: reason
  defp reason_class({reason, _detail}) when is_atom(reason) and not is_nil(reason), do: reason

  defp reason_class({reason, _first, _second}) when is_atom(reason) and not is_nil(reason),
    do: reason

  defp reason_class(_reason), do: :error

  defp value_class(value) when is_tuple(value), do: :tuple
  defp value_class(value) when is_list(value), do: :list
  defp value_class(value) when is_map(value), do: :map
  defp value_class(_value), do: :other

  defp validate_envelope(%Envelope{} = envelope) do
    case Envelope.new(envelope) do
      {:ok, ^envelope} -> :ok
      {:ok, _normalized} -> {:error, :noncanonical_receipt_envelope}
      {:error, _reason} = error -> error
    end
  end
end
