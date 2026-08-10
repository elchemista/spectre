defmodule Spectre.Execution.Work do
  @moduledoc """
  Compile-time DSL for declarative data-driven Work programs.

  The macros emit ordinary data and compile it through
  `Spectre.Execution.Program`. Runtime-authored maps use the same constructor,
  so compiled and runtime origins share the exact program IR and interpreter.
  """

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      import Spectre.Execution.Work,
        only: [
          step: 2,
          infer: 2,
          decide: 2,
          repeat: 2,
          finish: 1,
          finish: 2,
          fail: 2,
          migration: 2
        ]

      Module.register_attribute(__MODULE__, :spectre_execution_nodes,
        accumulate: true,
        persist: false
      )

      Module.register_attribute(__MODULE__, :spectre_execution_migrations,
        accumulate: true,
        persist: false
      )

      @spectre_execution_options opts
      @before_compile Spectre.Execution.Work
    end
  end

  @doc "Declares one registered operation step."
  defmacro step(id, opts), do: register_node(:step, id, opts)

  @doc "Declares one registered cognitive inference step."
  defmacro infer(id, opts), do: register_node(:infer, id, opts)

  @doc "Declares one pure registered predicate branch."
  defmacro decide(id, opts), do: register_node(:decide, id, opts)

  @doc "Declares one bounded repeat control node."
  defmacro repeat(id, opts), do: register_node(:repeat, id, opts)

  @doc "Declares a terminal completion node returning current state."
  defmacro finish(id), do: register_node(:complete, id, [])

  @doc "Declares a terminal completion node."
  defmacro finish(id, opts), do: register_node(:complete, id, opts)

  @doc "Declares a terminal failure node."
  defmacro fail(id, reason), do: register_node(:fail, id, reason: reason)

  @doc "Declares a pure registered state migration into this program version."
  defmacro migration(from, opts) do
    quote bind_quoted: [from: from, opts: opts] do
      @spectre_execution_migrations opts |> Map.new() |> Map.put(:from, from)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :spectre_execution_options)

    nodes =
      env.module
      |> Module.get_attribute(:spectre_execution_nodes)
      |> Enum.reverse()

    migrations =
      env.module
      |> Module.get_attribute(:spectre_execution_migrations)
      |> Enum.reverse()

    attrs =
      opts
      |> Map.new()
      |> Map.put(:nodes, nodes)
      |> Map.put(:migrations, migrations)

    program = Spectre.Execution.Program.new!(attrs)

    quote do
      @doc false
      def __spectre_execution_program__, do: unquote(Macro.escape(program))
    end
  end

  defp register_node(kind, id, opts) do
    quote bind_quoted: [kind: kind, id: id, opts: opts] do
      @spectre_execution_nodes opts
                               |> Map.new()
                               |> Map.put(:id, id)
                               |> Map.put(:kind, kind)
    end
  end
end
