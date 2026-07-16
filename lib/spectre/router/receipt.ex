defmodule Spectre.Router.Receipt do
  @moduledoc """
  Privacy-safe summary of one router-only evaluation.

  A receipt records the selected route, provider attempts, and whether the LLM
  classifier was invoked. It deliberately excludes input text, prompts, model
  output, candidate matches, and handlers so evaluation artifacts can be
  shared without silently becoming conversation logs.
  """

  alias Spectre.Router.Candidate
  alias Spectre.Router.Context

  defstruct [
    :outcome,
    :label,
    :strategy,
    :accepted?,
    :llm_called?,
    :duration_us,
    :error,
    attempts: [],
    candidates: [],
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
          required(:strength) => atom()
        }

  @type t :: %__MODULE__{
          outcome: outcome(),
          label: atom() | nil,
          strategy: atom() | nil,
          accepted?: boolean(),
          llm_called?: boolean(),
          duration_us: non_neg_integer(),
          error: atom() | nil,
          attempts: [attempt()],
          candidates: [candidate_summary()],
          trace_codes: [atom()]
        }

  @doc """
  Builds a receipt from a completed routing context.
  """
  @spec from_context(Context.t(), non_neg_integer()) :: t()
  def from_context(%Context{} = context, duration_us) do
    traces = Enum.reverse(context.traces || [])
    candidates = Enum.reverse(context.candidates || [])
    route = context.route

    %__MODULE__{
      outcome: route_outcome(route),
      label: route && route.label,
      strategy: route && route.strategy,
      accepted?: not is_nil(route) and route.accepted? == true,
      llm_called?: llm_called?(traces, candidates),
      duration_us: duration_us,
      attempts: attempts(traces, candidates),
      candidates: Enum.map(candidates, &candidate_summary/1),
      trace_codes: Enum.map(traces, &trace_code/1),
      error: context.errors |> List.first() |> reason_code()
    }
  end

  @doc """
  Builds an error receipt when the router pipeline cannot complete.
  """
  @spec from_error(term(), non_neg_integer()) :: t()
  def from_error(reason, duration_us) do
    %__MODULE__{
      outcome: :error,
      accepted?: false,
      llm_called?: false,
      duration_us: duration_us,
      error: reason_code(reason)
    }
  end

  @spec route_outcome(Spectre.Route.t() | nil) :: outcome()
  defp route_outcome(%Spectre.Route{strategy: :clarify}), do: :clarify

  defp route_outcome(%Spectre.Route{accepted?: true, handler: handler})
       when not is_nil(handler),
       do: :route

  defp route_outcome(%Spectre.Route{}), do: :unknown
  defp route_outcome(nil), do: :unknown

  @spec llm_called?([term()], [Candidate.t()]) :: boolean()
  defp llm_called?(traces, candidates) do
    Enum.any?(traces, &match?({:llm_arbitration_started, _labels}, &1)) or
      Enum.any?(candidates, &(&1.provider == :llm_classifier))
  end

  @spec attempts([term()], [Candidate.t()]) :: [attempt()]
  defp attempts(traces, candidates) do
    traced = Enum.flat_map(traces, &trace_attempt/1)
    traced_providers = MapSet.new(traced, & &1.provider)

    inferred =
      candidates
      |> Enum.reject(&MapSet.member?(traced_providers, &1.provider))
      |> Enum.map(fn candidate ->
        %{
          provider: candidate.provider,
          result: :candidate,
          label: candidate.label
        }
      end)

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
    %{provider: provider, result: result, label: label}
  end

  defp route_attempt(provider, result, _route), do: %{provider: provider, result: result}

  @spec reason_attempt(atom(), atom(), term()) :: attempt()
  defp reason_attempt(provider, result, reason) do
    %{provider: provider, result: result, reason: reason_code(reason)}
  end

  @spec candidate_summary(Candidate.t()) :: candidate_summary()
  defp candidate_summary(%Candidate{} = candidate) do
    Map.take(candidate, [:provider, :label, :accepted?, :score, :margin, :strength])
  end

  @spec trace_code(term()) :: atom()
  defp trace_code(trace) when is_atom(trace), do: trace

  defp trace_code(trace) when is_tuple(trace) do
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
end
