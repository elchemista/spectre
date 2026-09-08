defmodule Spectre.Agent.DSL do
  @moduledoc """
  Shared, process-free declarations for Agents, Skills, Routers and Stack presets.

  A route names a handler message, never an effect. Requests declare data for
  later preparation; these macros neither grant authority nor call providers.
  Local names are non-empty compile-time atoms, never atoms from user input.
  The '/' separator is reserved for mounted paths such as "orders/lookup";
  class strings are independent and keep their application-defined vocabulary.
  """

  alias Spectre.Agent.Compiler

  @doc "Declares an independently selected flow; policy and pipelines do not inherit."
  defmacro flow(name, do: block) do
    quote do
      Compiler.flow!(__MODULE__, unquote(name), __ENV__)
      unquote(block)
      Compiler.end_flow!(__MODULE__)
    end
  end

  @doc "Selects matcher order/thresholds within a flow, or mounts an extracted Router at the root."
  defmacro router(value), do: quote(do: Compiler.router!(__MODULE__, unquote(value), __ENV__))

  @doc "Names the handler message and its matcher data; cache/classifier participation is explicit."
  defmacro route(name, opts),
    do: quote(do: Compiler.route!(__MODULE__, unquote(name), unquote(opts), __ENV__))

  @doc "Selects already prepared host pipelines, in order."
  defmacro pipe_through(names),
    do: quote(do: Compiler.pipelines!(__MODULE__, unquote(names), __ENV__))

  @doc "Selects a build-time prompt directory; input cannot choose a file at runtime."
  defmacro prompt_root(path),
    do: quote(do: Compiler.prompt_root!(__MODULE__, unquote(path), __ENV__))

  @doc "Compiles inline EEx or a declared .text.eex/.txt.eex file once."
  defmacro prompt(name, value),
    do: quote(do: Compiler.prompt!(__MODULE__, unquote(name), unquote(value), __ENV__))

  @doc "Adds a prompt part in declaration order at Agent/flow scope; default position is :end."
  defmacro inject(name, opts \\ []),
    do: quote(do: Compiler.inject!(__MODULE__, unquote(name), unquote(opts), __ENV__))

  @doc "Fixes optional Candidate fields under a reusable name, without permission defaults."
  defmacro request(name, opts),
    do: quote(do: Compiler.request!(__MODULE__, unquote(name), unquote(opts), __ENV__))

  for kind <- [:ask, :history, :memory, :classifier, :semantic_cache] do
    @doc "Declares #{kind} configuration; the host supplies its operational bindings."
    defmacro unquote(kind)(name, opts) do
      kind = unquote(kind)

      quote do:
              Compiler.declaration!(
                __MODULE__,
                unquote(kind),
                unquote(name),
                unquote(opts),
                __ENV__
              )
    end
  end

  @doc "Declares a named adapter port; does not load models or start resources."
  defmacro adapter(kind, name, module, opts \\ []) do
    quote do:
            Compiler.adapter!(
              __MODULE__,
              unquote(kind),
              unquote(name),
              unquote(module),
              unquote(opts),
              __ENV__
            )
  end

  @doc "Mounts a Skill with an independent local state namespace, not another process."
  defmacro skill(module, opts) do
    quote do: Compiler.skill!(__MODULE__, unquote(module), unquote(opts), __ENV__)
  end

  for kind <- [:worker, :vigil] do
    @doc "Declares a reusable #{kind}; starting it still requires a governed Scope opening."
    defmacro unquote(kind)(name, module) do
      kind = unquote(kind)

      quote do:
              Compiler.component!(
                __MODULE__,
                unquote(kind),
                unquote(name),
                unquote(module),
                __ENV__
              )
    end
  end

  @doc """
  Installs an extension's explicit configuration, without dependency resolution.

  Block declarations become inert pairs passed to configure/1. The extension
  validates its vocabulary and returns portable data and ports, not processes.
  """
  defmacro install(module, options) do
    opts =
      case options do
        [do: block] ->
          expressions =
            case block do
              {:__block__, _, entries} -> entries
              entry -> [entry]
            end

          Enum.map(expressions, fn
            {name, _, args} when is_atom(name) and is_list(args) -> {name, args}
            _invalid -> raise ArgumentError, "extension blocks contain declarations only"
          end)

        options ->
          options
      end

    quote do: Compiler.extension!(__MODULE__, unquote(module), unquote(opts), __ENV__)
  end
end
