defmodule Spectre.Router.Context do
  @moduledoc """
  Shared data passed through a Spectre router pipeline.

  Router context is intentionally separate from runtime context. It is optimized
  for evidence collection: candidate routes, traces, errors, visible labels, and
  any input enrichment produced while routing.
  """

  defstruct [
    :input,
    :host_context,
    :opts,
    :labels,
    :route,
    :rules,
    :local_result,
    candidates: [],
    halted?: false,
    traces: [],
    errors: []
  ]

  @type t :: %__MODULE__{
          input: Spectre.Input.t(),
          host_context: map() | nil,
          opts: keyword(),
          labels: [atom()],
          route: Spectre.Route.t() | nil,
          rules: [Spectre.Rule.t()],
          local_result: map() | nil,
          candidates: [Spectre.Router.Candidate.t()],
          halted?: boolean(),
          traces: [term()],
          errors: [term()]
        }

  @doc """
  Returns true when a router plug halted route evaluation.
  """
  @spec halted?(t()) :: boolean()
  def halted?(%__MODULE__{halted?: halted?}), do: halted?

  @doc """
  Returns true when accepted hard evidence already identifies a runnable route.

  Expensive probabilistic providers can use this to avoid work that cannot
  change the default arbitration result. The arbitrator still owns the final
  route decision.
  """
  @spec hard_candidate?(t()) :: boolean()
  def hard_candidate?(%__MODULE__{candidates: candidates}) do
    Enum.any?(candidates, fn
      %Spectre.Router.Candidate{strength: :hard, accepted?: true, handler: handler}
      when not is_nil(handler) ->
        true

      _candidate ->
        false
    end)
  end

  @doc """
  Returns true when hard evidence may safely short-circuit later providers.

  This optimization is automatic for the built-in arbitrator. Custom
  arbitrators retain the complete evidence stream unless they explicitly set
  `hard_short_circuit?: true`.
  """
  @spec hard_candidate_locked?(t()) :: boolean()
  def hard_candidate_locked?(%__MODULE__{} = context) do
    hard_candidate?(context) and hard_short_circuit?(context.opts)
  end

  @spec hard_short_circuit?(keyword()) :: boolean()
  defp hard_short_circuit?(opts) do
    Keyword.get_lazy(opts, :hard_short_circuit?, fn -> default_arbitrator?(opts) end) == true
  end

  @spec default_arbitrator?(keyword()) :: boolean()
  defp default_arbitrator?(opts) do
    case Keyword.get(opts, :arbitrator) do
      {Spectre.Router.Arbitrators.Default, _opts} -> true
      Spectre.Router.Arbitrators.Default -> true
      nil -> true
      _custom -> false
    end
  end

  @doc """
  Replaces the normalized input after enrichment.
  """
  @spec put_input(t(), Spectre.Input.t()) :: t()
  def put_input(%__MODULE__{} = context, %Spectre.Input{} = input), do: %{context | input: input}

  @doc """
  Stores the current route in context.
  """
  @spec put_route(t(), map()) :: t()
  def put_route(%__MODULE__{} = context, route), do: %{context | route: Spectre.Route.new(route)}

  @doc """
  Stores non-terminal classifier/cache metadata for downstream plugs.
  """
  @spec put_local_result(t(), map()) :: t()
  def put_local_result(%__MODULE__{} = context, result), do: %{context | local_result: result}

  @doc """
  Appends a routing evidence candidate.

      context = Spectre.Router.Context.add_candidate(context, candidate)
  """
  @spec add_candidate(t(), Spectre.Router.Candidate.t()) :: t()
  def add_candidate(%__MODULE__{} = context, %Spectre.Router.Candidate{} = candidate) do
    %{context | candidates: [candidate | context.candidates]}
  end

  @doc """
  Appends several routing evidence candidates.

      context = Spectre.Router.Context.add_candidates(context, candidates)
  """
  @spec add_candidates(t(), [Spectre.Router.Candidate.t()]) :: t()
  def add_candidates(%__MODULE__{} = context, candidates) when is_list(candidates) do
    Enum.reduce(candidates, context, &add_candidate(&2, &1))
  end

  @doc """
  Appends a trace event.
  """
  @spec put_trace(t(), term()) :: t()
  def put_trace(%__MODULE__{} = context, trace), do: %{context | traces: [trace | context.traces]}

  @doc """
  Appends an error event.
  """
  @spec put_error(t(), term()) :: t()
  def put_error(%__MODULE__{} = context, error), do: %{context | errors: [error | context.errors]}

  @doc """
  Marks route evaluation as halted.
  """
  @spec halt(t()) :: t()
  def halt(%__MODULE__{} = context), do: %{context | halted?: true}
end
