defmodule Spectre.Secret.Broker.Passthrough do
  @moduledoc """
  Explicit development-only broker.

  It verifies and claims a checkout receipt before returning the capability
  supplied in its private options. Claims are volatile by design, so this
  adapter must not be used to support a mediated or isolated host profile.
  """

  use GenServer
  @behaviour Spectre.Secret.Broker

  alias Spectre.{Adapter, Secret.CheckoutReceipt}

  @ref "spectre:secret-broker:passthrough:v1"
  @option_keys [:capability, :checkout_receipt_secret, :domain_ref, :clock, :timeout]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Spectre.Secret.Broker
  def ref, do: @ref

  @impl Spectre.Secret.Broker
  def profile, do: :development

  @impl Spectre.Secret.Broker
  def checkout(%CheckoutReceipt{} = receipt, act, attempt, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- @option_keys,
         {:ok, secret} <- required_secret(opts),
         {:ok, domain_ref} <- required_binary(opts, :domain_ref),
         {:ok, now} <- current_time(opts),
         :ok <- verify_receipt(receipt, act, attempt, domain_ref, secret, now),
         :ok <- claim(receipt, now, opts),
         {:ok, capability} <- Keyword.fetch(opts, :capability) do
      {:ok, capability}
    else
      _invalid -> {:error, :ambiguous, %{evidence: [], details_ref: failure_ref()}}
    end
  end

  @impl true
  def checkout(_receipt, _act, _attempt, _opts),
    do: {:error, :ambiguous, %{evidence: [], details_ref: failure_ref()}}

  @impl GenServer
  def init(_opts), do: {:ok, %{claims: %{}}}

  @impl GenServer
  def handle_call({:claim, key, expires_at, now}, _from, state) do
    claims = Map.reject(state.claims, fn {_key, expiry} -> expiry <= now end)

    if Map.has_key?(claims, key) do
      {:reply, {:error, :checkout_receipt_already_claimed}, %{state | claims: claims}}
    else
      {:reply, :ok, %{state | claims: Map.put(claims, key, expires_at)}}
    end
  end

  defp verify_receipt(receipt, act, attempt, domain_ref, secret, now) do
    CheckoutReceipt.verify(receipt, secret, %{
      domain_ref: domain_ref,
      act_ref: act.ref,
      attempt_ref: attempt.ref,
      executor_ref: act.executor_ref,
      material_digest: act.material_digest,
      generation: attempt.generation,
      grant_nonce_digest: attempt.grant_nonce_digest,
      broker_ref: @ref,
      now: now
    })
  end

  defp claim(receipt, now, opts) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    key = {receipt.domain_ref, receipt.attempt_ref, receipt.grant_nonce_digest}
    GenServer.call(__MODULE__, {:claim, key, receipt.expires_at, now}, timeout)
  catch
    :exit, _reason -> {:error, :checkout_claim_store_unavailable}
  end

  defp current_time(opts) do
    clock = Keyword.get(opts, :clock, Spectre.Clock.System)

    case Adapter.validate(clock, now: 0) do
      :ok -> read_clock(clock)
      {:error, _reason} -> {:error, :invalid_checkout_clock}
    end
  end

  defp read_clock(clock) do
    case clock.now() do
      now when is_integer(now) and now >= 0 -> {:ok, now}
      _invalid -> {:error, :invalid_checkout_time}
    end
  rescue
    _exception -> {:error, :checkout_clock_unavailable}
  catch
    _kind, _reason -> {:error, :checkout_clock_unavailable}
  end

  defp required_secret(opts) do
    case Keyword.fetch(opts, :checkout_receipt_secret) do
      {:ok, secret} when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _missing_or_invalid -> {:error, :checkout_receipt_secret_required}
    end
  end

  defp required_binary(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing_or_invalid -> {:error, {:checkout_broker_option_required, key}}
    end
  end

  defp failure_ref, do: "spectre:secret-broker:passthrough:checkout-refused:v1"
end
