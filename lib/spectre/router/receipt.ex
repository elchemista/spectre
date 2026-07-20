defmodule Spectre.Router.Receipt do
  @moduledoc """
  Privacy-safe summary of one router-only evaluation.

  A receipt records the selected route, sanitized provider-call outcomes and
  durations, and whether an LLM adapter was actually invoked. It deliberately
  excludes input text, prompts, model output, candidate matches, and handlers
  so evaluation artifacts can be shared without silently becoming conversation
  logs.
  """

  alias Spectre.Router.Candidate
  alias Spectre.Router.Context

  defstruct [
    :outcome,
    :label,
    :scope,
    :strategy,
    :accepted?,
    :llm_called?,
    :duration_us,
    :error,
    :arbitration,
    attempts: [],
    candidates: [],
    provider_calls: [],
    trace_codes: []
  ]

  @type outcome :: :route | :clarify | :unknown | :error

  @type attempt :: %{
          required(:provider) => atom(),
          required(:result) => atom(),
          optional(:label) => atom() | nil,
          optional(:reason) => atom() | nil
        }

  @type candidate_summary :: %{
          required(:provider) => atom(),
          required(:label) => atom() | nil,
          required(:accepted?) => boolean(),
          required(:score) => number() | nil,
          required(:margin) => number() | nil,
          required(:strength) => atom(),
          optional(:eligible?) => boolean(),
          optional(:winner?) => boolean(),
          optional(:rejection_reason) => atom() | nil,
          optional(:required) => map()
        }

  @type provider_call :: %{
          required(:provider) => atom(),
          required(:outcome) => atom(),
          required(:duration_us) => non_neg_integer(),
          required(:invoked?) => boolean(),
          optional(:purpose) => atom()
        }

  @type t :: %__MODULE__{
          outcome: outcome(),
          label: atom() | nil,
          scope: Spectre.Definition.scope() | nil,
          strategy: atom() | nil,
          accepted?: boolean(),
          llm_called?: boolean(),
          duration_us: non_neg_integer(),
          error: atom() | nil,
          arbitration: map() | nil,
          attempts: [attempt()],
          candidates: [candidate_summary()],
          provider_calls: [provider_call()],
          trace_codes: [atom()]
        }

  @doc """
  Builds a receipt from a completed routing context.
  """
  @spec from_context(Context.t(), non_neg_integer()) :: t()
  def from_context(%Context{} = context, duration_us) do
    from_context(context, duration_us, nil)
  end

  @doc false
  @spec from_context(Context.t(), non_neg_integer(), [map()] | nil) :: t()
  def from_context(%Context{} = context, duration_us, provider_calls) do
    traces = context.traces |> safe_list() |> Enum.reverse()

    candidates =
      context.candidates
      |> safe_list()
      |> Enum.reverse()
      |> Enum.filter(&match?(%Candidate{}, &1))

    route = if match?(%Spectre.Route{}, context.route), do: context.route
    known_labels = known_labels(context.labels)
    safe_provider_calls = sanitize_provider_calls(provider_calls)
    arbitration = sanitize_arbitration(context.arbitration, known_labels)
    explanations = candidate_explanations(arbitration)

    %__MODULE__{
      outcome: route_outcome(route),
      label: route && safe_label(route.label, known_labels),
      scope: route && safe_scope(route.scope),
      strategy: route && safe_atom(route.strategy),
      accepted?: not is_nil(route) and route.accepted? == true,
      llm_called?: llm_called?(traces, candidates, provider_calls, safe_provider_calls),
      duration_us: safe_duration(duration_us),
      attempts: attempts(traces, candidates, known_labels),
      candidates: Enum.map(candidates, &candidate_summary(&1, known_labels, explanations)),
      arbitration: arbitration,
      provider_calls: safe_provider_calls,
      trace_codes: Enum.map(traces, &trace_code/1),
      error: context.errors |> safe_list() |> List.first() |> reason_code()
    }
  end

  @doc """
  Builds an error receipt when the router pipeline cannot complete.
  """
  @spec from_error(term(), non_neg_integer()) :: t()
  def from_error(reason, duration_us), do: from_error(reason, duration_us, nil)

  @doc false
  @spec from_error(term(), non_neg_integer(), [map()] | nil) :: t()
  def from_error(reason, duration_us, provider_calls) do
    safe_provider_calls = sanitize_provider_calls(provider_calls)

    %__MODULE__{
      outcome: :error,
      accepted?: false,
      llm_called?: llm_called?([], [], provider_calls, safe_provider_calls),
      duration_us: safe_duration(duration_us),
      error: reason_code(reason),
      provider_calls: safe_provider_calls
    }
  end

  @spec route_outcome(Spectre.Route.t() | nil) :: outcome()
  defp route_outcome(%Spectre.Route{strategy: :clarify}), do: :clarify

  defp route_outcome(%Spectre.Route{accepted?: true, handler: handler})
       when not is_nil(handler),
       do: :route

  defp route_outcome(%Spectre.Route{}), do: :unknown
  defp route_outcome(nil), do: :unknown

  @spec llm_called?([term()], [Candidate.t()], [map()] | nil, [provider_call()]) :: boolean()
  defp llm_called?(traces, candidates, nil, _safe_provider_calls) do
    Enum.any?(traces, &match?({:llm_arbitration_started, _labels}, &1)) or
      Enum.any?(candidates, &(&1.provider == :llm_classifier))
  end

  defp llm_called?(_traces, _candidates, _provider_calls, safe_provider_calls) do
    Enum.any?(safe_provider_calls, fn call ->
      call.provider == :llm and call.invoked?
    end)
  end

  @spec attempts([term()], [Candidate.t()], MapSet.t()) :: [attempt()]
  defp attempts(traces, candidates, known_labels) do
    traced =
      traces |> Enum.flat_map(&trace_attempt/1) |> Enum.map(&sanitize_attempt(&1, known_labels))

    traced_providers = MapSet.new(traced, & &1.provider)

    inferred =
      candidates
      |> Enum.reject(&MapSet.member?(traced_providers, &1.provider))
      |> Enum.map(&candidate_attempt(&1, known_labels))

    traced ++ inferred
  end

  @spec trace_attempt(term()) :: [attempt()]
  defp trace_attempt(:regex_skip), do: [%{provider: :regex, result: :miss}]

  defp trace_attempt({:regex_accept, route}),
    do: [route_attempt(:regex, :accepted, route)]

  defp trace_attempt({:local_skip, reason}),
    do: [reason_attempt(:local_classifier, :skipped, reason)]

  defp trace_attempt({:local_error, reason}),
    do: [reason_attempt(:local_classifier, :error, reason)]

  defp trace_attempt({:local_accept, route}),
    do: [route_attempt(:local_classifier, :accepted, route)]

  defp trace_attempt({:local_uncertain, route}),
    do: [route_attempt(:local_classifier, :uncertain, route)]

  defp trace_attempt({:local_label_not_routeable, route}),
    do: [route_attempt(:local_classifier, :unrouteable, route)]

  defp trace_attempt({:embedding_skip, reason}),
    do: [reason_attempt(:embedding, :skipped, reason)]

  defp trace_attempt({:cache_skip, reason}),
    do: [reason_attempt(:semantic_cache_exact, :skipped, reason)]

  defp trace_attempt({:cache_accept, route}),
    do: [route_attempt(:semantic_cache_exact, :accepted, route)]

  defp trace_attempt({:semantic_skip, reason}),
    do: [reason_attempt(:semantic_cache_search, :skipped, reason)]

  defp trace_attempt({:semantic_accept, route}),
    do: [route_attempt(:semantic_cache_search, :accepted, route)]

  defp trace_attempt({:llm_arbitration_started, _labels}),
    do: [%{provider: :llm_classifier, result: :started}]

  defp trace_attempt({:llm_arbitrated, route}),
    do: [route_attempt(:llm_classifier, :accepted, route)]

  defp trace_attempt({:llm_arbitration_failed, reason}),
    do: [reason_attempt(:llm_classifier, :error, reason)]

  defp trace_attempt({:llm_arbitration_skipped, reason}),
    do: [reason_attempt(:llm_classifier, :skipped, reason)]

  defp trace_attempt(_trace), do: []

  @spec route_attempt(atom(), atom(), Spectre.Route.t() | term()) :: attempt()
  defp route_attempt(provider, result, %Spectre.Route{label: label}) do
    %{provider: provider, result: result, label: safe_atom(label)}
  end

  defp route_attempt(provider, result, _route), do: %{provider: provider, result: result}

  @spec reason_attempt(atom(), atom(), term()) :: attempt()
  defp reason_attempt(provider, result, reason) do
    %{provider: provider, result: result, reason: reason_code(reason)}
  end

  @spec candidate_summary(Candidate.t(), MapSet.t(), map()) :: candidate_summary()
  defp candidate_summary(%Candidate{} = candidate, known_labels, explanations) do
    summary = %{
      provider: safe_atom(candidate.provider) || :unknown,
      label: safe_label(candidate.label, known_labels),
      accepted?: candidate.accepted? == true,
      score: safe_number(candidate.score),
      margin: safe_number(candidate.margin),
      strength: safe_atom(candidate.strength) || :unknown
    }

    summary = Map.merge(summary, Map.get(explanations, candidate_key(candidate), %{}))

    case safe_scope(candidate.scope) do
      nil -> summary
      scope -> Map.put(summary, :scope, scope)
    end
  end

  @spec sanitize_arbitration(term(), MapSet.t()) :: map() | nil
  defp sanitize_arbitration(explanation, known_labels) when is_map(explanation) do
    candidates =
      explanation
      |> Map.get(:candidates, [])
      |> safe_list()
      |> Enum.map(&sanitize_candidate_explanation(&1, known_labels))

    %{
      version: Map.get(explanation, :version, 1),
      outcome: safe_atom(Map.get(explanation, :outcome)) || :unknown,
      reason: safe_atom(Map.get(explanation, :reason)) || :unknown,
      thresholds: sanitize_thresholds(Map.get(explanation, :thresholds, %{})),
      candidates: candidates
    }
  end

  defp sanitize_arbitration(_explanation, _known_labels), do: nil

  defp sanitize_candidate_explanation(candidate, known_labels) when is_map(candidate) do
    %{
      provider: safe_atom(Map.get(candidate, :provider)) || :unknown,
      label: safe_label(Map.get(candidate, :label), known_labels),
      scope: safe_scope(Map.get(candidate, :scope)),
      score: safe_number(Map.get(candidate, :score)),
      margin: safe_number(Map.get(candidate, :margin)),
      strength: safe_atom(Map.get(candidate, :strength)) || :unknown,
      accepted?: Map.get(candidate, :accepted?) == true,
      eligible?: Map.get(candidate, :eligible?) == true,
      winner?: Map.get(candidate, :winner?) == true,
      rejection_reason: safe_atom(Map.get(candidate, :rejection_reason)),
      required: sanitize_thresholds(Map.get(candidate, :required, %{}))
    }
  end

  defp sanitize_candidate_explanation(_candidate, _known_labels), do: %{}

  defp sanitize_thresholds(thresholds) when is_map(thresholds) do
    thresholds
    |> Enum.filter(fn {key, value} ->
      is_atom(key) and (is_number(value) or is_boolean(value) or is_atom(value))
    end)
    |> Map.new()
  end

  defp sanitize_thresholds(_thresholds), do: %{}

  defp candidate_explanations(%{candidates: candidates}) do
    Map.new(candidates, fn candidate ->
      summary =
        Map.take(candidate, [:eligible?, :winner?, :rejection_reason, :required])

      {candidate_key(candidate), summary}
    end)
  end

  defp candidate_explanations(_arbitration), do: %{}

  defp candidate_key(candidate) do
    {Map.get(candidate, :provider), Map.get(candidate, :scope), Map.get(candidate, :label)}
  end

  @spec candidate_attempt(Candidate.t(), MapSet.t()) :: attempt()
  defp candidate_attempt(%Candidate{} = candidate, known_labels) do
    %{
      provider: safe_atom(candidate.provider) || :unknown,
      result: :candidate,
      label: safe_label(candidate.label, known_labels)
    }
  end

  @spec sanitize_attempt(attempt(), MapSet.t()) :: attempt()
  defp sanitize_attempt(attempt, known_labels) do
    Map.update(attempt, :label, nil, &safe_label(&1, known_labels))
  end

  @spec sanitize_provider_calls([map()] | nil) :: [provider_call()]
  defp sanitize_provider_calls(nil), do: []

  defp sanitize_provider_calls(provider_calls) when is_list(provider_calls) do
    Enum.map(provider_calls, &sanitize_provider_call/1)
  end

  defp sanitize_provider_calls(_provider_calls), do: []

  @spec sanitize_provider_call(map()) :: provider_call()
  defp sanitize_provider_call(call) when is_map(call) do
    summary = %{
      provider: safe_atom(Map.get(call, :provider)) || :unknown,
      outcome: safe_atom(Map.get(call, :outcome)) || :unknown,
      duration_us: safe_duration(Map.get(call, :duration_us)),
      invoked?: Map.get(call, :invoked?) == true
    }

    case safe_atom(Map.get(call, :purpose)) do
      nil -> summary
      purpose -> Map.put(summary, :purpose, purpose)
    end
  end

  defp sanitize_provider_call(_call) do
    %{provider: :unknown, outcome: :unknown, duration_us: 0, invoked?: false}
  end

  @spec trace_code(term()) :: atom()
  defp trace_code(trace) when is_atom(trace), do: trace

  defp trace_code(trace) when is_tuple(trace) and tuple_size(trace) > 0 do
    case elem(trace, 0) do
      code when is_atom(code) -> code
      _other -> :unknown_trace
    end
  end

  defp trace_code(_trace), do: :unknown_trace

  @spec reason_code(term()) :: atom() | nil
  defp reason_code(nil), do: nil
  defp reason_code(reason) when is_atom(reason), do: reason

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: reason_code(elem(reason, 0))

  defp reason_code(%{reason: reason}), do: reason_code(reason)
  defp reason_code(_reason), do: :unknown_error

  @spec safe_atom(term()) :: atom() | nil
  defp safe_atom(value) when is_atom(value), do: value
  defp safe_atom(_value), do: nil

  @spec known_labels(term()) :: MapSet.t()
  defp known_labels(labels) do
    labels
    |> safe_list()
    |> Enum.filter(&is_atom/1)
    |> MapSet.new()
    |> MapSet.put(:unknown)
  end

  @spec safe_label(term(), MapSet.t()) :: atom() | nil
  defp safe_label(label, known_labels) when is_atom(label) do
    if MapSet.member?(known_labels, label), do: label
  end

  defp safe_label(_label, _known_labels), do: nil

  @spec safe_scope(term()) :: Spectre.Definition.scope() | nil
  defp safe_scope(:agent), do: :agent

  defp safe_scope({:skill, id}) when is_atom(id) or is_binary(id) or is_integer(id),
    do: {:skill, id}

  defp safe_scope(_scope), do: nil

  @spec safe_number(term()) :: number() | nil
  defp safe_number(value) when is_number(value), do: value
  defp safe_number(_value), do: nil

  @spec safe_duration(term()) :: non_neg_integer()
  defp safe_duration(value) when is_integer(value) and value >= 0, do: value
  defp safe_duration(_value), do: 0

  @spec safe_list(term()) :: list()
  defp safe_list(value) when is_list(value), do: value
  defp safe_list(_value), do: []
end
