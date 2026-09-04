defmodule Spectre.GovernedAct.Transition.Admission.Presentation do
  @moduledoc """
  Replays the consent material bound to an admitted Act.

  Presentation preparation, its governed show Act and the later approval
  Evidence remain separate records. This validator rebuilds that chain at the
  Act's commit time and returns the exact Evidence basis consumed by Admission.
  """

  alias Spectre.{Act, Candidate, Evidence, Presentation}
  alias Spectre.GovernedAct.State

  @doc false
  @spec validate(State.t(), Candidate.t(), Act.t(), [Evidence.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def validate(
        %State{} = projection,
        %Candidate{class: "presentation.show"} = candidate,
        %Act{} = act,
        _evidence
      ) do
    with {:ok, presentation_ref} <- Presentation.show_presentation_ref(candidate.consequence),
         {:ok, presentation} <- Map.fetch(projection.presentations, presentation_ref),
         :ok <- Presentation.validate_show(candidate, presentation),
         :ok <- Presentation.validate_show(act, presentation),
         true <- presentation.prepared_at <= act.committed_at do
      {:ok, []}
    else
      :error -> {:error, {:act_presentation_not_found, act.ref}}
      false -> {:error, {:act_presentation_show_precedes_preparation, act.ref}}
      {:error, reason} -> {:error, {:invalid_presentation_show_act, act.ref, reason}}
    end
  end

  def validate(
        %State{},
        %Candidate{presentation_ref: nil},
        %Act{presentation_ref: nil},
        _evidence
      ),
      do: {:ok, []}

  def validate(%State{} = projection, %Candidate{} = candidate, %Act{} = act, evidence) do
    case Map.fetch(projection.presentations, act.presentation_ref) do
      {:ok, presentation} ->
        with :ok <- Presentation.validate_candidate(candidate, presentation),
             true <- presentation.prepared_at <= act.committed_at,
             {:ok, approval_refs, basis_refs} <-
               validate_approval(
                 projection,
                 presentation,
                 evidence,
                 act.committed_at,
                 act.ref
               ),
             true <-
               presentation.candidate_binding_ref ==
                 Candidate.presentation_binding_ref(candidate, approval_refs),
             :ok <- required_evidence_declared(basis_refs, candidate.evidence_refs) do
          {:ok, basis_refs}
        else
          false -> {:error, {:act_presentation_binding_mismatch, act.ref}}
          {:error, _reason} = error -> error
        end

      :error ->
        {:error, {:act_presentation_not_found, act.ref, act.presentation_ref}}
    end
  end

  defp validate_approval(projection, presentation, evidence, time, act_ref) do
    classification =
      Presentation.classify_responses(
        presentation,
        projection.acts,
        Map.values(projection.outcomes),
        evidence,
        time
      )

    case classification do
      {:contradicted, _approval_refs, _basis_refs} ->
        {:error, {:act_presentation_approval_contradicted, act_ref}}

      {:supported, approval_refs, basis_refs} ->
        {:ok, approval_refs, basis_refs}

      {:missing, _approval_refs, _basis_refs} ->
        {:error, {:act_presentation_approval_missing, act_ref}}

      {:unqualified, _approval_refs, _basis_refs} ->
        {:error, {:act_presentation_approval_not_current_or_final, act_ref}}
    end
  end

  defp required_evidence_declared(required_refs, declared_refs) do
    case required_refs -- declared_refs do
      [] -> :ok
      missing -> {:error, {:recognition_basis_not_declared, missing}}
    end
  end
end
