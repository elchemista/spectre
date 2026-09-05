defmodule Spectre.Attempt.Evidence do
  @moduledoc """
  Pure boundary rules for Evidence emitted during one executor Attempt.

  Builders, the untrusted execution reply boundary and the authoritative
  Domain command all use this module. It binds every record to the exact Act,
  Attempt and executor, and restricts derivation parents to the Evidence frozen
  in the Act. Looking up those parents and proving the derivation still belongs
  to the Domain command because it requires current ledger state.
  """

  alias Spectre.{Act, Attempt, Evidence}
  alias Spectre.Attempt.Binding

  @doc false
  @spec validate(Evidence.t(), Act.t(), Attempt.t()) :: :ok | {:error, term()}
  def validate(%Evidence{} = evidence, %Act{} = act, %Attempt{} = attempt) do
    with :ok <- validate_attempt(act, attempt) do
      validate_record(evidence, act, attempt, MapSet.new(act.evidence_refs))
    end
  end

  def validate(_evidence, _act, _attempt), do: {:error, :invalid_executor_evidence}

  @doc false
  @spec validate_all([Evidence.t()], Act.t(), Attempt.t()) :: :ok | {:error, term()}
  def validate_all(evidence, %Act{} = act, %Attempt{} = attempt) when is_list(evidence) do
    with :ok <- validate_attempt(act, attempt) do
      allowed_parents = MapSet.new(act.evidence_refs)

      validate_records(evidence, act, attempt, allowed_parents)
    end
  end

  def validate_all(_evidence, _act, _attempt), do: {:error, :invalid_executor_evidence}

  defp validate_records(evidence, act, attempt, allowed_parents) do
    Enum.reduce_while(evidence, :ok, fn
      %Evidence{} = record, :ok ->
        case validate_record(record, act, attempt, allowed_parents) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, :ok ->
        {:halt, {:error, :invalid_executor_evidence}}
    end)
  end

  @doc false
  @spec validate_attempt(Act.t(), Attempt.t()) :: :ok | {:error, term()}
  def validate_attempt(%Act{} = act, %Attempt{} = attempt) do
    case Binding.mismatch(attempt, act) do
      {:act_ref, _expected, _actual} -> {:error, :executor_evidence_act_mismatch}
      {:executor_ref, _expected, _actual} -> {:error, :executor_evidence_executor_mismatch}
      {:material_digest, _expected, _actual} -> {:error, :executor_evidence_material_mismatch}
      nil -> :ok
    end
  end

  def validate_attempt(_act, _attempt), do: {:error, :invalid_executor_evidence_cause}

  defp validate_record(evidence, act, attempt, allowed_parents) do
    cond do
      evidence.bindings != Binding.evidence_bindings(act, attempt) ->
        {:error, {:executor_evidence_binding_mismatch, evidence.ref}}

      evidence.source_ref != act.executor_ref or evidence.issuer_ref != act.executor_ref ->
        {:error, {:executor_evidence_source_mismatch, evidence.ref}}

      evidence.observed_at < attempt.started_at ->
        {:error, {:executor_evidence_before_attempt, evidence.ref}}

      true ->
        validate_lineage(evidence, allowed_parents)
    end
  end

  defp validate_lineage(evidence, allowed_parents) do
    cond do
      evidence.provenance == :observed and evidence.parent_refs != [] ->
        {:error, {:observed_executor_evidence_has_parents, evidence.ref}}

      evidence.provenance == :observed ->
        :ok

      evidence.provenance in [:derived, :generated] ->
        validate_derived_parents(evidence, allowed_parents)

      true ->
        {:error, {:invalid_executor_evidence_provenance, evidence.ref}}
    end
  end

  defp validate_derived_parents(evidence, allowed_parents) do
    cond do
      evidence.parent_refs == [] ->
        {:error, {:invalid_executor_evidence_lineage, evidence.ref}}

      not Enum.all?(evidence.parent_refs, &MapSet.member?(allowed_parents, &1)) ->
        {:error, {:executor_evidence_parent_outside_act_inputs, evidence.ref}}

      true ->
        :ok
    end
  end
end
