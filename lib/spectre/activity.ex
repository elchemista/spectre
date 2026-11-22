defmodule Spectre.Activity do
  @moduledoc """
  An on-demand worker that runs application callbacks through `Spectre.Server.Runtime`.

  Register the module in a Stack with `activity :research, MyApp.Research` or
  in a library with `Spectre.Integration.activity/4`. Start it with
  `Spectre.Server.start_activity/4` inside a Server callback.

      defmodule MyApp.Research do
        use Spectre.Activity

        def handle_start(args, ctx),
          do: call_tool(ctx, {:documents, :read}, args, on_result: :loaded)

        def handle_result(:loaded, {:ok, document}, ctx),
          do: complete(ctx, document)
      end

  `handle_start/2` receives the arguments after the Activity is adopted.
  `handle_signal/2` can apply a control request to its local state and returns
  the Context by default. Use `handle_result/3` to consume command continuations.
  Results unmatched by application clauses use the inherited handler, which
  ends the Activity when a command returns an error.

  An Activity that starts children can implement `c:Spectre.Server.handle_activity/3`
  to handle their terminal events. The Runtime counts conversational callbacks
  within each Activity revision using `max_steps:` (32 by default). A revision
  starts a fresh budget. Set `activity_idle:` to `:notify`, `:fail` or `:keep`
  to control what happens when the execution has no tracked work left.
  """
  alias Spectre.Server
  alias Spectre.Server.Context

  @doc "Receives the portable arguments supplied to the start command and the Activity Context."
  @callback handle_start(term(), Context.t()) :: Context.t()
  @doc "Handles an accepted control signal or a reconciled governed effect."
  @callback handle_signal(term(), Context.t()) :: Context.t()
  @optional_callbacks handle_signal: 2

  @doc """
  Imports Activity completion helpers and installs the Server callback defaults.

  Options such as `prompt_root:` are forwarded to `use Spectre.Server`.
  If the Activity omits `prompt_root:`, prompt lookup uses the Agent's
  configured prompt root. Set it on the Activity to use its own assets.
  The module must implement `c:handle_start/2`.
  """
  @spec __using__(Macro.t()) :: Macro.t()
  defmacro __using__(opts) do
    quote do
      use Spectre.Server, unquote(opts)
      @behaviour Spectre.Activity
      import Spectre.Activity, only: [complete: 2, fail: 2]

      @doc false
      def __spectre_activity__, do: __spectre_server_options__()

      def handle_signal(_signal, ctx), do: ctx

      def handle_result(_tag, {:error, reason}, ctx), do: fail(ctx, reason)
      def handle_result(tag, result, ctx), do: super(tag, result, ctx)

      defoverridable handle_signal: 2, handle_result: 3
      @before_compile Spectre.Activity
    end
  end

  @doc false
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    if Server.result_fallback_needed?(env.module) do
      quote generated: true do
        def handle_result(tag, result, ctx), do: super(tag, result, ctx)
      end
    end
  end

  @doc "Queues completion with a portable result. The root consumer receives the lifecycle event."
  @spec complete(Context.t(), term()) :: Context.t()
  def complete(ctx, value), do: Server.complete_activity(ctx, value)

  @doc "Queues a terminal Activity failure with a portable reason."
  @spec fail(Context.t(), term()) :: Context.t()
  def fail(ctx, reason), do: Server.fail_activity(ctx, reason)
end
