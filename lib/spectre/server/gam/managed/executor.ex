defmodule Spectre.Server.GAM.Managed.Executor do
  @moduledoc false
  @behaviour ExGAM.Attempt.Executor
  alias ExGAM, as: GAM
  alias Spectre.Server.GAM.{Effect, Managed}
  alias Spectre.Server.GAM.Managed.{Broker, Content, Payload}

  {:ok, principal} =
    GAM.Principal.new(%{kind: :service, attributes: %{"name" => "spectre-managed-executor-v1"}})

  @principal principal

  @doc false
  @spec principal() :: GAM.Principal.t()
  def principal, do: @principal
  @doc false
  @spec executor_ref() :: binary()
  @impl true
  def executor_ref, do: @principal.ref
  @doc false
  @spec contract_ref() :: binary()
  @impl true
  def contract_ref, do: "spectre:managed:executor-contract:v1"

  @impl true
  def execute(act, attempt, capability, opts) do
    case Broker.consume(capability, act, attempt, Keyword.get(opts, :broker, [])) do
      :ok ->
        execute_admitted(act, attempt, opts)

      {:error, _} ->
        {:error, :ambiguous,
         %{evidence: [], details_ref: "spectre:managed:execution-capability-refused:v1"}}
    end
  end

  @spec execute_admitted(GAM.Act.t(), GAM.Attempt.t(), keyword()) :: term()
  defp execute_admitted(act, attempt, opts) do
    case perform(act, opts) do
      {:ok, receipt} ->
        result(act, attempt, :succeeded, receipt, opts)

      {:error, status, reason} when status in [:failed, :definitive_no_effect] ->
        result(act, attempt, status, %{reason: public_reason(reason)}, opts)

      {:error, :ambiguous, _reason} ->
        {:error, :ambiguous, %{evidence: [], details_ref: "spectre:uncertain:" <> act.ref}}
    end
  end

  @spec perform(GAM.Act.t(), keyword()) :: {:ok, term()} | {:error, atom(), term()}
  defp perform(%{class: "presentation.show"} = act, opts) do
    material = act.consequence["presentation_show"]
    ref = material["presentation_ref"]

    case Content.shown(opts[:payload_store], material, opts[:domain_ref]) do
      {:ok, material} ->
        case Managed.Gate.show(opts[:gate], material, self(), act.ref) do
          :ok ->
            receive do
              {:spectre_managed_presented, ^ref} ->
                {:ok, %{shown: true}}

              {:spectre_managed_show_failed, ^ref, certainty, reason} ->
                {:error, certainty, reason}
            after
              opts[:show_timeout] -> {:error, :ambiguous, :presentation_not_acknowledged}
            end

          {:error, :ambiguous, reason} ->
            {:error, :ambiguous, reason}

          {:error, reason} ->
            {:error, :definitive_no_effect, reason}
        end

      {:error, reason} ->
        {:error, :definitive_no_effect, reason}
    end
  end

  defp perform(act, opts) do
    case Content.act(opts[:payload_store], act, opts[:domain_ref]) do
      {:ok, act} ->
        case prepare_effect(act, opts) do
          {:ok, effect, context} -> Effect.execute(effect, act.consequence["payload"], context)
          {:error, reason} -> {:error, :definitive_no_effect, reason}
        end

      {:error, reason} ->
        {:error, :definitive_no_effect, reason}
    end
  end

  @spec prepare_effect(GAM.Act.t(), keyword()) :: {:ok, Effect.t(), map()} | {:error, term()}
  defp prepare_effect(act, opts) do
    with {:ok, effect, context} <- Managed.execution(opts[:managed], act),
         {:ok, current} <- Effect.resolve(context.agent, effect.host_operation, %{}, context),
         true <- current.contract_ref == act.consequence["effect_contract_ref"] do
      {:ok, current, context}
    else
      false -> {:error, :effect_contract_changed}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :effect_preparation_failed}
  catch
    :exit, _ -> {:error, :managed_execution_unavailable}
  end

  @spec public_reason(term()) :: atom() | map()
  defp public_reason(reason) when is_atom(reason), do: reason

  defp public_reason(reason) do
    %{digest: ExGAM.Canonical.Value.digest!(reason)}
  end

  @spec result(GAM.Act.t(), GAM.Attempt.t(), atom(), term(), keyword()) :: term()
  defp result(act, attempt, status, receipt, opts) do
    with {:ok, receipt} <-
           Payload.protect(
             opts[:payload_store],
             receipt,
             Map.merge(Content.context(opts[:domain_ref], :receipt), %{
               act_ref: act.ref,
               attempt_ref: attempt.ref
             })
           ),
         {:ok, evidence} <-
           GAM.Attempt.Executor.outcome_evidence(
             act,
             attempt,
             status,
             System.system_time(:millisecond),
             payload: receipt
           ) do
      observation = %{evidence: [evidence], details_ref: "spectre:receipt:" <> act.ref}
      if status == :succeeded, do: {:ok, observation}, else: {:error, status, observation}
    end
  end
end
