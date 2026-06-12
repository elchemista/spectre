defmodule Spectre.Router.Plugs.SemanticCacheExact do
  @moduledoc false

  @behaviour Spectre.Router.Plug

  alias Spectre.Router.Context
  alias Spectre.Router.SemanticCache
  alias Spectre.Router.Support

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Context{} = context, _state) do
    cond do
      Context.halted?(context) ->
        {:cont, context}

      not Keyword.get(context.opts, :semantic_cache?, true) ->
        {:cont, Context.put_local_result(context, %{semantic_cache: :semantic_cache_disabled})}

      true ->
        semantic_lookup(context, false, :cache_accept, :cache_skip)
    end
  end

  @spec semantic_lookup(Context.t(), boolean(), atom(), atom()) :: {:cont, Context.t()}
  defp semantic_lookup(
         %Context{input: %{text: text}, labels: labels, rules: rules, opts: opts} = context,
         search?,
         accept_trace,
         skip_trace
       ) do
    lookup_opts = Keyword.put(opts, :semantic_search?, search?)

    case SemanticCache.lookup(text, lookup_opts) do
      {:ok, %{accepted?: true} = result} ->
        route = Support.route_from_result(result, rules, labels, :semantic_cache)
        Support.log_route(:info, to_string(accept_trace), route, opts)

        {:cont,
         context
         |> Context.put_route(route)
         |> Context.put_trace({accept_trace, route})
         |> Context.halt()}

      {:error, reason} ->
        Support.log(:debug, "#{skip_trace} reason=#{Support.format_reason(reason)}", opts)

        {:cont,
         context
         |> Context.put_local_result(%{semantic_cache: reason})
         |> Context.put_trace({skip_trace, reason})}
    end
  end
end
