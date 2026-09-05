defmodule Spectre.Attempt.Runner.Observation do
  @moduledoc false

  require Spectre.Portable

  alias Spectre.{Act, Attempt, Evidence, Outcome, Portable}
  alias Spectre.Attempt.Binding
  alias Spectre.Attempt.Evidence, as: AttemptEvidence
  alias Spectre.Outcome.Attestation

  @statuses Outcome.statuses()
  @definitive_statuses Outcome.definitive_statuses()

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
      when status in @statuses and Portable.is_non_negative_integer(observed_at) do
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
      when status in @definitive_statuses do
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
  @spec outcome(t(), Act.t(), Attempt.t(), String.t() | nil) ::
          {:ok, Outcome.t()} | {:error, term()}
  def outcome(observation, act, attempt, contradicts_outcome_ref \\ nil)

  def outcome(
        %{
          status: status,
          outcome_evidence: evidence,
          observed_at: observed_at,
          details_ref: details_ref
        },
        %Act{} = act,
        %Attempt{} = attempt,
        contradicts_outcome_ref
      )
      when is_list(evidence) do
    Outcome.new(%{
      act_ref: act.ref,
      attempt_ref: attempt.ref,
      status: status,
      evidence_refs: Enum.map(evidence, & &1.ref),
      observed_at: observed_at,
      details_ref: details_ref,
      contradicts_outcome_ref: contradicts_outcome_ref
    })
  end

  def outcome(_observation, _act, _attempt, _contradicts_outcome_ref),
    do: {:error, :invalid_attempt_observation}

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
    AttemptEvidence.validate_all(evidence, act, attempt)
  end

  defp boundary_details_ref(boundary, kind)
       when boundary in [:broker, :executor] and
              kind in [:exception, :exit, :throw, :invalid_reply, :invalid_metadata] do
    "spectre:attempt-boundary:#{boundary}:#{kind}:v1"
  end
end
