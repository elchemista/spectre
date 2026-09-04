defmodule Spectre.Domain.Startup do
  @moduledoc """
  Recovers an existing Domain or atomically installs its Genesis batch.

  Startup is separate from the long-lived Sequencer mailbox. It verifies host
  bootstrap anchors, content payload references and ambiguous first-append
  outcomes, then returns only a projection recovered from durable ledger state.
  """

  alias Spectre.Domain.{Bootstrap, Configuration, Recovery, Transaction}
  alias Spectre.Ledger.Writer
  alias Spectre.Payload.Store, as: PayloadStore

  @doc "Loads verified durable state, bootstrapping only when no ledger exists."
  @spec load(Configuration.t()) :: {:ok, Spectre.Domain.Projection.t()} | {:error, term()}

  def load(config) do
    case recover(config) do
      {:ok, projection} ->
        verify_recovered(config, projection)

      :not_found ->
        bootstrap(config)

      {:error, _reason} = error ->
        error
    end
  end

  defp bootstrap(config) do
    bootstrap_opts = Keyword.put(config.bootstrap_opts, :constitution, config.constitution)

    with {:ok, recorded_at} <- Transaction.trusted_now(config.clock),
         {:ok, prepared} <- Bootstrap.prepare(config.domain_ref, bootstrap_opts, recorded_at) do
      case append_bootstrap(
             config,
             prepared.batch_id,
             prepared.payloads,
             recorded_at,
             config.ambiguous_retries
           ) do
        :ok -> recover_bootstrapped(config)
        :conflict -> recover_bootstrapped(config)
        {:error, _reason} = error -> error
      end
    end
  end

  defp append_bootstrap(config, batch_id, payloads, recorded_at, ambiguous_retries) do
    with :ok <- Transaction.verify_payload_references(config.payload_store, payloads) do
      Writer.append(
        config.store,
        config.domain_ref,
        batch_id,
        payloads,
        0,
        Keyword.put(config.ledger_opts, :recorded_at, recorded_at)
      )
    end
    |> case do
      {:ok, _revision} ->
        :ok

      {:error, :conflict} ->
        :conflict

      {:error, :ambiguous} ->
        classify_bootstrap_ambiguity(
          config,
          batch_id,
          payloads,
          recorded_at,
          ambiguous_retries
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp classify_bootstrap_ambiguity(
         config,
         batch_id,
         payloads,
         recorded_at,
         ambiguous_retries
       ) do
    case Recovery.classify_ambiguous(
           config.store,
           config.domain_ref,
           batch_id,
           payloads,
           0,
           config.ledger_opts
         ) do
      {:ok, {:committed, _info}} ->
        :ok

      {:ok, :not_committed} when ambiguous_retries > 0 ->
        append_bootstrap(config, batch_id, payloads, recorded_at, ambiguous_retries - 1)

      {:ok, :not_committed} ->
        {:error, :ambiguous_bootstrap_unresolved}

      {:error, _reason} = error ->
        error
    end
  end

  defp recover_bootstrapped(config) do
    case recover(config) do
      {:ok, projection} ->
        verify_recovered(config, projection)

      :not_found ->
        {:error, :domain_bootstrap_not_durable}

      {:error, _reason} = error ->
        error
    end
  end

  defp recover(config) do
    Recovery.recover(
      config.store,
      config.domain_ref,
      config.constitution,
      config.ledger_opts
    )
  end

  defp verify_recovered(config, projection) do
    with :ok <-
           Bootstrap.verify_projection(projection, Configuration.verification_opts(config)),
         :ok <- PayloadStore.verify_live_references(config.payload_store, projection) do
      {:ok, projection}
    end
  end
end
