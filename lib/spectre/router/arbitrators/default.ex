defmodule Spectre.Router.Arbitrators.Default do
  @moduledoc """
  Default evidence arbitrator for Spectre routers.
  """

  @behaviour Spectre.Router.Arbitrator

  alias Spectre.Router.Arbitration
  alias Spectre.Router.Candidate
  alias Spectre.Router.LLMClassifier

  @defaults [
    classifier_accept: 0.93,
    classifier_margin: 0.08,
    embedding_accept: 0.84,
    embedding_margin: 0.05,
    bag_accept: 0.72,
    jaro_accept: 0.9,
    conflict: :llm,
    no_decision: :llm
  ]

  @impl Spectre.Router.Arbitrator
  def decide(%Arbitration{} = arbitration, opts) do
    opts = Keyword.merge(@defaults, opts)
    candidates = eligible_candidates(arbitration.candidates, opts)

    case select_candidate(candidates) do
      %Candidate{} = candidate -> {:ok, Candidate.to_route(candidate, arbitration.labels)}
      nil -> fallback_decision(candidates, arbitration, opts)
    end
  end

  @doc """
  Returns the normal arbitration decision together with a privacy-safe,
  deterministic explanation of thresholds, eligibility, and precedence.
  """
  @spec explain(Arbitration.t(), keyword()) :: {term(), map()}
  def explain(%Arbitration{} = arbitration, opts) do
    merged = Keyword.merge(@defaults, opts)
    decision = decide(arbitration, opts)

    evidence =
      Enum.map(arbitration.candidates, fn candidate ->
        candidate_explanation(candidate, merged, decision)
      end)

    {decision,
     %{
       version: 1,
       outcome: decision_outcome(decision),
       reason: decision_reason(decision, arbitration.candidates, merged),
       thresholds: threshold_configuration(merged),
       candidates: evidence
     }}
  end

  @spec candidate_explanation(Candidate.t(), keyword(), term()) :: map()
  defp candidate_explanation(%Candidate{} = candidate, opts, decision) do
    {eligible?, rejection, thresholds} = eligibility(candidate, opts)

    %{
      provider: candidate.provider,
      label: candidate.label,
      scope: candidate.scope,
      score: candidate.score,
      margin: candidate.margin,
      strength: candidate.strength,
      accepted?: candidate.accepted? == true,
      eligible?: eligible?,
      rejection_reason: rejection,
      required: thresholds,
      winner?: winner?(candidate, decision)
    }
  end

  defp eligibility(%Candidate{handler: nil}, _opts), do: {false, :missing_handler, %{}}

  defp eligibility(%Candidate{metadata: %{router_adapter: %{} = adapter}} = candidate, _opts) do
    required = Map.get(adapter, :required, %{})

    if candidate.accepted? == true do
      {true, nil, required}
    else
      {false, Map.get(adapter, :threshold_reason, :provider_rejected), required}
    end
  end

  defp eligibility(%Candidate{accepted?: accepted?}, _opts) when accepted? != true,
    do: {false, :provider_rejected, %{}}

  defp eligibility(%Candidate{strength: :hard, accepted?: true}, _opts),
    do: {true, nil, %{strength: :hard}}

  defp eligibility(%Candidate{provider: :local_classifier} = candidate, opts) do
    required = %{
      score: Keyword.fetch!(opts, :classifier_accept),
      margin: Keyword.fetch!(opts, :classifier_margin)
    }

    threshold_eligibility(candidate, required)
  end

  defp eligibility(%Candidate{provider: :embedding} = candidate, opts) do
    required = %{
      score: Keyword.fetch!(opts, :embedding_accept),
      margin: Keyword.fetch!(opts, :embedding_margin),
      margin_optional?: true
    }

    threshold_eligibility(candidate, required)
  end

  defp eligibility(%Candidate{provider: :bag} = candidate, opts),
    do: threshold_eligibility(candidate, %{score: Keyword.fetch!(opts, :bag_accept)})

  defp eligibility(%Candidate{provider: :jaro} = candidate, opts),
    do: threshold_eligibility(candidate, %{score: Keyword.fetch!(opts, :jaro_accept)})

  defp eligibility(%Candidate{provider: :llm_classifier}, _opts), do: {true, nil, %{}}

  defp eligibility(%Candidate{score: score}, _opts) do
    if is_nil(score) or (number?(score) and score > 0),
      do: {true, nil, %{}},
      else: {false, :non_positive_score, %{}}
  end

  defp threshold_eligibility(candidate, required) do
    case {score_threshold_met?(candidate, required), margin_threshold_met?(candidate, required)} do
      {false, _margin} -> {false, :score_below_threshold, required}
      {true, false} -> {false, :margin_below_threshold, required}
      {true, true} -> {true, nil, required}
    end
  end

  defp score_threshold_met?(candidate, required),
    do: number?(candidate.score) and candidate.score >= required.score

  defp margin_threshold_met?(_candidate, required) when not is_map_key(required, :margin),
    do: true

  defp margin_threshold_met?(%Candidate{margin: nil}, %{margin_optional?: true}), do: true

  defp margin_threshold_met?(candidate, required),
    do: number?(candidate.margin) and candidate.margin >= required.margin

  defp winner?(candidate, {:ok, route}) do
    candidate.provider == route.strategy and candidate.label == route.label and
      (candidate.scope || :agent) == route.scope
  end

  defp winner?(_candidate, _decision), do: false

  defp decision_outcome({:ok, _route}), do: :route
  defp decision_outcome({:llm, _arbitration}), do: :llm
  defp decision_outcome({:clarify, _text}), do: :clarify
  defp decision_outcome({:error, _reason}), do: :error

  defp decision_reason({:llm, _}, _candidates, _opts), do: :llm_fallback
  defp decision_reason({:clarify, _}, _candidates, _opts), do: :no_eligible_candidate
  defp decision_reason({:error, _}, _candidates, _opts), do: :arbitration_error

  defp decision_reason({:ok, route}, candidates, opts) do
    eligible = eligible_candidates(candidates, opts)
    winner = Enum.find(eligible, &winner?(&1, {:ok, route}))
    selected_reason(winner, eligible)
  end

  defp selected_reason(%Candidate{strength: :hard}, _eligible), do: :hard_evidence

  defp selected_reason(%Candidate{} = winner, eligible) do
    if agreement_winner?(winner, eligible),
      do: :provider_agreement,
      else: provider_reason(winner.provider)
  end

  defp selected_reason(nil, _eligible), do: :best_candidate

  defp provider_reason(:local_classifier), do: :classifier_precedence
  defp provider_reason(:embedding), do: :embedding_precedence
  defp provider_reason(provider) when provider in [:bag, :jaro], do: :similarity_precedence
  defp provider_reason(_adapter), do: :best_candidate

  defp agreement_winner?(winner, candidates) do
    candidates
    |> Enum.filter(&(candidate_identity(&1) == candidate_identity(winner)))
    |> Enum.map(& &1.provider)
    |> Enum.uniq()
    |> length() >= 2
  end

  defp threshold_configuration(opts) do
    opts
    |> Keyword.take([
      :classifier_accept,
      :classifier_margin,
      :embedding_accept,
      :embedding_margin,
      :bag_accept,
      :jaro_accept,
      :conflict,
      :no_decision
    ])
    |> Map.new()
  end

  @spec select_candidate([Candidate.t()]) :: Candidate.t() | nil
  defp select_candidate(candidates) do
    adapter_slots? = not Enum.any?(candidates, &(&1.provider == :llm_classifier))

    [
      fn -> best_by_strength(candidates, :hard) end,
      fn -> agreement(candidates) end,
      fn -> adapter_in_bands(candidates, [:hard, :strong], adapter_slots?) end,
      fn -> confident_provider(candidates, :local_classifier) end,
      fn -> confident_provider(candidates, :embedding) end,
      fn -> adapter_in_bands(candidates, [:medium], adapter_slots?) end,
      fn -> confident_provider(candidates, :semantic_cache_exact) end,
      fn -> confident_provider(candidates, :semantic_cache_search) end,
      fn -> confident_provider(candidates, :semantic_cache) end,
      fn -> confident_provider(candidates, :bag) end,
      fn -> confident_provider(candidates, :jaro) end,
      fn -> adapter_in_bands(candidates, [:weak], adapter_slots?) end
    ]
    |> Enum.find_value(& &1.())
  end

  @spec fallback_decision([Candidate.t()], Arbitration.t(), keyword()) ::
          {:ok, Spectre.Route.t()}
          | {:llm, Arbitration.t()}
          | {:clarify, String.t()}
          | {:error, term()}
  defp fallback_decision(candidates, arbitration, opts) do
    if conflict?(candidates) do
      conflict_decision(candidates, arbitration, opts)
    else
      no_conflict_decision(candidates, arbitration, opts)
    end
  end

  @spec conflict_decision([Candidate.t()], Arbitration.t(), keyword()) ::
          {:ok, Spectre.Route.t()} | {:llm, Arbitration.t()} | {:clarify, String.t()}
  defp conflict_decision(candidates, arbitration, opts) do
    case Keyword.get(opts, :conflict) do
      :llm -> maybe_llm(arbitration, opts)
      _other -> {:ok, Candidate.to_route(List.first(candidates), arbitration.labels)}
    end
  end

  @spec no_conflict_decision([Candidate.t()], Arbitration.t(), keyword()) ::
          {:ok, Spectre.Route.t()}
          | {:llm, Arbitration.t()}
          | {:clarify, String.t()}
          | {:error, term()}
  defp no_conflict_decision([best | _rest], arbitration, _opts),
    do: {:ok, Candidate.to_route(best, arbitration.labels)}

  defp no_conflict_decision([], arbitration, opts) do
    case Keyword.get(opts, :no_decision) do
      :llm -> maybe_llm(arbitration, opts)
      :clarify -> clarify()
      _other -> {:error, :no_route_candidate}
    end
  end

  @spec maybe_llm(Arbitration.t(), keyword()) ::
          {:llm, Arbitration.t()} | {:clarify, String.t()}
  defp maybe_llm(arbitration, opts) do
    if llm_ready?(opts), do: {:llm, arbitration}, else: clarify()
  end

  @spec clarify() :: {:clarify, String.t()}
  defp clarify, do: {:clarify, "Please rephrase your request."}

  @spec eligible_candidates([Candidate.t()], keyword()) :: [Candidate.t()]
  defp eligible_candidates(candidates, opts) do
    candidates
    |> Enum.filter(&eligible?(&1, opts))
    |> Enum.sort_by(&candidate_order_key/1)
  end

  defp eligible?(%Candidate{handler: nil}, _opts), do: false
  defp eligible?(%Candidate{accepted?: accepted?}, _opts) when accepted? != true, do: false
  defp eligible?(%Candidate{strength: :hard, accepted?: true}, _opts), do: true

  defp eligible?(%Candidate{provider: :local_classifier, score: score, margin: margin}, opts) do
    number?(score) and score >= Keyword.fetch!(opts, :classifier_accept) and
      number?(margin) and margin >= Keyword.fetch!(opts, :classifier_margin)
  end

  defp eligible?(%Candidate{provider: :embedding, score: score, margin: margin}, opts) do
    number?(score) and score >= Keyword.fetch!(opts, :embedding_accept) and
      (is_nil(margin) or margin >= Keyword.fetch!(opts, :embedding_margin))
  end

  defp eligible?(%Candidate{provider: :llm_classifier, accepted?: true}, _opts), do: true

  defp eligible?(%Candidate{provider: :bag, score: score}, opts) do
    number?(score) and score >= Keyword.fetch!(opts, :bag_accept)
  end

  defp eligible?(%Candidate{provider: :jaro, score: score}, opts) do
    number?(score) and score >= Keyword.fetch!(opts, :jaro_accept)
  end

  defp eligible?(%Candidate{accepted?: true, score: score}, _opts), do: is_nil(score) or score > 0
  defp eligible?(_candidate, _opts), do: false

  defp best_by_strength(candidates, strength) do
    Enum.find(candidates, &(&1.strength == strength))
  end

  defp agreement(candidates) do
    candidates
    |> Enum.group_by(&candidate_identity/1)
    |> Enum.flat_map(fn {_identity, same_route} ->
      providers = same_route |> Enum.map(& &1.provider) |> Enum.uniq()

      if length(providers) >= 2 do
        [Enum.min_by(same_route, &candidate_order_key/1)]
      else
        []
      end
    end)
    |> Enum.min_by(&candidate_order_key/1, fn -> nil end)
  end

  defp confident_provider(candidates, provider) do
    Enum.find(candidates, &(&1.provider == provider))
  end

  defp adapter_in_bands(_candidates, _bands, false), do: nil

  defp adapter_in_bands(candidates, bands, true) do
    Enum.find(candidates, &(adapter_band(&1) in bands))
  end

  defp conflict?(candidates) do
    candidates
    |> Enum.map(&candidate_identity/1)
    |> Enum.uniq()
    |> length() > 1
  end

  defp candidate_identity(%Candidate{} = candidate), do: {candidate.scope, candidate.label}

  defp candidate_order_key(%Candidate{} = candidate) do
    {
      -strength_rank(candidate.strength),
      -candidate_provider_rank(candidate),
      adapter_order(candidate),
      -(candidate.score || 0.0),
      -(candidate.margin || 0.0),
      stable_id(candidate.scope),
      stable_id(candidate.label),
      stable_id(candidate.flow),
      stable_id(candidate.owner),
      stable_id(candidate.provider)
    }
  end

  defp stable_id(nil), do: ""

  defp stable_id(value) when is_atom(value) or is_binary(value) or is_integer(value),
    do: to_string(value)

  defp stable_id(value), do: inspect(value, limit: 4, printable_limit: 120)

  defp strength_rank(:hard), do: 4
  defp strength_rank(:strong), do: 3
  defp strength_rank(:medium), do: 2
  defp strength_rank(:weak), do: 1
  defp strength_rank(_strength), do: 0

  defp candidate_provider_rank(%Candidate{} = candidate) do
    case adapter_band(candidate) do
      band when band in [:hard, :strong] -> 55
      :medium -> 35
      :weak -> 15
      nil -> provider_rank(candidate.provider) * 10
    end
  end

  defp adapter_band(%Candidate{metadata: %{router_adapter: %{band: band}}})
       when band in [:hard, :strong, :medium, :weak],
       do: band

  defp adapter_band(%Candidate{}), do: nil

  defp adapter_order(%Candidate{metadata: %{router_adapter: %{order: order}}})
       when is_integer(order) and order >= 0,
       do: order

  defp adapter_order(%Candidate{}), do: 0

  defp provider_rank(:llm_classifier), do: 6
  defp provider_rank(:local_classifier), do: 5
  defp provider_rank(:embedding), do: 4
  defp provider_rank(:semantic_cache), do: 3
  defp provider_rank(:semantic_cache_exact), do: 3
  defp provider_rank(:semantic_cache_search), do: 3
  defp provider_rank(:bag), do: 2
  defp provider_rank(:jaro), do: 2
  defp provider_rank(:regex), do: 1
  defp provider_rank(_provider), do: 0

  defp number?(value), do: is_integer(value) or is_float(value)

  @spec llm_ready?(keyword()) :: boolean()
  defp llm_ready?(opts) do
    LLMClassifier.enabled?(opts) and LLMClassifier.available?(opts)
  end
end
