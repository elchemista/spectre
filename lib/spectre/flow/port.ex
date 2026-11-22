defmodule Spectre.Flow.Port do
  @moduledoc """
  A reusable conversational flow contributed by a Stack installation.

  Register the module with `Spectre.Integration.flow/3`. The Agent exposes the
  installation or selects a particular flow. The router matches the exposed
  rules and the flow receives the selected local label and the Server Context.

      defmodule MyApp.Documents.Flow do
        use Spectre.Flow.Port

        def routes, do: [on(:read, regex: ~r/^show (?<id>D[0-9]+)$/i)]

        def handle_flow(:read, _input, ctx) do
          call_tool(ctx, {:documents, :read}, %{id: ctx.routing.params["id"]})
        end

        def handle_result(:read, {:ok, document}, ctx), do: respond(ctx, document.title)
      end
  """

  alias Spectre.{Input, Route}
  alias Spectre.Server.Context

  @typedoc "A local route label and its Agent routing options."
  @type declaration :: {atom(), keyword()}
  @type binding :: %{module: module(), routes: [declaration()]}
  @type owner :: {term(), atom(), module()}

  @callback routes() :: [declaration()]
  @callback handle_flow(atom(), Input.t(), Context.t()) :: Context.t()
  @callback handle_result(term(), term(), Context.t()) :: Context.t()
  @optional_callbacks handle_result: 3

  defmacro __using__(_options) do
    quote do
      @behaviour Spectre.Flow.Port
      import Spectre.Flow.Port, only: [on: 2]
      import Spectre.Server, except: [inspect: 1, inspect: 2]
    end
  end

  @doc "Declares a selectable route and its recognition options."
  @spec on(atom(), keyword()) :: declaration()
  def on(label, opts) when is_atom(label) and label not in [nil, true, false] do
    if Keyword.keyword?(opts), do: {label, opts}, else: invalid_route!({label, opts})
  end

  def on(label, opts), do: invalid_route!({label, opts})

  @doc false
  @spec compile!(module()) :: binding()
  def compile!(module) do
    validate_module!(module)

    case module.routes() do
      [_ | _] = routes when is_list(routes) ->
        %{module: module, routes: Enum.map(routes, &portable_route!/1)}

      other ->
        raise ArgumentError, "invalid routes for #{inspect(module)}: #{inspect(other)}"
    end
  end

  @doc false
  @spec validate!(binding()) :: :ok
  def validate!(%{module: module, routes: [_ | _] = routes}) when is_list(routes) do
    validate_module!(module)
    Enum.each(routes, &validate_route!/1)
  end

  def validate!(other), do: raise(ArgumentError, "invalid Stack flow binding: #{inspect(other)}")

  @doc false
  @spec rule_options!(declaration()) :: declaration()
  def rule_options!({label, opts}) do
    on(label, opts)

    regexes =
      opts
      |> Keyword.fetch!(:regex)
      |> Enum.map(fn {source, modifiers} -> Regex.compile!(source, modifiers) end)

    {label, Keyword.put(opts, :regex, regexes)}
  end

  def rule_options!(other), do: invalid_route!(other)

  @doc false
  @spec owner(Route.t() | nil) :: owner() | nil
  def owner(%Route{handler: {:server, _, [flow_port: {_, scope, module} = owner]}})
      when is_atom(scope) and is_atom(module), do: owner

  def owner(_route), do: nil

  defp portable_route!({label, opts}) do
    on(label, opts)

    regexes =
      opts
      |> Keyword.get(:regex)
      |> List.wrap()
      |> Enum.map(fn
        %Regex{} = regex -> {Regex.source(regex), Regex.opts(regex)}
        other -> invalid_route!({label, regex: other})
      end)

    {label, Keyword.put(opts, :regex, regexes)}
  end

  defp portable_route!(other), do: invalid_route!(other)

  defp validate_route!({label, opts} = route) do
    on(label, opts)

    case Keyword.fetch(opts, :regex) do
      {:ok, regexes} when is_list(regexes) -> Enum.each(regexes, &validate_regex!/1)
      _ -> invalid_route!(route)
    end
  end

  defp validate_route!(other), do: invalid_route!(other)

  defp validate_regex!({source, modifiers})
       when is_binary(source) and (is_binary(modifiers) or is_list(modifiers)),
       do: :ok

  defp validate_regex!(other), do: invalid_route!(other)

  defp validate_module!(module) do
    unless is_atom(module) and Code.ensure_compiled(module) == {:module, module} and
             function_exported?(module, :routes, 0) and
             function_exported?(module, :handle_flow, 3) do
      raise ArgumentError, "invalid Stack flow module: #{inspect(module)}"
    end
  end

  defp invalid_route!(route),
    do: raise(ArgumentError, "invalid Stack flow route: #{inspect(route)}")
end
