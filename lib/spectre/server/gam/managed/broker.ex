defmodule Spectre.Server.GAM.Managed.Broker do
  @moduledoc false
  use ExGAM.Secret.Broker, ref: "spectre:managed:broker:v1", profile: :mediated

  alias ExGAM.{Act, Attempt}
  alias ExGAM.GovernedAct.Admission.Binding
  alias ExGAM.Secret.CheckoutReceipt

  @doc false
  @spec checkout(CheckoutReceipt.t(), Act.t(), Attempt.t(), keyword()) ::
          {:ok, CheckoutReceipt.t()} | {:error, :ambiguous, map()}
  @impl true
  def checkout(receipt, act, attempt, opts) do
    with :ok <- verify(receipt, act, attempt, opts),
         {store, reference} <- Keyword.fetch!(opts, :store),
         {:ok, _revision} <- store.put_new(reference, key(receipt), claimed(act, attempt)) do
      # This exact-bound receipt is a one-use capability, not a provider secret.
      # Its durable claim must transition to consumed before the adapter runs.
      {:ok, receipt}
    else
      _ -> refused()
    end
  rescue
    _ -> refused()
  catch
    :exit, _ -> refused()
  end

  @doc false
  @spec consume(CheckoutReceipt.t(), Act.t(), Attempt.t(), keyword()) ::
          :ok | {:error, :invalid_execution_capability}
  def consume(receipt, act, attempt, opts) do
    expected = claimed(act, attempt)

    with :ok <- verify(receipt, act, attempt, opts),
         {store, reference} <- Keyword.fetch!(opts, :store),
         {:ok, %{revision: revision, value: ^expected}} <- store.fetch(reference, key(receipt)),
         {:ok, _revision} <-
           store.compare_and_swap(reference, key(receipt), revision, %{
             expected
             | status: :consumed
           }) do
      :ok
    else
      _ -> {:error, :invalid_execution_capability}
    end
  rescue
    _ -> {:error, :invalid_execution_capability}
  catch
    :exit, _ -> {:error, :invalid_execution_capability}
  end

  @spec verify(CheckoutReceipt.t(), Act.t(), Attempt.t(), keyword()) :: :ok | {:error, term()}
  defp verify(%CheckoutReceipt{} = receipt, %Act{} = act, %Attempt{} = attempt, opts) do
    expected =
      act
      |> CheckoutReceipt.binding(attempt, ref())
      |> Map.merge(%{
        domain_ref: Keyword.fetch!(opts, :domain_ref),
        now: System.system_time(:millisecond)
      })

    with :ok <-
           CheckoutReceipt.verify(
             receipt,
             Keyword.fetch!(opts, :checkout_receipt_secret),
             expected
           ),
         {:ok, _candidate} <- Binding.candidate(act),
         true <-
           attempt.act_ref == act.ref and attempt.executor_ref == act.executor_ref and
             attempt.material_digest == act.material_digest do
      :ok
    else
      _ -> {:error, :invalid_execution_capability}
    end
  end

  defp verify(_, _, _, _), do: {:error, :invalid_execution_capability}

  @spec key(CheckoutReceipt.t()) :: tuple()
  defp key(receipt),
    do: {:managed_checkout, receipt.domain_ref, receipt.attempt_ref, receipt.grant_nonce_digest}

  @spec claimed(Act.t(), Attempt.t()) :: map()
  defp claimed(act, attempt),
    do: %{status: :claimed, act_digest: Act.digest(act), attempt_digest: Attempt.digest(attempt)}

  @spec refused() :: {:error, :ambiguous, map()}
  defp refused,
    do:
      {:error, :ambiguous,
       %{evidence: [], details_ref: "spectre:managed:capability-checkout-refused:v1"}}
end
