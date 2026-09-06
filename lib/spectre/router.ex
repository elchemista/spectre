defmodule Spectre.Router do
  @moduledoc """
  Composable proposal routing before the GAM kernel.

      {:ok, router} = Spectre.Router.new(%{
        "refund" => %{to: "refund", match: %{regex: ~r/^refund (?<amount>[0-9]+)$/,
          string_bag: ["money back", "refund please"]}}
      }, via: [:regex, :string_bag])
      {:ok, selection} = Spectre.Router.route(router, "refund 12")

  Methods are evaluated in `via` order. A unique nomination must meet both
  `accept` (default 0.85) and its lead over the runner-up, `margin` (default 0).
  Exact ties are ambiguous even with zero margin. An undecided method lets the
  next method try; callback errors are returned, not silently treated as misses.

  Add methods with `adapters: [binary: MyMatcher]`. The registry is host wiring,
  never executable code resolved from a Definition. Built-in identifiers cannot
  be overwritten. This object is a reusable compiled plan, not an OTP process;
  create it once per pinned Definition/configuration, then reuse it across turns.

  A selection only names a declared candidate. Build it with `Spectre.Agent`
  and submit through the usual facade; recognition, consent, authority, Meter
  and append-before-dispatch remain exclusively in the governed core.
  """

  alias Spectre.{Adapter, Portable}
  alias Spectre.Canonical.Value
  alias Spectre.Router.Adapter.Request
  alias Spectre.Router.{Matchers, Rule, Selection}

  @builtins ["regex", "string_bag", "bag_distance", "jaro"]
  @enforce_keys [:ref, :rules, :methods, :accept, :margin]
  defstruct [:ref, :rules, :methods, :accept, :margin]

  @type t :: %__MODULE__{
          ref: String.t(),
          rules: map(),
          methods: [map()],
          accept: number(),
          margin: number()
        }

  @doc "Compiles portable rules using an explicit host adapter registry."
  @spec new(map(), keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(rules, opts \\ []) do
    with {:ok, opts} <-
           Portable.normalize_attrs(opts, [:via, :adapters, :accept, :margin], :router),
         {:ok, rules} <- rules(rules),
         {:ok, config} <- configuration(Map.drop(opts, [:adapters])),
         {:ok, registry} <- registry(Map.get(opts, :adapters, [])),
         {:ok, methods} <- methods(config["via"], registry, rules),
         {:ok, ref} <-
           Portable.content_ref("router", %{
             "rules" => Map.new(rules, fn {name, rule} -> {name, Rule.canonical(rule)} end),
             "config" => config
           }) do
      {:ok,
       %__MODULE__{
         ref: ref,
         rules: rules,
         methods: methods,
         accept: config["accept"],
         margin: config["margin"]
       }}
    end
  end

  @doc "Returns a selection, a miss, an ambiguity, or an explicit adapter failure."
  @spec route(t(), term()) ::
          {:ok, Selection.t()} | :no_match | {:ambiguous, [String.t()]} | {:error, term()}
  def route(%__MODULE__{} = router, input) do
    with :ok <- Value.validate(input, max_bytes: 65_536) do
      Enum.reduce_while(router.methods, :no_match, fn method, previous ->
        continue_routing(evaluate(method, input, router), previous)
      end)
    end
  end

  defp continue_routing(:no_match, previous), do: {:cont, previous}
  defp continue_routing({:ambiguous, _} = ambiguous, _previous), do: {:cont, ambiguous}
  defp continue_routing(result, _previous), do: {:halt, result}

  @doc false
  def configuration(opts) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(opts, [:via, :accept, :margin], :router_configuration),
         {:ok, via} <- method_ids(Map.get(attrs, :via, [:regex, :string_bag])),
         accept = Map.get(attrs, :accept, 0.85),
         margin = Map.get(attrs, :margin, 0.0),
         true <- score?(accept) and score?(margin) do
      {:ok, %{"via" => via, "accept" => accept, "margin" => margin}}
    else
      false -> {:error, :invalid_router_threshold}
      {:error, _} = error -> error
    end
  end

  @doc false
  def rules(values) when is_map(values) and not is_struct(values) and map_size(values) <= 1024 do
    Enum.reduce_while(values, {:ok, %{}}, fn {name, attrs}, {:ok, acc} ->
      case Rule.new(name, attrs) do
        {:ok, rule} -> {:cont, {:ok, Map.put(acc, name, rule)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def rules(_values), do: {:error, :invalid_router_rules}

  defp method_ids(ids) when is_list(ids) and ids != [] do
    with :ok <- Portable.validate(ids), do: normalize_method_ids(ids)
  end

  defp method_ids(_ids), do: {:error, :invalid_router_methods}

  defp normalize_method_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, name} <- Rule.method(id), false <- name in acc do
        {:cont, {:ok, [name | acc]}}
      else
        true -> {:halt, {:error, :duplicate_router_method}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, names} -> {:ok, Enum.reverse(names)}
      error -> error
    end
  end

  defp registry(adapters) do
    if Portable.keyword?(adapters) or (is_map(adapters) and not is_struct(adapters)) do
      defaults = Map.new(@builtins, &{&1, {Matchers, [method: &1]}})
      Enum.reduce_while(adapters, {:ok, defaults}, &register/2)
    else
      {:error, :invalid_router_adapters}
    end
  end

  defp register({id, config}, {:ok, acc}) do
    with {:ok, id} <- Rule.method(id),
         false <- Map.has_key?(acc, id),
         {module, opts} <- adapter_config(config),
         true <- Portable.keyword?(opts),
         :ok <- Adapter.validate(module, evaluate: 2) do
      {:cont, {:ok, Map.put(acc, id, {module, opts})}}
    else
      true -> {:halt, {:error, {:duplicate_router_adapter, id}}}
      false -> {:halt, {:error, :invalid_router_adapter_options}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp adapter_config({module, opts}), do: {module, opts}
  defp adapter_config(module), do: {module, []}

  defp methods(ids, registry, rules) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      with {:ok, {module, opts}} <- Map.fetch(registry, id),
           :ok <- Adapter.validate(module, evaluate: 2),
           {:ok, prepared} <- prepare_rules(rules, id, module, opts) do
        {:cont, {:ok, [%{id: id, module: module, opts: opts, rules: prepared} | acc]}}
      else
        :error -> {:halt, {:error, {:unknown_router_method, id}}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, methods} -> {:ok, Enum.reverse(methods)}
      error -> error
    end
  end

  defp prepare_rules(rules, id, module, opts) do
    rules
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {ref, rule}, {:ok, acc} ->
      with {:ok, data} <- Map.fetch(rule.match, id), {:ok, data} <- prepare(module, data, opts) do
        {:cont, {:ok, [%{ref: ref, data: data} | acc]}}
      else
        :error -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      error -> error
    end
  end

  defp prepare(module, data, opts) do
    if function_exported?(module, :prepare, 2) do
      with {:ok, reply} <- Adapter.invoke(module, :prepare, [data, opts]) do
        prepared_reply(reply)
      end
    else
      {:ok, data}
    end
  end

  defp prepared_reply({:ok, _} = ok), do: ok
  defp prepared_reply({:error, _} = error), do: error
  defp prepared_reply(_reply), do: {:error, :invalid_router_prepare_reply}

  defp evaluate(%{rules: []}, _input, _router), do: :no_match

  defp evaluate(method, input, router) do
    request = %Request{input: input, rules: method.rules}

    with {:ok, reply} <- Adapter.invoke(method.module, :evaluate, [request, method.opts]),
         {:ok, results} <- results(reply, MapSet.new(method.rules, & &1.ref)) do
      select(results, method.id, router)
    end
  end

  defp results(:skip, _visible), do: {:ok, []}
  defp results({:error, _} = error, _visible), do: error

  defp results({:ok, results}, visible) when is_list(results) and length(results) <= 32 do
    Enum.reduce_while(results, {:ok, %{}}, fn result, {:ok, acc} ->
      with {:ok, attrs} <-
             Portable.normalize_attrs(result, [:rule, :score, :matched], :router_result),
           ref = Map.get(attrs, :rule),
           true <- MapSet.member?(visible, ref) and not Map.has_key?(acc, ref),
           true <- score?(Map.get(attrs, :score)),
           :ok <- Value.validate(Map.get(attrs, :matched), max_bytes: 4096) do
        {:cont, {:ok, Map.put(acc, ref, Map.put_new(attrs, :matched, nil))}}
      else
        false -> {:halt, {:error, :invalid_router_nomination}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Map.values() |> Enum.sort_by(&{-&1.score, &1.rule})}
      error -> error
    end
  end

  defp results(_reply, _visible), do: {:error, :invalid_router_reply}

  defp select([], _method, _router), do: :no_match

  defp select([first | rest], method, router) do
    runner_up =
      case rest do
        [second | _] -> second.score
        [] -> nil
      end

    cond do
      first.score < router.accept ->
        :no_match

      runner_up != nil and (first.score == runner_up or first.score - runner_up < router.margin) ->
        {:ambiguous, Enum.map([first | rest], & &1.rule)}

      true ->
        {:ok,
         %Selection{
           router_ref: router.ref,
           rule: first.rule,
           candidate: router.rules[first.rule].to,
           via: method,
           score: first.score,
           matched: first.matched
         }}
    end
  end

  defp score?(value), do: is_number(value) and value >= 0 and value <= 1
end
