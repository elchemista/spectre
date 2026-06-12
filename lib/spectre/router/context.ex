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
