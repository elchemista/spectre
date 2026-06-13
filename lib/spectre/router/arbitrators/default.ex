defmodule Spectre.Router.Arbitrators.Default do
  @moduledoc """
  Default evidence arbitrator for Spectre routers.
  """

  @behaviour Spectre.Router.Arbitrator

  alias Spectre.Router.Arbitration
  alias Spectre.Router.Candidate

  @defaults [
    classifier_accept: 0.93,
    classifier_margin: 0.08,
    embedding_accept: 0.84,
    embedding_margin: 0.05,
    bag_accept: 0.72,
    jaro_accept: 0.9,
    conflict: :llm,
    no_decision: :clarify
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

  @spec select_candidate([Candidate.t()]) :: Candidate.t() | nil
  defp select_candidate(candidates) do
    [
      fn -> best_by_strength(candidates, :hard) end,
      fn -> agreement(candidates) end,
      fn -> confident_provider(candidates, :local_classifier) end,
      fn -> confident_provider(candidates, :embedding) end,
      fn -> confident_provider(candidates, :bag) end,
      fn -> confident_provider(candidates, :jaro) end
    ]
    |> Enum.find_value(& &1.())
  end

  @spec fallback_decision([Candidate.t()], Arbitration.t(), keyword()) ::
          {:ok, Spectre.Route.t()}
          | {:llm, Arbitration.t()}
          | {:clarify, String.t()}
          | {:error, term()}
  defp fallback_decision(candidates, arbitration, opts) do
    cond do
      conflict?(candidates) and Keyword.get(opts, :conflict) == :llm ->
        {:llm, arbitration}

      best = List.first(candidates) ->
        {:ok, Candidate.to_route(best, arbitration.labels)}

      Keyword.get(opts, :no_decision) == :clarify ->
        {:clarify, "Please rephrase your request."}

      true ->
        {:error, :no_route_candidate}
    end
  end

  @spec eligible_candidates([Candidate.t()], keyword()) :: [Candidate.t()]
  defp eligible_candidates(candidates, opts) do
    candidates
    |> Enum.filter(&eligible?(&1, opts))
    |> Enum.sort_by(&candidate_rank/1, :desc)
  end

  defp eligible?(%Candidate{handler: nil}, _opts), do: false
  defp eligible?(%Candidate{strength: :hard}, _opts), do: true

  defp eligible?(%Candidate{provider: :local_classifier, score: score, margin: margin}, opts) do
    number?(score) and score >= Keyword.fetch!(opts, :classifier_accept) and
      number?(margin) and margin >= Keyword.fetch!(opts, :classifier_margin)
  end

  defp eligible?(%Candidate{provider: :embedding, score: score, margin: margin}, opts) do
    number?(score) and score >= Keyword.fetch!(opts, :embedding_accept) and
      (is_nil(margin) or margin >= Keyword.fetch!(opts, :embedding_margin))
  end

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
    |> Enum.group_by(& &1.label)
    |> Enum.find_value(fn {_label, same_label} ->
      providers = same_label |> Enum.map(& &1.provider) |> Enum.uniq()

      if length(providers) >= 2 do
        Enum.max_by(same_label, &(&1.score || 0.0))
      end
    end)
  end

  defp confident_provider(candidates, provider) do
    Enum.find(candidates, &(&1.provider == provider))
  end

  defp conflict?(candidates) do
    candidates
    |> Enum.map(& &1.label)
    |> Enum.uniq()
    |> length() > 1
  end

  defp candidate_rank(%Candidate{} = candidate) do
    {strength_rank(candidate.strength), provider_rank(candidate.provider), candidate.score || 0.0}
  end

  defp strength_rank(:hard), do: 4
  defp strength_rank(:strong), do: 3
  defp strength_rank(:medium), do: 2
  defp strength_rank(:weak), do: 1
  defp strength_rank(_strength), do: 0

  defp provider_rank(:llm_classifier), do: 6
  defp provider_rank(:local_classifier), do: 5
  defp provider_rank(:embedding), do: 4
  defp provider_rank(:semantic_cache), do: 3
  defp provider_rank(:bag), do: 2
  defp provider_rank(:jaro), do: 2
  defp provider_rank(:regex), do: 1
  defp provider_rank(_provider), do: 0

  defp number?(value), do: is_integer(value) or is_float(value)
end
