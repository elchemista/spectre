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
      @before_compile Spectre.Activity
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    case Module.get_definition(env.module, {:handle_result, 3}) do
      {:v1, :def, _, clauses} ->
        unless Enum.any?(clauses, &catch_all_result_clause?/1) do
          quote generated: true do
            def handle_result(tag, result, ctx), do: super(tag, result, ctx)
          end
        end

      _ ->
        :ok
    end
  end

  defp catch_all_result_clause?({_, args, guards, _}) when guards in [[], [true]] do
    named_variables = for {name, _, context} <- args, name != :_, do: {name, context}
    Enum.all?(args, &variable?/1) and Enum.uniq(named_variables) == named_variables
  end

  defp catch_all_result_clause?(_clause), do: false

  defp variable?({name, metadata, context}),
    do: is_atom(name) and is_list(metadata) and is_atom(context)

  defp variable?(_pattern), do: false

  @doc "Completes the current Activity with a portable result."
  @spec complete(Context.t(), term()) :: Context.t()
  def complete(ctx, value), do: Server.complete_activity(ctx, value)

  @doc "Ends the current Activity with a failure reason."
  @spec fail(Context.t(), term()) :: Context.t()
  def fail(ctx, reason), do: Server.fail_activity(ctx, reason)
end
