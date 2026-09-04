defmodule Spectre.Attempt.Runner.Observation do
  @moduledoc false

  alias Spectre.{Act, Attempt, Evidence, Portable}
  alias Spectre.Attempt.Binding
  alias Spectre.Outcome.Attestation

  @statuses [:succeeded, :failed, :definitive_no_effect, :ambiguous]

  @type raw :: %{
          required(:status) => atom(),
          required(:evidence) => [Evidence.t()],
          required(:details_ref) => String.t()
        }
  @type t :: %{
          required(:status) => atom(),
          required(:evidence) => [Evidence.t()],
          required(:outcome_evidence) => [Evidence.t()],
          required(:observed_at) => non_neg_integer(),
          required(:details_ref) => String.t()
        }

  @spec normalize_late(
          atom(),
          map(),
          Act.t(),
          Attempt.t(),
          non_neg_integer()
        ) :: {:ok, t()} | {:error, term()}
  def normalize_late(status, metadata, act, attempt, observed_at)
      when status in @statuses and is_integer(observed_at) and observed_at >= 0 do
    with {:ok, act} <- Act.new(act),
         {:ok, attempt} <- Attempt.new(attempt),
         nil <- Binding.mismatch(attempt, act),
         true <- observed_at >= attempt.started_at,
         {:ok, evidence, details_ref} <- validate(metadata, act, attempt) do
      observation =
        %{status: status, evidence: evidence, details_ref: details_ref}
        |> classify(act, attempt, observed_at)

      {:ok, observation}
    else
      false -> {:error, :late_observation_cause_mismatch}
      {_field, _expected, _actual} -> {:error, :late_observation_cause_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def normalize_late(_status, _metadata, _act, _attempt, _observed_at),
    do: {:error, :invalid_late_observation}

  @spec normalize(atom(), term(), :broker | :executor, Act.t(), Attempt.t()) ::
          {:ok, raw()} | {:error, term()}
  def normalize(status, metadata, boundary, %Act{} = act, %Attempt{} = attempt)
      when status in @statuses and boundary in [:broker, :executor] do
    case validate(metadata, act, attempt) do
      {:ok, evidence, details_ref} ->
        {:ok, %{status: status, evidence: evidence, details_ref: details_ref}}

      {:error, _reason} ->
        boundary_failure(boundary, :invalid_metadata)
    end
  end

  @spec classify(
          raw(),
          Act.t(),
          Attempt.t(),
          non_neg_integer()
        ) :: t()
  def classify(
        %{status: :ambiguous, evidence: evidence} = observation,
        act,
        attempt,
        observed_at
      ) do
    causal = Enum.filter(evidence, &Attestation.causal?(&1, act, attempt, observed_at))

    Map.merge(observation, %{
      outcome_evidence: causal,
      observed_at: observed_at
    })
  end

  def classify(
        %{status: status, evidence: evidence} = observation,
        act,
        attempt,
        observed_at
      )
      when status in [:succeeded, :failed, :definitive_no_effect] do
    {supporting, causal, conflicting?} =
      Enum.reduce(evidence, {[], [], false}, fn item, {supporting, causal, conflicting?} ->
        supports? = Attestation.supports?(item, status, act, attempt, observed_at)
        causal? = supports? or Attestation.causal?(item, act, attempt, observed_at)

        {
          if(supports?, do: [item | supporting], else: supporting),
          if(causal?, do: [item | causal], else: causal),
          conflicting? or (causal? and not supports?)
        }
      end)

    if supporting != [] and not conflicting? do
      Map.merge(observation, %{
        outcome_evidence: Enum.reverse(supporting),
        observed_at: observed_at
      })
    else
      Map.merge(observation, %{
        status: :ambiguous,
        outcome_evidence: Enum.reverse(causal),
        observed_at: observed_at,
        details_ref: "spectre:attempt-boundary:unattested-outcome:v1"
      })
    end
  end

  @doc false
  @spec normalize_evidence(Evidence.t() | [Evidence.t()]) ::
          {:ok, [Evidence.t()]} | {:error, term()}
  def normalize_evidence(%Evidence{} = evidence) do
    with {:ok, evidence} <- Evidence.new(evidence), do: {:ok, [evidence]}
  end

  def normalize_evidence(evidence) when is_list(evidence) do
    evidence
    |> Enum.reduce_while({:ok, []}, fn
      %Evidence{} = item, {:ok, normalized} ->
        case Evidence.new(item) do
          {:ok, item} -> {:cont, {:ok, [item | normalized]}}
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_observation_evidence}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  def normalize_evidence(_evidence), do: {:error, :invalid_observation_evidence}

  @spec boundary_failure(:broker | :executor, atom()) ::
          {:ok, raw()}
  def boundary_failure(boundary, kind) do
    {:ok,
     %{
       status: :ambiguous,
       evidence: [],
       details_ref: boundary_details_ref(boundary, kind)
     }}
  end

  defp validate(%{evidence: evidence, details_ref: details_ref} = metadata, act, attempt)
       when not is_struct(metadata) do
    with true <- map_size(metadata) == 2,
         :ok <- Portable.validate_ref(details_ref, :details_ref),
         {:ok, evidence} <- normalize_evidence(evidence),
         :ok <- unique_evidence(evidence),
         :ok <- validate_boundary_evidence(evidence, act, attempt) do
      {:ok, evidence, details_ref}
    else
      false -> {:error, :invalid_observation_fields}
      {:error, _reason} = error -> error
    end
  end

  defp validate(_metadata, _act, _attempt), do: {:error, :invalid_observation_metadata}

  defp unique_evidence(evidence) do
    Enum.reduce_while(evidence, MapSet.new(), fn %Evidence{ref: ref}, refs ->
      if MapSet.member?(refs, ref) do
        {:halt, {:error, :duplicate_evidence}}
      else
        {:cont, MapSet.put(refs, ref)}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp validate_boundary_evidence(evidence, act, attempt) do
    allowed_parent_refs = MapSet.new(act.evidence_refs)

    Enum.reduce_while(evidence, :ok, fn item, :ok ->
      with :ok <- exact_attempt_bindings(item, act, attempt),
           :ok <- explicit_executor_lineage(item, allowed_parent_refs) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp exact_attempt_bindings(%Evidence{} = evidence, act, attempt) do
    expected = Binding.evidence_bindings(act, attempt)

    if evidence.bindings == expected,
      do: :ok,
      else: {:error, {:executor_evidence_binding_mismatch, evidence.ref}}
  end

  defp explicit_executor_lineage(%Evidence{provenance: :observed}, _allowed_parent_refs),
    do: :ok

  defp explicit_executor_lineage(
         %Evidence{provenance: provenance, parent_refs: [_first | _rest] = parents} = evidence,
         allowed_parent_refs
       )
       when provenance in [:derived, :generated] do
    if Enum.all?(parents, &MapSet.member?(allowed_parent_refs, &1)),
      do: :ok,
      else: {:error, {:executor_evidence_parent_outside_act_inputs, evidence.ref}}
  end

  defp explicit_executor_lineage(%Evidence{} = evidence, _allowed_parent_refs),
    do: {:error, {:invalid_executor_evidence_lineage, evidence.ref}}

  defp boundary_details_ref(boundary, kind)
       when boundary in [:broker, :executor] and
              kind in [:exception, :exit, :throw, :invalid_reply, :invalid_metadata] do
    "spectre:attempt-boundary:#{boundary}:#{kind}:v1"
  end
end
