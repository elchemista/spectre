defmodule Spectre.Payload.Store do
  @moduledoc """
  Application-owned storage for content kept outside durable Spectre records.

  Configure `{MyApp.Payloads, options}` at the consuming runtime boundary.
  `put/3` returns an opaque, portable reference; `fetch/3` resolves it. Spectre
  does not prescribe a database, object store, encryption scheme, digest or
  reference format. The adapter owns those choices and the guarantees offered
  by its references, including retention and any integrity checks.

  Callbacks run in the caller's worker. This facade does not start detached
  tasks, retain payloads, retry writes or fall back to inline persistence.
  Runtime integrations must invoke it outside their ordering process and own
  the worker's timeout, cancellation and result handling.

  The small context map describes why content is being stored or fetched.
  Adapters can use its operation identity for idempotency and access control;
  it is application context, never an authorization capability.

  A successful `put/3` must mean the reference can be resolved according to the
  adapter's contract. If an external write succeeds but the subsequent Spectre
  commit fails, cleanup of unused content belongs to the application.
  """

  alias Spectre.GAM.Adapter
  alias Spectre.GAM.Canonical.Value

  @type config :: {module(), keyword()}
  @type payload_ref :: term()
  @type context :: map()

  @callback put(term(), context(), keyword()) :: {:ok, payload_ref()} | {:error, term()}
  @callback fetch(payload_ref(), context(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Validates adapter wiring; nil leaves external payload storage unconfigured."
  @spec normalize(term()) :: {:ok, config() | nil} | {:error, :invalid_payload_store}
  def normalize(nil), do: {:ok, nil}

  def normalize({module, opts} = config) when is_atom(module) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- Adapter.validate(module, put: 3, fetch: 3) do
      {:ok, config}
    else
      _ -> {:error, :invalid_payload_store}
    end
  end

  def normalize(_), do: {:error, :invalid_payload_store}

  @doc "Stores content and validates only that its opaque reference is portable."
  @spec put(config(), term(), context()) :: {:ok, payload_ref()} | {:error, term()}
  def put(config, payload, context) when is_map(context) and not is_struct(context) do
    with {:ok, reference} <- invoke(config, :put, [payload, context]) do
      case Value.validate(reference) do
        :ok -> {:ok, reference}
        {:error, _} -> {:error, :invalid_payload_reference}
      end
    end
  end

  def put(_, _, _), do: {:error, :invalid_payload_context}

  @doc "Resolves content through the configured adapter without imposing a payload schema."
  @spec fetch(config(), payload_ref(), context()) :: {:ok, term()} | {:error, term()}
  def fetch(config, reference, context) when is_map(context) and not is_struct(context),
    do: invoke(config, :fetch, [reference, context])

  def fetch(_, _, _), do: {:error, :invalid_payload_context}

  defp invoke({module, opts}, callback, args)
       when is_atom(module) and module not in [nil, true, false] and is_list(opts) do
    case Adapter.invoke(module, callback, args ++ [opts]) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _} -> {:error, :invalid_payload_store_result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp invoke(_, _, _), do: {:error, :payload_store_not_configured}
end
