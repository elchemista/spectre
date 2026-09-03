defmodule Spectre.GovernedAct.View do
  @moduledoc """
  Pure read operations over folded governed state.

  The fold owns transitions; this module owns derived views and exact lookups.
  Keeping them separate prevents query convenience from becoming part of the
  authority state and lets the kernel, Domain facade and recovery reuse the
  same calculations without duplicating indexes or policy.
  """

  alias Spectre.GovernedAct.State
  alias Spectre.Kernel.Authority.Facts
  alias Spectre.Scope.Opening
  alias Spectre.SubmissionContext

  @doc "Returns the authority-only facts consumed by resolution."
  @spec authority(State.t()) :: Facts.t()
  def authority(%State{} = state), do: Facts.from_state(state)

  @doc "Returns Mandates blocked by unresolved Meter recontainment deficits."
  @spec blocked_mandate_refs(State.t()) :: MapSet.t(String.t())
  defdelegate blocked_mandate_refs(state), to: Facts

  @doc "Returns consequence digests held by unresolved containment Duties."
  @spec blocked_effect_digests(State.t()) :: MapSet.t(String.t())
  defdelegate blocked_effect_digests(state), to: Facts

  @doc "Returns physical Meter accounts for a logical Mandate revision."
  @spec meter_accounts(State.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def meter_accounts(%State{} = state, mandate_ref)
      when is_binary(mandate_ref) and mandate_ref != "" do
    with {:ok, owner_ref} <- Map.fetch(state.meter_owners, mandate_ref),
         {:ok, accounts} <- Map.fetch(state.meters, owner_ref) do
      {:ok, accounts}
    else
      :error -> {:error, {:meter_mandate_not_found, mandate_ref}}
    end
  end

  def meter_accounts(%State{}, mandate_ref),
    do: {:error, {:invalid_meter_mandate_ref, mandate_ref}}

  @doc "Builds a logical Meter view without copying physical account state."
  @spec meters(State.t()) :: map()
  def meters(%State{} = state) do
    Map.new(state.meter_owners, fn {mandate_ref, owner_ref} ->
      {mandate_ref, Map.fetch!(state.meters, owner_ref)}
    end)
  end

  @doc "Fetches an Evidence set in caller order."
  @spec evidence_set(State.t(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  def evidence_set(%State{} = state, refs) when is_list(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, found} ->
      case Map.fetch(state.evidence, ref) do
        {:ok, evidence} -> {:cont, {:ok, [evidence | found]}}
        :error -> {:halt, {:error, {:evidence_not_found, ref}}}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Enum.reverse(found)}
      {:error, _reason} = error -> error
    end
  end

  def evidence_set(_state, _refs), do: {:error, :invalid_evidence_refs}

  @doc "Checks an authenticated context against its durable Scope opening."
  @spec scope_context(State.t(), SubmissionContext.t()) ::
          {:ok, Opening.t()} | {:error, term()}
  def scope_context(%State{} = state, %SubmissionContext{} = context) do
    with {:ok, context} <- SubmissionContext.new(context),
         {:ok, %Opening{} = opening} <- Map.fetch(state.scopes, context.scope_ref) do
      cond do
        context.domain_ref != state.domain_ref or opening.domain_ref != context.domain_ref ->
          {:error, {:scope_context_domain_mismatch, context.scope_ref}}

        context.authenticated_principal_ref != opening.opened_by_ref ->
          {:error, {:scope_context_principal_mismatch, context.scope_ref}}

        context.authentication_ref != opening.authentication_ref ->
          {:error, {:scope_context_authentication_mismatch, context.scope_ref}}

        context.ingress_ref != opening.ingress_ref ->
          {:error, {:scope_context_ingress_mismatch, context.scope_ref}}

        context.channel_ref != opening.channel_ref ->
          {:error, {:scope_context_channel_mismatch, context.scope_ref}}

        context.session_ref != opening.session_ref ->
          {:error, {:scope_context_session_mismatch, context.scope_ref}}

        true ->
          {:ok, opening}
      end
    else
      :error -> {:error, {:scope_not_open, context.scope_ref}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_projected_scope, context.scope_ref}}
    end
  end

  def scope_context(%State{}, _context), do: {:error, :invalid_scope_context}

  @doc "Looks up a Duty by idempotent cause key or durable reference."
  @spec duty(State.t(), {:cause_key, term()} | {:ref, String.t()}) ::
          {:ok, Spectre.Duty.t()} | :not_found | {:error, :invalid_duty_lookup}
  def duty(%State{} = state, {:cause_key, cause_key}) when not is_nil(cause_key) do
    case Map.fetch(state.duties, cause_key) do
      {:ok, duty} -> {:ok, duty}
      :error -> :not_found
    end
  end

  def duty(%State{} = state, {:ref, ref}) when is_binary(ref) and ref != "" do
    with {:ok, cause_key} <- Map.fetch(state.duty_refs, ref),
         {:ok, duty} <- Map.fetch(state.duties, cause_key) do
      {:ok, duty}
    else
      :error -> :not_found
    end
  end

  def duty(%State{}, _lookup), do: {:error, :invalid_duty_lookup}
end
