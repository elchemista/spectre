defmodule Spectre.Domain.Configuration do
  @moduledoc """
  Validated host wiring for one Domain sequencer.

  Configuration is deliberately separate from governed state. It selects the
  adapters through which a deployment authenticates input, persists the ledger
  and reaches Zone X, but it grants no Mandate and is never treated as ledger
  truth. The resulting struct is immutable process configuration consumed by
  `Spectre.Domain.Sequencer` during boot.
  """

  alias Spectre.{Adapter, Ingress, Mind, Portable}
  alias Spectre.Execution.Boundary
  alias Spectre.Ledger.Store
  alias Spectre.Payload.Store, as: PayloadStore

  @default_batch_size 64
  @default_batch_wait_ms 1
  @default_grant_ttl_ms 30_000
  @default_conflict_retries 8
  @default_ambiguous_retries 2
  @minimum_secret_bytes 32

  @bootstrap_options [
    :genesis,
    :principals,
    :host_profile,
    :surface,
    :root_mandates,
    :genesis_verifier
  ]

  @options [
    :name,
    :registry,
    :domain_ref,
    :store,
    :ingress,
    :clock,
    :id_source,
    :late_observer,
    :mind,
    :generation,
    :grant_secret,
    :checkout_receipt_secret,
    :grant_ttl_ms,
    :batch_size,
    :batch_wait_ms,
    :conflict_retries,
    :ambiguous_retries,
    :ledger_opts,
    :payload_store,
    :executors,
    :broker,
    :constitution,
    :genesis,
    :principals,
    :host_profile,
    :surface,
    :root_mandates,
    :genesis_verifier
  ]
  @runtime_options [:name, :registry, :domain_ref, :store]
  @host_options @options -- @runtime_options

  @enforce_keys [
    :domain_ref,
    :store,
    :ingress,
    :ingress_ref,
    :clock,
    :id_source,
    :late_observer,
    :mind,
    :mind_ref,
    :execution_boundary,
    :generation,
    :grant_secret,
    :checkout_receipt_secret,
    :grant_ttl_ms,
    :batch_size,
    :batch_wait_ms,
    :conflict_retries,
    :ambiguous_retries,
    :ledger_opts,
    :payload_store,
    :bootstrap_opts,
    :constitution
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          domain_ref: String.t(),
          store: Store.config(),
          ingress: module(),
          ingress_ref: String.t(),
          clock: module(),
          id_source: module(),
          late_observer: module() | nil,
          mind: module() | nil,
          mind_ref: String.t() | nil,
          execution_boundary: Boundary.t(),
          generation: non_neg_integer(),
          grant_secret: binary(),
          checkout_receipt_secret: binary(),
          grant_ttl_ms: pos_integer(),
          batch_size: pos_integer(),
          batch_wait_ms: non_neg_integer(),
          conflict_retries: non_neg_integer(),
          ambiguous_retries: non_neg_integer(),
          ledger_opts: keyword(),
          payload_store: PayloadStore.config() | nil,
          bootstrap_opts: keyword(),
          constitution: map()
        }

  @doc "Normalizes and validates all immutable Domain process configuration."
  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- known_options(opts),
         {:ok, domain_ref} <- required_non_empty_binary(opts, :domain_ref),
         {:ok, store} <- required_store(opts),
         {:ok, {ingress, ingress_ref}} <- required_ingress(opts),
         {:ok, payload_store} <- PayloadStore.normalize(Keyword.get(opts, :payload_store)),
         {:ok, clock} <- module_option(opts, :clock, Spectre.Clock.System, now: 0),
         {:ok, id_source} <- module_option(opts, :id_source, Spectre.Id.UUIDv7, generate: 0),
         {:ok, late_observer} <- late_observer_option(opts),
         {:ok, {mind, mind_ref}} <- mind_option(opts),
         {:ok, execution_boundary} <-
           Boundary.normalize(Keyword.get(opts, :executors, []), Keyword.get(opts, :broker)),
         {:ok, generation} <- generation_option(opts),
         {:ok, grant_secret} <- secret_option(opts, :grant_secret),
         {:ok, checkout_receipt_secret} <- secret_option(opts, :checkout_receipt_secret),
         {:ok, grant_ttl_ms} <- positive_option(opts, :grant_ttl_ms, @default_grant_ttl_ms),
         {:ok, batch_size} <- positive_option(opts, :batch_size, @default_batch_size),
         {:ok, batch_wait_ms} <-
           non_negative_option(opts, :batch_wait_ms, @default_batch_wait_ms),
         {:ok, conflict_retries} <-
           non_negative_option(opts, :conflict_retries, @default_conflict_retries),
         {:ok, ambiguous_retries} <-
           non_negative_option(opts, :ambiguous_retries, @default_ambiguous_retries),
         {:ok, ledger_opts} <- keyword_option(opts, :ledger_opts, []),
         {:ok, constitution} <- constitution_option(opts),
         :ok <- usable_clock(clock) do
      {:ok,
       %__MODULE__{
         domain_ref: domain_ref,
         store: store,
         ingress: ingress,
         ingress_ref: ingress_ref,
         clock: clock,
         id_source: id_source,
         late_observer: late_observer,
         mind: mind,
         mind_ref: mind_ref,
         execution_boundary: execution_boundary,
         generation: generation,
         grant_secret: grant_secret,
         checkout_receipt_secret: checkout_receipt_secret,
         grant_ttl_ms: grant_ttl_ms,
         batch_size: batch_size,
         batch_wait_ms: batch_wait_ms,
         conflict_retries: conflict_retries,
         ambiguous_retries: ambiguous_retries,
         ledger_opts: ledger_opts,
         payload_store: payload_store,
         bootstrap_opts: Keyword.take(opts, @bootstrap_options),
         constitution: constitution
       }}
    else
      false -> {:error, :invalid_sequencer_options}
      {:error, _reason} = error -> error
    end
  end

  def new(_opts), do: {:error, :invalid_sequencer_options}

  @doc false
  @spec validate_host_options(keyword()) :: :ok | {:error, term()}
  def validate_host_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- @host_options do
        [] -> :ok
        unknown -> {:error, {:unknown_options, :domain, unknown}}
      end
    else
      {:error, {:invalid_keyword_options, :domain_options}}
    end
  end

  def validate_host_options(_opts),
    do: {:error, {:invalid_keyword_options, :domain_options}}

  @doc false
  @spec verification_opts(t()) :: keyword()
  def verification_opts(%__MODULE__{bootstrap_opts: opts}),
    do: Keyword.take(opts, [:genesis_verifier])

  @doc false
  @spec genesis_verifier(t()) :: term()
  def genesis_verifier(%__MODULE__{bootstrap_opts: opts}),
    do: Keyword.get(opts, :genesis_verifier)

  defp known_options(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      unknown -> {:error, {:unknown_sequencer_configuration_options, Enum.sort(unknown)}}
    end
  end

  defp required_non_empty_binary(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      :error -> {:error, {:missing_sequencer_option, key}}
      {:ok, _invalid} -> {:error, {:invalid_sequencer_option, key}}
    end
  end

  defp required_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, store} -> Store.normalize(store)
      :error -> {:error, {:missing_sequencer_option, :store}}
    end
  end

  defp required_ingress(opts) do
    case Keyword.fetch(opts, :ingress) do
      {:ok, module} -> Ingress.resolve(module)
      :error -> {:error, {:missing_sequencer_option, :ingress}}
    end
  end

  defp module_option(opts, key, default, callbacks) do
    module = Keyword.get(opts, key, default)

    case Adapter.validate(module, callbacks) do
      :ok ->
        {:ok, module}

      {:error, {:invalid_adapter_module, _module}} ->
        {:error, {:invalid_sequencer_option, key}}

      {:error, _reason} ->
        [{callback, arity} | _rest] = callbacks
        {:error, {:sequencer_callback_unavailable, key, module, callback, arity}}
    end
  end

  defp generation_option(opts) do
    case Keyword.fetch(opts, :generation) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _invalid} -> {:error, {:invalid_sequencer_option, :generation}}
      :error -> {:ok, :binary.decode_unsigned(:crypto.strong_rand_bytes(8))}
    end
  end

  defp late_observer_option(opts) do
    case Keyword.get(opts, :late_observer) do
      nil ->
        {:ok, nil}

      module when is_atom(module) ->
        case Adapter.validate(module, observe: 4) do
          :ok ->
            {:ok, module}

          {:error, _reason} ->
            {:error, {:sequencer_callback_unavailable, :late_observer, module, :observe, 4}}
        end

      _invalid ->
        {:error, {:invalid_sequencer_option, :late_observer}}
    end
  end

  defp mind_option(opts) do
    case Keyword.get(opts, :mind) do
      nil -> {:ok, {nil, nil}}
      module -> Mind.resolve(module)
    end
  end

  defp secret_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and byte_size(value) >= @minimum_secret_bytes ->
        {:ok, value}

      {:ok, _invalid} ->
        {:error, {:invalid_sequencer_option, key}}

      :error ->
        {:ok, :crypto.strong_rand_bytes(@minimum_secret_bytes)}
    end
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_sequencer_option, key}}
    end
  end

  defp non_negative_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _invalid -> {:error, {:invalid_sequencer_option, key}}
    end
  end

  defp keyword_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_list(value) ->
        if Keyword.keyword?(value),
          do: {:ok, value},
          else: {:error, {:invalid_sequencer_option, key}}

      _invalid ->
        {:error, {:invalid_sequencer_option, key}}
    end
  end

  defp constitution_option(opts) do
    case Keyword.get(opts, :constitution, %{}) do
      value when is_map(value) and not is_struct(value) ->
        case Portable.validate(value) do
          :ok -> {:ok, value}
          {:error, reason} -> {:error, {:invalid_constitution, reason}}
        end

      _invalid ->
        {:error, :invalid_constitution}
    end
  end

  defp usable_clock(clock) do
    case Adapter.invoke(clock, :now, []) do
      {:ok, now} when is_integer(now) and now >= 0 -> :ok
      _invalid -> {:error, :invalid_clock_value}
    end
  end
end
