defmodule Spectre.Context do
  @moduledoc """
  Per-turn runtime context.

  Context is passed between runtime, router, prompt rendering, handlers, and
  action execution. It keeps dependencies explicit without pushing the entire
  host application into each function signature.
  """

  defstruct [
    :agent,
    :input,
    :state,
    opts: [],
    assigns: %{},
    memory: nil,
    route: nil,
    halted?: false,
    traces: [],
    errors: []
  ]

  @type t :: %__MODULE__{
          agent: module(),
          input: Spectre.Input.t(),
          state: Spectre.State.t(),
          opts: keyword(),
          assigns: map(),
          memory: term(),
          route: Spectre.Route.t() | nil,
          halted?: boolean(),
          traces: [term()],
          errors: [term()]
        }

  @doc """
  Marks the context as halted.

      ctx = Spectre.Context.halt(ctx)
  """
  @spec halt(t()) :: t()
  def halt(%__MODULE__{} = ctx), do: %{ctx | halted?: true}

  @doc """
  Adds a trace entry to the context.

      ctx = Spectre.Context.put_trace(ctx, {:router, :accepted})
  """
  @spec put_trace(t(), term()) :: t()
  def put_trace(%__MODULE__{} = ctx, trace), do: %{ctx | traces: [trace | ctx.traces]}

  @doc """
  Adds an error entry to the context.

      ctx = Spectre.Context.put_error(ctx, {:adapter_failed, reason})
  """
  @spec put_error(t(), term()) :: t()
  def put_error(%__MODULE__{} = ctx, error), do: %{ctx | errors: [error | ctx.errors]}
end
