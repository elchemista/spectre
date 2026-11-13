defmodule Spectre.Server.ToolCompiler do
  @moduledoc false
  alias Spectre.Stack.{Definition, Tools}

  def snapshot!(opts, caller) do
    case Keyword.fetch(opts, :tools) do
      :error -> %{}
      {:ok, ast} -> snapshot_for!(Macro.expand(ast, caller))
    end
  end

  defp snapshot_for!(stack) when is_atom(stack) and stack not in [nil, true, false] do
    Code.ensure_compiled!(stack)
    stack |> Definition.fetch!() |> Map.fetch!(:installations) |> Tools.table!()
  end

  defp snapshot_for!(_),
    do: raise(ArgumentError, "Server tools: must name a literal Stack module")

  defmacro __before_compile__(env) do
    table = Module.get_attribute(env.module, :spectre_server_tools)
    functions = Enum.flat_map(table, &helper_ast!(&1, env))

    quote do
      @doc false
      def __spectre_server_tools__, do: unquote(Macro.escape(table))
      unquote_splicing(functions)
    end
  end

  defp helper_ast!({name, entry}, env) do
    Enum.each([2, 3], &check_collision!(env, name, &1))

    [
      quote do
        @compile {:nowarn_unused_function, [{unquote(name), 2}, {unquote(name), 3}]}
        defp unquote(name)(ctx, input, opts \\ []) do
          Spectre.Server.Tool.request(
            ctx,
            unquote(name),
            input,
            opts,
            unquote(Macro.escape(entry))
          )
        end
      end
    ]
  end

  defp check_collision!(env, name, arity) do
    signature = {name, arity}

    imported? =
      Enum.any?(env.functions ++ env.macros, fn {_, entries} -> signature in entries end)

    callback? = Keyword.has_key?(Spectre.Server.behaviour_info(:callbacks), name)

    if Module.defines?(env.module, signature) or imported? or callback? do
      raise ArgumentError,
            "Stack tool helper #{name}/#{arity} conflicts with a Server function, import or callback"
    end
  end
end
