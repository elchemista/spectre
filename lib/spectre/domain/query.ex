defmodule Spectre.Domain.Query do
  @moduledoc """
  Narrow reads performed where the verified projection lives.

  Only results cross the Domain mailbox, never its full history. Scoped reads
  validate the same authentication/generation fence as commands; callers cannot
  supply executable selectors or callbacks to the trusted process.
  """

  alias Spectre.Attempt.Runner.Recovery
  alias Spectre.Authority.View, as: AuthorityView
  alias Spectre.Domain.{Context, Transaction}
  alias Spectre.{Governance, Mandate, Presentation}
  alias Spectre.Scope.View, as: ScopeView

  @doc false
  def head(state), do: Map.take(state.projection, [:domain_ref, :revision, :head_digest])

  @doc false
  def attempt_result(state, decision, act),
    do: Recovery.from_projection(state.projection, decision, act)

  @doc false
  def scoped(state, scope, query) do
    with {:ok, context, _opening} <- Context.validate_scope(state, scope.context) do
      read(state, %{scope | context: context}, query)
    end
  end

  defp read(state, scope, :view),
    do: ScopeView.from_projection(state.projection, Spectre.Scope.ref(scope))

  defp read(state, scope, :authority) do
    with {:ok, now} <- Transaction.trusted_recorded_at(state),
         do: AuthorityView.from_projection(state.projection, scope, now)
  end

  defp read(state, scope, {:records, key})
       when key in [:acts, :duties, :erasures, :declassifications] do
    ScopeView.records(state.projection, Spectre.Scope.ref(scope), key)
  end

  defp read(state, _scope, {:presentation, ref}) do
    case Map.fetch(state.projection.presentations, ref) do
      {:ok, %Presentation{} = presentation} -> {:ok, presentation}
      {:ok, _invalid} -> {:error, {:invalid_presentation_record, ref}}
      :error -> {:error, {:presentation_not_found, ref}}
    end
  end

  defp read(state, _scope, {:mandate, ref}) when is_binary(ref) and ref != "" do
    case Map.fetch(state.projection.mandates, ref) do
      {:ok, %Mandate{} = mandate} -> {:ok, mandate}
      {:ok, _invalid} -> {:error, {:invalid_mandate_record, ref}}
      :error -> {:error, {:mandate_not_found, ref}}
    end
  end

  defp read(_state, _scope, {:mandate, _ref}), do: {:error, :invalid_mandate_ref}

  defp read(state, scope, {:outcome_scope, act_ref}) do
    scope_ref = Spectre.Scope.ref(scope)

    case Map.fetch(state.projection.acts, act_ref) do
      {:ok, %{scope_ref: ^scope_ref}} -> {:ok, :ok}
      {:ok, _act} -> {:error, :outcome_scope_mismatch}
      :error -> {:error, {:outcome_act_not_found, act_ref}}
    end
  end

  defp read(state, scope, {:late_observation, attempt_ref}) do
    projection = state.projection

    with {:ok, attempt} <- Map.fetch(projection.attempts, attempt_ref),
         {:ok, act} <- Map.fetch(projection.acts, attempt.act_ref),
         true <- act.scope_ref === Spectre.Scope.ref(scope),
         true <- attempt.executor_ref === act.executor_ref,
         true <- attempt.material_digest === act.material_digest do
      {:ok, {act, attempt}}
    else
      :error -> {:error, {:late_observation_attempt_not_found, attempt_ref}}
      false -> {:error, :late_observation_cause_mismatch}
    end
  end

  defp read(state, _scope, {:outcome, ref}) do
    case Map.fetch(state.projection.outcomes, ref) do
      {:ok, outcome} -> {:ok, outcome}
      :error -> {:error, {:corrected_outcome_not_found, ref}}
    end
  end

  # Derive the potentially large closure beside the history. Only the finished
  # Candidate leaves this process; Admission still verifies it at its own prefix.
  defp read(state, scope, {:erasure_candidate, request, candidate}) do
    Governance.request_erasure(scope, state.projection, request, candidate)
  end

  defp read(state, _scope, {:surface, revision}) do
    case Enum.filter(state.projection.catalog.surfaces, fn {_ref, surface} ->
           surface.revision == revision
         end) do
      [{_ref, surface}] -> {:ok, surface}
      [] -> {:error, {:historical_surface_not_found, revision}}
      _many -> {:error, {:ambiguous_surface_revision, revision}}
    end
  end

  defp read(_state, _scope, _query), do: {:error, :invalid_domain_query}
end
