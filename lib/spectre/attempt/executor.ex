defmodule Spectre.Attempt.Executor do
  @moduledoc """
  Executes one already-committed governed Act.

  Implementations are Zone X adapters. They receive no authority to alter the
  Act; `capability` is the short-lived host handle released only after the
  corresponding Attempt has been committed.

  Results cross back into the governed record layer, so they contain only
  validated `Spectre.Evidence` and an opaque, non-empty `details_ref`. Raw
  provider replies, exceptions, credentials and reusable bearer material are
  not valid result metadata. Evidence may be empty only for an ambiguous result.
  """

  alias Spectre.{Act, Attempt, Evidence, Outcome, Portable}
  alias Spectre.Attempt.Binding

  @evidence_fields [
    :ref,
    :proposition,
    :stance,
    :provenance,
    :parent_refs,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :assumptions,
    :labels,
    :payload,
    :payload_ref,
    :provisional
  ]
  @outcome_evidence_fields [
    :ref,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :labels,
    :payload,
    :payload_ref
  ]

  @type observation :: %{
          required(:evidence) => Evidence.t() | [Evidence.t()],
          required(:details_ref) => String.t()
        }

  @type result ::
          {:ok, observation()}
          | {:error, :failed, observation()}
          | {:error, :definitive_no_effect, observation()}
          | {:error, :ambiguous, observation()}

  @doc "Builds executor-attested Evidence with the Act and Attempt bindings forced."
  @spec evidence(Act.t(), Attempt.t(), integer(), map() | keyword()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def evidence(%Act{} = act, %Attempt{} = attempt, observed_at, attrs)
      when is_integer(observed_at) do
    with {:ok, act} <- Act.new(act),
         {:ok, attempt} <- Attempt.new(attempt),
         :ok <- validate_cause(act, attempt, observed_at),
         {:ok, attrs} <-
           Portable.normalize_attrs(attrs, @evidence_fields, :executor_evidence),
         attrs =
           attrs
           |> Map.put_new(:provenance, :observed)
           |> Map.put_new(:parent_refs, []),
         :ok <- validate_parent_boundary(attrs.provenance, attrs.parent_refs, act) do
      attrs
      |> Map.put(:issuer_ref, act.executor_ref)
      |> Map.put(:source_ref, act.executor_ref)
      |> Map.put(:observed_at, observed_at)
      |> Map.put(:bindings, Binding.evidence_bindings(act, attempt))
      |> Evidence.new()
    end
  end

  def evidence(_act, _attempt, _observed_at, _attrs),
    do: {:error, :invalid_executor_evidence}

  @doc "Builds a final Evidence attestation for one exact Outcome classification."
  @spec outcome_evidence(
          Act.t(),
          Attempt.t(),
          Outcome.status(),
          integer(),
          map() | keyword()
        ) :: {:ok, Evidence.t()} | {:error, term()}
  def outcome_evidence(%Act{} = act, %Attempt{} = attempt, status, observed_at, attrs)
      when status in [:succeeded, :failed, :definitive_no_effect, :ambiguous] and
             is_integer(observed_at) do
    with {:ok, act} <- Act.new(act),
         {:ok, attempt} <- Attempt.new(attempt),
         {:ok, attrs} <-
           Portable.normalize_attrs(
             attrs,
             @outcome_evidence_fields,
             :executor_outcome_evidence
           ) do
      attrs
      |> Map.merge(%{
        proposition: Outcome.proposition(status, act.ref, attempt.ref, act.executor_contract_ref),
        stance: Outcome.evidence_stance(status),
        provenance: :observed,
        parent_refs: [],
        assumptions: [],
        provisional: false
      })
      |> then(&evidence(act, attempt, observed_at, &1))
    end
  end

  def outcome_evidence(_act, _attempt, _status, _observed_at, _attrs),
    do: {:error, :invalid_executor_outcome_evidence}

  @doc "Returns the stable executor identity accepted by this adapter."
  @callback executor_ref() :: String.t()

  @doc "Returns the immutable contract revision implemented by this adapter."
  @callback contract_ref() :: String.t()

  @callback execute(Act.t(), Attempt.t(), term(), keyword()) :: result()

  defp validate_cause(act, attempt, observed_at) do
    case Binding.mismatch(attempt, act) do
      {:act_ref, _expected, _actual} ->
        {:error, :executor_evidence_act_mismatch}

      {:executor_ref, _expected, _actual} ->
        {:error, :executor_evidence_executor_mismatch}

      {:material_digest, _expected, _actual} ->
        {:error, :executor_evidence_material_mismatch}

      nil ->
        if observed_at < attempt.started_at,
          do: {:error, :executor_evidence_precedes_attempt},
          else: :ok
    end
  end

  defp validate_parent_boundary(:observed, [], _act), do: :ok

  defp validate_parent_boundary(provenance, [_first | _rest] = parents, act)
       when provenance in [:derived, :generated] do
    if MapSet.subset?(MapSet.new(parents), MapSet.new(act.evidence_refs)),
      do: :ok,
      else: {:error, :executor_evidence_parent_outside_act_inputs}
  end

  defp validate_parent_boundary(_provenance, _parents, _act),
    do: {:error, :invalid_executor_evidence_lineage}
end
