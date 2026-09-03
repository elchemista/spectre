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

  alias Spectre.{Act, Attempt, Evidence, Portable}

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
      |> Map.put(:bindings, %{"act_ref" => act.ref, "attempt_ref" => attempt.ref})
      |> Evidence.new()
    end
  end

  def evidence(_act, _attempt, _observed_at, _attrs),
    do: {:error, :invalid_executor_evidence}

  @doc "Returns the stable executor identity accepted by this adapter."
  @callback executor_ref() :: String.t()

  @doc "Returns the immutable contract revision implemented by this adapter."
  @callback contract_ref() :: String.t()

  @callback execute(Act.t(), Attempt.t(), term(), keyword()) :: result()

  defp validate_cause(act, attempt, observed_at) do
    cond do
      attempt.act_ref != act.ref ->
        {:error, :executor_evidence_act_mismatch}

      attempt.executor_ref != act.executor_ref ->
        {:error, :executor_evidence_executor_mismatch}

      observed_at < attempt.started_at ->
        {:error, :executor_evidence_precedes_attempt}

      true ->
        :ok
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
