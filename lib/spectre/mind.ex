defmodule Spectre.Mind do
  @moduledoc """
  Capability-free boundary for application deliberation.

  A mind may route, plan, call application code and construct Candidates.  It
  receives no Grant, broker or ledger writer, and its result remains only a
  proposal until each Candidate independently crosses the kernel boundary.
  """

  alias Spectre.Evidence.Derivation
  alias Spectre.{Adapter, Candidate, Disclosure, Evidence, Portable, SubmissionContext}
  alias Spectre.Mind.Turn

  @candidate_fields [
    :identity_key,
    :class,
    :consequence,
    :row,
    :requested_mandate_ref,
    :executor_ref,
    :accountable_ref,
    :subject_refs,
    :target_refs,
    :purpose_ref,
    :purpose_params,
    :consent,
    :evidence_refs,
    :disclosure,
    :presentation_ref,
    :meter_requests,
    :executor_contract_ref,
    :observation_window_ms
  ]
  @evidence_fields [
    :ref,
    :proposition,
    :stance,
    :provenance,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :bindings,
    :assumptions,
    :labels,
    :payload,
    :payload_ref,
    :provisional
  ]

  @callback ref() :: String.t()
  @callback deliberate(Turn.t(), keyword()) ::
              {:ok, Candidate.t() | map() | keyword() | [Candidate.t() | map() | keyword()]}
              | {:error, term()}

  @doc "Invokes a mind and normalizes its output to scope-bound Candidates."
  @spec deliberate(module(), Turn.t(), keyword()) ::
          {:ok, [Candidate.t()]} | {:error, term()}
  def deliberate(module, turn, opts \\ [])

  def deliberate(module, %Turn{} = turn, opts)
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, {^module, mind_ref}} <- resolve(module),
         true <- mind_ref == turn.mind_ref,
         {:ok, result} <- safe_deliberate(module, turn, opts),
         {:ok, candidates} <- normalize_result(result),
         :ok <- scope_bound(candidates, turn.scope_ref),
         :ok <- proposers_bound(candidates, turn.authenticated_principal_ref),
         :ok <- evidence_bound(candidates, turn.evidence_refs),
         :ok <- disclosures_bound(candidates, turn) do
      {:ok, candidates}
    else
      false -> {:error, {:mind_turn_binding_mismatch, module}}
      {:error, _reason} = error -> error
    end
  end

  def deliberate(_module, _turn, _opts), do: {:error, :invalid_mind_deliberation}

  @doc "Builds a Candidate whose trusted proposer and Scope come from the sealed Turn."
  @spec candidate(Turn.t(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def candidate(%Turn{} = turn, attrs), do: candidate(turn, [], attrs)
  def candidate(_turn, _attrs), do: {:error, :invalid_mind_candidate}

  @doc "Builds a Candidate that may also cite validated derivations produced from the same Turn."
  @spec candidate(Turn.t(), Evidence.t() | [Evidence.t()], map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def candidate(%Turn{} = turn, derivations, attrs) do
    with {:ok, _context} <- turn_context(turn),
         {:ok, derivations} <- normalize_turn_derivations(turn, derivations),
         available = turn.evidence ++ derivations,
         available_refs = Enum.map(available, & &1.ref),
         {:ok, attrs} <- Portable.normalize_attrs(attrs, @candidate_fields, :mind_candidate),
         attrs = Map.put_new(attrs, :evidence_refs, available_refs),
         attrs =
           Map.merge(attrs, %{
             proposer_ref: turn.authenticated_principal_ref,
             scope_ref: turn.scope_ref
           }),
         {:ok, candidate} <- Candidate.new(attrs),
         :ok <- evidence_bound([candidate], available_refs),
         :ok <- disclosures_bound([candidate], turn, derivations) do
      {:ok, candidate}
    end
  end

  def candidate(_turn, _derivations, _attrs), do: {:error, :invalid_mind_candidate}

  @doc "Builds derived or generated Evidence bound to the exact sealed Turn context."
  @spec evidence(Turn.t(), integer(), map() | keyword()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def evidence(%Turn{} = turn, observed_at, attrs) when is_integer(observed_at) do
    with {:ok, context} <- turn_context(turn),
         true <- observed_at >= turn.opened_at,
         {:ok, attrs} <- Portable.normalize_attrs(attrs, @evidence_fields, :mind_evidence),
         provenance = Map.get(attrs, :provenance, :generated),
         :ok <- derivation_provenance(provenance),
         {:ok, labels} <-
           Derivation.conservative_labels(turn.evidence, Map.get(attrs, :labels, [])),
         {:ok, bindings} <-
           SubmissionContext.merge_evidence_bindings(
             context,
             Map.get(attrs, :bindings, %{})
           ) do
      attrs
      |> Map.put(:issuer_ref, turn.mind_ref)
      |> Map.put(:source_ref, turn.mind_ref)
      |> Map.put(:provenance, provenance)
      |> Map.put(:parent_refs, turn.evidence_refs)
      |> Map.put(:observed_at, observed_at)
      |> Map.put(:bindings, bindings)
      |> Map.put(:labels, labels)
      |> Evidence.new()
    else
      false -> {:error, :mind_evidence_precedes_turn}
      {:error, _reason} = error -> error
    end
  end

  def evidence(_turn, _observed_at, _attrs), do: {:error, :invalid_mind_evidence}

  @doc false
  @spec resolve(module()) :: {:ok, {module(), String.t()}} | {:error, term()}
  def resolve(module) when is_atom(module) and module not in [nil, true, false] do
    with :ok <- validate_adapter(module),
         {:ok, ref} <- safe_ref(module),
         :ok <- Portable.validate_ref(ref, :mind_ref) do
      {:ok, {module, ref}}
    else
      {:error, _reason} = error -> error
    end
  end

  def resolve(module), do: {:error, {:mind_unavailable, module}}

  defp validate_adapter(module) do
    case Adapter.validate(module, ref: 0, deliberate: 2) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:mind_unavailable, module}}
    end
  end

  defp safe_ref(module) do
    case Adapter.invoke(module, :ref, []) do
      {:ok, ref} when is_binary(ref) and ref != "" -> {:ok, ref}
      {:ok, _invalid} -> {:error, {:invalid_mind_ref, module}}
      {:error, _reason} -> {:error, {:mind_ref_failed, module}}
    end
  end

  defp turn_context(%Turn{} = turn) do
    with {:ok, context} <- SubmissionContext.from_evidence_bindings(turn.context_bindings),
         true <- context.ref == turn.submission_context_ref,
         true <- context.domain_ref == turn.domain_ref,
         true <- context.scope_ref == turn.scope_ref,
         true <-
           context.authenticated_principal_ref == turn.authenticated_principal_ref do
      {:ok, context}
    else
      false -> {:error, :mind_turn_context_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp derivation_provenance(provenance) when provenance in [:derived, :generated], do: :ok

  defp derivation_provenance(provenance),
    do: {:error, {:invalid_mind_evidence_provenance, provenance}}

  defp safe_deliberate(module, turn, opts) do
    case Adapter.invoke(module, :deliberate, [turn, opts]) do
      {:ok, {:ok, result}} ->
        {:ok, result}

      {:ok, {:error, _reason} = error} ->
        error

      {:ok, _invalid} ->
        {:error, {:invalid_mind_result, module}}

      {:error, {:adapter_callback_exception, _, _, exception}} ->
        {:error, {:mind_failed, module, exception}}

      {:error, {:adapter_callback_failure, _, _, kind}} ->
        {:error, {:mind_failed, module, kind}}
    end
  end

  defp normalize_result(result) when is_list(result) do
    if Keyword.keyword?(result), do: normalize_one(result), else: normalize_many(result)
  end

  defp normalize_result(result), do: normalize_one(result)

  defp normalize_many(result) do
    if result == [] do
      {:ok, []}
    else
      Enum.reduce_while(result, {:ok, []}, fn value, {:ok, candidates} ->
        case Candidate.new(value) do
          {:ok, candidate} -> {:cont, {:ok, [candidate | candidates]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize_one(result) do
    with {:ok, candidate} <- Candidate.new(result), do: {:ok, [candidate]}
  end

  defp scope_bound(candidates, scope_ref) do
    case Enum.find(candidates, &(&1.scope_ref != scope_ref)) do
      nil -> :ok
      candidate -> {:error, {:mind_candidate_scope_mismatch, candidate.ref, scope_ref}}
    end
  end

  defp proposers_bound(candidates, principal_ref) do
    case Enum.find(candidates, &(&1.proposer_ref != principal_ref)) do
      nil -> :ok
      candidate -> {:error, {:mind_candidate_proposer_mismatch, candidate.ref, principal_ref}}
    end
  end

  defp evidence_bound(candidates, evidence_refs) do
    available = MapSet.new(evidence_refs)

    case Enum.find(candidates, fn candidate ->
           not MapSet.subset?(MapSet.new(candidate.evidence_refs), available)
         end) do
      nil -> :ok
      candidate -> {:error, {:mind_candidate_evidence_outside_turn, candidate.ref}}
    end
  end

  defp disclosures_bound(candidates, turn) do
    disclosures_bound(candidates, turn, [])
  end

  defp disclosures_bound(candidates, turn, derivations) do
    evidence_index = Map.new(turn.evidence ++ derivations, &{&1.ref, &1})
    derived_refs = MapSet.new(derivations, & &1.ref)

    case Enum.find(
           candidates,
           &(not disclosure_bound?(&1, turn, evidence_index, derived_refs))
         ) do
      nil -> :ok
      candidate -> {:error, {:mind_candidate_disclosure_mismatch, candidate.ref}}
    end
  end

  defp disclosure_bound?(
         %Candidate{row: %{disclose: false}, disclosure: nil},
         _turn,
         _evidence_index,
         _derived_refs
       ),
       do: true

  defp disclosure_bound?(
         %Candidate{disclosure: %Disclosure{} = disclosure},
         turn,
         evidence_index,
         derived_refs
       ) do
    Disclosure.verify_sources(disclosure, evidence_index) == :ok and
      labels_cover?(disclosure.labels, turn.context_labels) and
      disclosure_covers_turn?(disclosure.source_evidence_refs, turn, derived_refs)
  end

  defp disclosure_bound?(_candidate, _turn, _evidence_index, _derived_refs), do: false

  defp disclosure_covers_turn?(source_refs, turn, derived_refs) do
    source_refs == turn.evidence_refs or
      Enum.any?(source_refs, &MapSet.member?(derived_refs, &1))
  end

  defp labels_cover?(actual, required) do
    actual_refs = MapSet.new(actual, & &1.ref)
    required_refs = MapSet.new(required, & &1.ref)
    MapSet.subset?(required_refs, actual_refs)
  end

  defp normalize_turn_derivations(_turn, []), do: {:ok, []}

  defp normalize_turn_derivations(turn, %Evidence{} = evidence),
    do: normalize_turn_derivations(turn, [evidence])

  defp normalize_turn_derivations(turn, derivations) when is_list(derivations) do
    with {:ok, context} <- turn_context(turn) do
      derivations
      |> Enum.reduce_while({:ok, [], MapSet.new(turn.evidence_refs)}, fn value,
                                                                         {:ok, records, refs} ->
        with {:ok, evidence} <- Evidence.new(value),
             false <- MapSet.member?(refs, evidence.ref),
             :ok <- validate_turn_derivation(evidence, turn, context) do
          {:cont, {:ok, [evidence | records], MapSet.put(refs, evidence.ref)}}
        else
          true -> {:halt, {:error, :duplicate_mind_derivation}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, records, _refs} -> {:ok, Enum.reverse(records)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize_turn_derivations(_turn, _derivations),
    do: {:error, :invalid_mind_derivations}

  defp validate_turn_derivation(evidence, turn, context) do
    cond do
      evidence.provenance not in [:derived, :generated] ->
        {:error, {:invalid_derivation_provenance, evidence.provenance}}

      evidence.issuer_ref != turn.mind_ref or evidence.source_ref != turn.mind_ref ->
        {:error, {:mind_derivation_source_mismatch, evidence.ref}}

      evidence.observed_at < turn.opened_at ->
        {:error, {:mind_derivation_precedes_turn, evidence.ref}}

      true ->
        with :ok <- SubmissionContext.validate_evidence_bindings(context, evidence.bindings),
             do: Derivation.validate(evidence, turn.evidence)
    end
  end
end
