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

        def handle_result(tag, result, ctx), do: super(tag, result, ctx)
      end

  `handle_start/2` receives the arguments after the Activity is adopted.
  `handle_signal/2` can apply a control request to its local state and returns
  the Context by default. Use `handle_result/3` to consume command continuations.
  The default ends the Activity when a command returns an error.
  """
  alias Spectre.Server
  alias Spectre.Server.Context

  @callback handle_start(term(), Context.t()) :: Context.t()
  @callback handle_signal(term(), Context.t()) :: Context.t()
  @optional_callbacks handle_signal: 2

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
    end
  end

  @doc "Completes the current Activity with a portable result."
  @spec complete(Context.t(), term()) :: Context.t()
  def complete(ctx, value), do: Server.complete_activity(ctx, value)

  @doc "Ends the current Activity with a failure reason."
  @spec fail(Context.t(), term()) :: Context.t()
  def fail(ctx, reason), do: Server.fail_activity(ctx, reason)
end
