defmodule Spectre.GAM.Erasure.Analysis do
  @moduledoc """
  Pure causal analysis for payload erasure.

  The analysis consumes decoded governed records through `Analysis.Facts`.
  It derives the immutable closure affected by deleting a payload and remains
  conservative when execution may have touched the external payload store.
  """

  alias Spectre.GAM.{Erasure, Portable}
  alias Spectre.GAM.GovernedAct.Reads, as: Selection
  alias Spectre.GAM.Erasure.Analysis.{Closure, Execution, Facts}
  alias Spectre.GAM.Erasure.Index
  alias Spectre.GAM.GovernedAct.State

  @type input :: State.t() | Facts.t()
  @type payload_state :: Execution.payload_state()

  @doc "Derives the exact immutable erasure draft from the current fact prefix."
  @spec derive_request(input(), String.t(), String.t(), String.t(), integer()) ::
          {:ok, map()} | {:error, term()}
  def derive_request(input, target_ref, scope_ref, reason, requested_at)
      when is_binary(target_ref) and is_binary(scope_ref) and is_binary(reason) and
             is_integer(requested_at) do
    with {:ok, facts} <- Facts.coerce(input),
         {:ok, digest} <- payload_digest(target_ref),
         :ok <- Portable.validate_ref(scope_ref, :scope_ref),
         true <- reason != "",
         {:ok, affected_refs} <- Closure.affected_refs(facts, target_ref) do
      {:ok,
       %{
         target_ref: target_ref,
         target_digest: digest,
         scope_ref: scope_ref,
         affected_refs: affected_refs,
         reason: reason,
         reduces_verifiability: affected_refs != [],
         requested_at: requested_at
       }}
    else
      false -> {:error, :invalid_erasure_reason}
      {:error, _reason} = error -> error
    end
  end

  def derive_request(_input, _target_ref, _scope_ref, _reason, _requested_at),
    do: {:error, :invalid_erasure_analysis}

  @doc "Checks a supplied draft against the closure derivable at this exact prefix."
  @spec validate_request(input(), Erasure.t() | map() | keyword()) ::
          :ok | {:error, term()}
  def validate_request(input, request) do
    with {:ok, facts} <- Facts.coerce(input),
         {:ok, actual} <- Erasure.request_draft(request),
         {:ok, expected_attrs} <-
           derive_request(
             facts,
             actual["target_ref"],
             actual["scope_ref"],
             actual["reason"],
             actual["requested_at"]
           ),
         {:ok, expected} <- Erasure.request_draft(expected_attrs),
         true <- actual == expected do
      :ok
    else
      false -> {:error, :erasure_request_not_derived_from_prefix}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns every durable record causally affected by one payload."
  @spec affected_refs(input(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def affected_refs(input, target_ref) when is_binary(target_ref) do
    with {:ok, facts} <- Facts.coerce(input),
         {:ok, _digest} <- payload_digest(target_ref) do
      Closure.affected_refs(facts, target_ref)
    end
  end

  def affected_refs(_input, target_ref),
    do: {:error, {:invalid_erasable_payload_ref, target_ref}}

  @doc "Returns affected Evidence using the current dynamic causal closure."
  @spec affected_evidence_refs(input(), String.t()) ::
          {:ok, MapSet.t(String.t())} | {:error, term()}
  def affected_evidence_refs(input, target_ref) when is_binary(target_ref) do
    with {:ok, facts} <- Facts.coerce(input),
         {:ok, _digest} <- payload_digest(target_ref) do
      Closure.affected_evidence_refs(facts, target_ref)
    end
  end

  def affected_evidence_refs(_input, target_ref),
    do: {:error, {:invalid_erasable_payload_ref, target_ref}}

  @doc "Classifies whether deletion may have touched the named payload."
  @spec execution_state(input(), String.t()) :: {:ok, payload_state()} | {:error, term()}
  def execution_state(input, target_ref) when is_binary(target_ref) do
    with {:ok, facts} <- Facts.coerce(input),
         {:ok, _digest} <- payload_digest(target_ref) do
      if facts.availability_index,
        do:
          Selection.ensure(
            facts.availability_index.selection,
            {:row, :erasure_states, target_ref}
          )

      if indexed?(facts),
        do: {:ok, Map.get(facts.availability_index.states, target_ref, :live)},
        else: {:ok, Execution.state(facts, target_ref)}
    end
  end

  def execution_state(_input, target_ref),
    do: {:error, {:invalid_erasable_payload_ref, target_ref}}

  @doc "Rejects duplicate erasure while an earlier request may still have had effect."
  @spec requestable?(input(), String.t()) :: :ok | {:error, term()}
  def requestable?(input, target_ref) when is_binary(target_ref) do
    with {:ok, facts} <- Facts.coerce(input),
         {:ok, _digest} <- payload_digest(target_ref) do
      Execution.requestable?(facts, target_ref)
    end
  end

  def requestable?(_input, target_ref),
    do: {:error, {:invalid_erasable_payload_ref, target_ref}}

  @doc "Returns all Evidence made unusable by an attempted erasure."
  @spec unavailable_evidence_refs(input()) :: MapSet.t(String.t())
  def unavailable_evidence_refs(input) do
    case Facts.coerce(input) do
      {:ok, facts} -> unavailable(facts)
      {:error, :invalid_erasure_facts} -> MapSet.new()
    end
  end

  @doc "Returns the Evidence records that remain valid inputs after erasure."
  @spec available_evidence(input()) :: %{optional(String.t()) => Spectre.GAM.Evidence.t()}
  def available_evidence(%State{
        erasures: erasures,
        evidence: evidence,
        read_index: %{selection: nil}
      })
      when map_size(erasures) == 0, do: evidence

  def available_evidence(input) do
    case Facts.coerce(input) do
      {:ok, facts} ->
        unavailable = unavailable(facts)
        Map.reject(facts.evidence, fn {ref, _evidence} -> MapSet.member?(unavailable, ref) end)

      {:error, :invalid_erasure_facts} ->
        %{}
    end
  end

  @doc "Rejects reuse of Evidence whose causal payload may have been erased."
  @spec validate_evidence_available(input(), [String.t()]) :: :ok | {:error, term()}
  def validate_evidence_available(input, refs) when is_list(refs) do
    with {:ok, facts} <- Facts.coerce(input) do
      unavailable = unavailable(facts)

      case Enum.find(refs, &MapSet.member?(unavailable, &1)) do
        nil -> :ok
        ref -> {:error, {:evidence_unavailable_after_erasure, ref}}
      end
    end
  end

  def validate_evidence_available(_input, _refs),
    do: {:error, :invalid_evidence_availability_check}

  defp indexed?(%Facts{availability_index: nil}), do: false

  defp indexed?(%Facts{availability_index: %{selection: reads}} = facts) when not is_nil(reads) do
    Enum.each(facts.evidence, fn {ref, _} ->
      Selection.ensure(reads, {:row, :unavailable_evidence, ref})
    end)

    true
  end

  defp indexed?(facts), do: Index.complete?(facts.availability_index, facts)

  defp unavailable(facts) do
    if indexed?(facts),
      do: facts.availability_index.unavailable,
      else: Closure.unavailable_evidence_refs(facts)
  end

  @doc false
  @spec payload_digest(String.t()) :: {:ok, String.t()} | {:error, term()}
  def payload_digest("payload:" <> digest = target_ref) do
    if Portable.sha256_digest?(digest),
      do: {:ok, digest},
      else: {:error, {:invalid_erasable_payload_ref, target_ref}}
  end

  def payload_digest(target_ref), do: {:error, {:invalid_erasable_payload_ref, target_ref}}
end
