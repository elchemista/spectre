defmodule Spectre.GovernedAct.View do
  @moduledoc """
  Pure read operations over folded governed state.

  The fold owns transitions; this module owns derived views and exact lookups.
  Keeping them separate prevents query convenience from becoming part of the
  authority state and lets the kernel, Domain facade and recovery reuse the
  same calculations without duplicating indexes or policy.
  """

  alias Spectre.GovernedAct.{MeterState, State}
  alias Spectre.Kernel.Authority.Facts
  alias Spectre.Kernel.Meter
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
  @spec meter_accounts(State.t(), String.t()) :: {:ok, Meter.accounts()} | {:error, term()}
  def meter_accounts(%State{} = state, mandate_ref)
      when is_binary(mandate_ref) and mandate_ref != "" do
    MeterState.accounts(state, mandate_ref)
  end

  def meter_accounts(%State{}, mandate_ref),
    do: {:error, {:invalid_meter_mandate_ref, mandate_ref}}

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

  @doc "Looks up one immutable governed Definition by its exact content reference."
  @spec definition(State.t(), String.t()) ::
          {:ok, Spectre.Definition.t()} | {:error, term()}
  def definition(%State{} = state, ref) when is_binary(ref) and ref != "" do
    case Map.fetch(state.catalog.definitions, ref) do
      {:ok, %Spectre.Definition{ref: ^ref} = definition} -> {:ok, definition}
      {:ok, _invalid} -> {:error, {:invalid_definition_record, ref}}
      :error -> {:error, {:definition_not_found, ref}}
    end
  end

  def definition(%State{}, ref), do: {:error, {:invalid_definition_ref, ref}}

  @doc "Looks up the durable Decision selected by a Candidate identity key."
  @spec candidate_decision(State.t(), String.t()) ::
          {:ok, Spectre.Decision.t()} | :not_found | {:error, term()}
  def candidate_decision(%State{} = state, identity_key)
      when is_binary(identity_key) and identity_key != "" do
    case Map.fetch(state.admissions, identity_key) do
      {:ok, %{decision_ref: decision_ref}} ->
        case Map.fetch(state.decisions, decision_ref) do
          {:ok, %Spectre.Decision{candidate_identity_key: ^identity_key} = decision} ->
            {:ok, decision}

          {:ok, _mismatch} ->
            {:error, {:candidate_identity_index_mismatch, identity_key, decision_ref}}

          :error ->
            {:error, {:candidate_identity_decision_not_found, identity_key, decision_ref}}
        end

      :error ->
        :not_found

      {:ok, _invalid} ->
        {:error, {:invalid_candidate_admission, identity_key}}
    end
  end

  def candidate_decision(%State{}, _identity_key),
    do: {:error, :invalid_candidate_identity_key}

  @doc "Looks up the Act paired with a durable Decision."
  @spec decision_act(State.t(), Spectre.Decision.t()) ::
          {:ok, Spectre.Act.t() | nil} | {:error, term()}
  def decision_act(%State{}, %Spectre.Decision{outcome: outcome}) when outcome != :admitted,
    do: {:ok, nil}

  def decision_act(
        %State{} = state,
        %Spectre.Decision{
          outcome: :admitted,
          ref: decision_ref,
          candidate_identity_key: identity_key
        }
      ) do
    with {:ok, %{decision_ref: ^decision_ref, act_ref: act_ref}} when is_binary(act_ref) <-
           Map.fetch(state.admissions, identity_key),
         {:ok, %Spectre.Act{decision_ref: ^decision_ref} = act} <- Map.fetch(state.acts, act_ref) do
      {:ok, act}
    else
      _missing_or_invalid -> {:error, {:admitted_decision_missing_act, decision_ref}}
    end
  end

  @doc "Checks an authenticated context against its durable Scope opening."
  @spec scope_context(State.t(), SubmissionContext.t()) ::
          {:ok, Opening.t()} | {:error, term()}
  def scope_context(%State{} = state, %SubmissionContext{} = context) do
    with {:ok, context} <- SubmissionContext.new(context),
         {:ok, %Opening{} = opening} <- Map.fetch(state.catalog.scopes, context.scope_ref),
         :ok <- match_scope_context(state, opening, context) do
      {:ok, opening}
    else
      :error -> {:error, {:scope_not_open, context.scope_ref}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_projected_scope, context.scope_ref}}
    end
  end

  def scope_context(%State{}, _context), do: {:error, :invalid_scope_context}

  defp match_scope_context(state, opening, context) do
    cond do
      context.domain_ref != state.domain_ref ->
        {:error, {:scope_context_domain_mismatch, context.scope_ref}}

      Opening.validate_context(opening, context) != :ok ->
        {:error, {:scope_context_binding_mismatch, context.scope_ref}}

      true ->
        :ok
    end
  end

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
    with {:ok, cause_key} <- Map.fetch(state.read_index.duties.by_ref, ref),
         {:ok, duty} <- Map.fetch(state.duties, cause_key) do
      {:ok, duty}
    else
      :error -> :not_found
    end
  end

  def duty(%State{}, _lookup), do: {:error, :invalid_duty_lookup}
end
