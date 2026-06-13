defmodule Spectre.Router.Context do
  @moduledoc """
  Shared data passed through a Spectre router pipeline.
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
          host_context: map(),
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
  """
  @spec add_candidate(t(), Spectre.Router.Candidate.t()) :: t()
  def add_candidate(%__MODULE__{} = context, %Spectre.Router.Candidate{} = candidate) do
    %{context | candidates: [candidate | context.candidates]}
  end

  @doc """
  Appends several routing evidence candidates.
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
