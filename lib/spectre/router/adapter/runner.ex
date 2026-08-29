defmodule Spectre.Router.Adapter.Runner do
  @moduledoc false

  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Router.Adapter.Compiler
  alias Spectre.Router.Adapter.Plan
  alias Spectre.Router.Adapter.Request
  alias Spectre.Router.Adapter.RuleView
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.RecentChat
  alias Spectre.Router.Support

  @result_keys [:rule, :score, :margin, :matched]
  @required_result_keys [:rule, :score]
  @max_results 32
  @strength_rank %{weak: 1, medium: 2, strong: 3, hard: 4}

  @doc false
  @spec run(Context.t(), atom()) :: {:cont, Context.t()} | {:error, term()}
  def run(%Context{} = context, adapter_id) when is_atom(adapter_id) do
    cond do
      Context.halted?(context) ->
        {:cont, context}

      Context.hard_candidate_locked?(context) ->
        {:cont, put_skip(context, adapter_id, :hard_candidate)}

      true ->
        run_planned(context, adapter_id)
    end
  end

  @doc false
  @spec normalize_results(term(), [Spectre.Rule.t() | RuleView.t()]) ::
          {:ok, [map()]} | {:error, term()}
  def normalize_results(results, visible_rules) when is_list(visible_rules) do
    rules_by_ref = Map.new(visible_rules, &{rule_ref(&1), &1})

    with {:ok, results} <- result_list(results),
         {:ok, normalized} <- validate_results(results, rules_by_ref),
         {:ok, deduplicated} <- deduplicate_results(normalized) do
      {:ok, sort_results(deduplicated)}
    end
  end

  @doc false
  @spec threshold(map(), Compiler.descriptor()) :: {boolean(), atom() | nil}
  def threshold(result, descriptor) when is_map(result) and is_map(descriptor) do
    score = Map.fetch!(result, :score)
    margin = Map.get(result, :margin)

    cond do
      score <= 0.0 or score < descriptor.accept ->
        {false, :score_below_threshold}

      not is_nil(margin) and not is_nil(descriptor.margin) and margin < descriptor.margin ->
        {false, :margin_below_threshold}

      true ->
        {true, nil}
    end
  end

  @spec run_planned(Context.t(), atom()) :: {:cont, Context.t()} | {:error, term()}
  defp run_planned(%Context{} = context, adapter_id) do
    with {:ok, plan} <- fetch_plan(context.opts),
         {:ok, entry} <- Plan.fetch(plan, adapter_id) do
      run_entry(context, entry)
    else
      :error -> {:error, {:unknown_router_adapter, adapter_id}}
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_plan(keyword()) :: {:ok, Plan.t()} | {:error, term()}
  defp fetch_plan(opts) do
    plan = Keyword.get(opts, Compiler.compiled_key())

    if Plan.adapter_plan?(plan),
      do: {:ok, plan},
      else: {:error, :router_adapter_plan_unavailable}
  end

  @spec run_entry(Context.t(), Plan.entry()) :: {:cont, Context.t()}
  defp run_entry(context, %{availability: {:unavailable, diagnostic}} = entry) do
    {:cont,
     context
     |> Context.put_error(diagnostic)
     |> put_skip(entry.id, :descriptor_unavailable)}
  end

  defp run_entry(context, %{availability: :available} = entry) do
    visible_rules = Support.rules_for(context.rules, entry.id, context.input)

    if visible_rules == [] do
      {:cont, put_skip(context, entry.id, :no_visible_rules)}
    else
      invoke(context, entry, visible_rules)
    end
  end

  @spec invoke(Context.t(), Plan.entry(), [Spectre.Rule.t()]) :: {:cont, Context.t()}
  defp invoke(context, entry, visible_rules) do
    call_opts = Keyword.put(context.opts, :purpose, entry.id)
    adapter_opts = Call.adapter_opts(call_opts)
    request = request(context, entry.id, visible_rules, adapter_opts)
    started_at = System.monotonic_time()

    Spectre.Telemetry.emit(
      [:router, :adapter, :start],
      %{system_time: System.system_time()},
      %{adapter_id: entry.id},
      call_opts
    )

    result =
      Call.run(
        :router_adapter,
        fn -> entry.module.evaluate(request) |> normalize_callback_reply() end,
        call_opts
      )

    {context, outcome, result_count, invoked?} =
      handle_result(context, entry, visible_rules, result)

    Spectre.Telemetry.emit(
      [:router, :adapter, :stop],
      %{duration_us: elapsed_us(started_at), result_count: result_count},
      %{adapter_id: entry.id, outcome: outcome, invoked?: invoked?},
      call_opts
    )

    {:cont, context}
  end

  @spec request(Context.t(), atom(), [Spectre.Rule.t()], keyword()) :: Request.t()
  defp request(context, adapter_id, visible_rules, opts) do
    state =
      case context.host_context && Map.get(context.host_context, :state) do
        %Spectre.State{} = state -> state
        _missing_or_invalid -> nil
      end

    %Request{
      text: context.input.text,
      meta: context.input.meta,
      current_flow: state && state.current_flow,
      current_scope: state && state.current_scope,
      recent_chat: RecentChat.value(state, opts),
      rules: Enum.map(visible_rules, &rule_view(&1, adapter_id))
    }
  end

  @spec rule_view(Spectre.Rule.t(), atom()) :: RuleView.t()
  defp rule_view(rule, adapter_id) do
    %RuleView{
      ref: rule_ref(rule),
      label: rule.label,
      scope: rule.scope,
      flow: rule.flow,
      flow_path: rule.flow_path,
      global?: rule.global?,
      data: Keyword.get(rule.opts, adapter_id),
      opts: rule.opts
    }
  end

  @spec rule_ref(Spectre.Rule.t() | RuleView.t()) :: RuleView.ref()
  defp rule_ref(rule), do: {rule.scope, rule.label}

  @spec normalize_callback_reply(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_callback_reply({:ok, results}), do: {:ok, {:results, results}}
  defp normalize_callback_reply(:skip), do: {:ok, :skip}

  defp normalize_callback_reply({:skip, reason}),
    do: {:ok, {:skip, reason_code(reason)}}

  defp normalize_callback_reply({:error, _reason} = error), do: error

  defp normalize_callback_reply(other),
    do: {:error, Failure.invalid_reply(:router_adapter, other)}

  @spec handle_result(Context.t(), Plan.entry(), [Spectre.Rule.t()], term()) ::
          {Context.t(), atom(), non_neg_integer(), boolean()}
  defp handle_result(context, entry, visible_rules, {:ok, {:results, results}}) do
    case normalize_results(results, visible_rules) do
      {:ok, results} ->
        rules_by_ref = Map.new(visible_rules, &{rule_ref(&1), &1})

        candidates =
          Enum.map(results, fn result ->
            candidate(result, Map.fetch!(rules_by_ref, result.rule), entry, context.input.text)
          end)

        context =
          context
          |> Context.add_candidates(candidates)
          |> Context.put_trace({:router_adapter_result, entry.id, length(candidates)})

        {context, :ok, length(candidates), true}

      {:error, reason} ->
        context = put_failure(context, entry.id, {:invalid_result, reason})
        {context, :invalid_reply, 0, true}
    end
  end

  defp handle_result(context, entry, _visible_rules, {:ok, :skip}) do
    {put_skip(context, entry.id, :adapter_skip), :skip, 0, true}
  end

  defp handle_result(context, entry, _visible_rules, {:ok, {:skip, reason}}) do
    {put_skip(context, entry.id, reason), :skip, 0, true}
  end

  defp handle_result(context, entry, _visible_rules, {:error, %Failure{} = failure}) do
    context = put_failure(context, entry.id, failure.kind)
    {context, failure.kind, 0, failure.kind != :configuration}
  end

  defp handle_result(context, entry, _visible_rules, {:error, reason}) do
    context = put_failure(context, entry.id, reason_code(reason))
    {context, :error, 0, true}
  end

  @spec result_list(term()) :: {:ok, [map()]} | {:error, term()}
  defp result_list(result) when is_map(result) and not is_struct(result), do: {:ok, [result]}

  defp result_list(results) when is_list(results) do
    if Enum.all?(results, &(is_map(&1) and not is_struct(&1))),
      do: {:ok, results},
      else: {:error, :results_must_be_plain_maps}
  end

  defp result_list(_result), do: {:error, :result_must_be_a_map_or_list}

  @spec validate_results([map()], map()) :: {:ok, [map()]} | {:error, term()}
  defp validate_results(results, rules_by_ref) do
    results
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {result, index}, {:ok, normalized} ->
      case validate_result(result, rules_by_ref) do
        {:ok, result} -> {:cont, {:ok, [result | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_result, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_result(map(), map()) :: {:ok, map()} | {:error, term()}
  defp validate_result(result, rules_by_ref) do
    keys = Map.keys(result)
    unknown = keys -- @result_keys
    missing = @required_result_keys -- keys
    ref = Map.get(result, :rule)
    score = Map.get(result, :score)
    margin = Map.get(result, :margin)

    cond do
      unknown != [] ->
        {:error, {:unknown_fields, Enum.sort(unknown)}}

      missing != [] ->
        {:error, {:missing_fields, missing}}

      not Map.has_key?(rules_by_ref, ref) ->
        {:error, :rule_not_visible}

      not probability?(score) ->
        {:error, :invalid_score}

      not is_nil(margin) and not probability?(margin) ->
        {:error, :invalid_margin}

      true ->
        {:ok,
         result
         |> Map.put(:score, as_float(score))
         |> maybe_float_margin(margin)}
    end
  end

  @spec deduplicate_results([map()]) :: {:ok, [map()]} | {:error, term()}
  defp deduplicate_results(results) do
    deduplicated =
      Enum.reduce(results, %{}, fn result, by_ref ->
        Map.update(by_ref, result.rule, result, &preferred_result(&1, result))
      end)

    if map_size(deduplicated) <= @max_results,
      do: {:ok, Map.values(deduplicated)},
      else: {:error, {:too_many_results, @max_results}}
  end

  @spec preferred_result(map(), map()) :: map()
  defp preferred_result(left, right) do
    if result_order_key(left) <= result_order_key(right), do: left, else: right
  end

  @spec sort_results([map()]) :: [map()]
  defp sort_results(results), do: Enum.sort_by(results, &result_order_key/1)

  @spec result_order_key(map()) :: tuple()
  defp result_order_key(result) do
    {
      -Map.fetch!(result, :score),
      -(Map.get(result, :margin) || -1.0),
      :erlang.term_to_binary(Map.fetch!(result, :rule), [:deterministic])
    }
  end

  @spec candidate(map(), Spectre.Rule.t(), Plan.entry(), String.t()) :: Candidate.t()
  defp candidate(result, rule, entry, raw) do
    {accepted?, threshold_reason} = threshold(result, entry.descriptor)

    metadata = %{
      router_adapter: %{
        id: entry.id,
        module: entry.module,
        band: entry.descriptor.strength,
        order: entry.order,
        contract: entry.descriptor.contract,
        required: %{score: entry.descriptor.accept, margin: entry.descriptor.margin},
        threshold_reason: threshold_reason
      }
    }

    rule
    |> Candidate.from_rule(entry.id, raw,
      score: result.score,
      margin: Map.get(result, :margin),
      matched: Map.get(result, :matched),
      accepted?: accepted?,
      metadata: metadata
    )
    |> clamp_strength(entry.descriptor.strength)
  end

  @spec clamp_strength(Candidate.t(), Spectre.Router.Adapter.strength()) :: Candidate.t()
  defp clamp_strength(%Candidate{rule: %{global?: true}} = candidate, _descriptor_strength),
    do: candidate

  defp clamp_strength(%Candidate{strength: strength} = candidate, descriptor_strength) do
    with rule_rank when is_integer(rule_rank) <- Map.get(@strength_rank, strength),
         descriptor_rank when is_integer(descriptor_rank) <-
           Map.get(@strength_rank, descriptor_strength) do
      if rule_rank <= descriptor_rank,
        do: candidate,
        else: %{candidate | strength: descriptor_strength}
    else
      _invalid -> candidate
    end
  end

  @spec maybe_float_margin(map(), term()) :: map()
  defp maybe_float_margin(result, nil), do: result
  defp maybe_float_margin(result, margin), do: Map.put(result, :margin, as_float(margin))

  @spec probability?(term()) :: boolean()
  defp probability?(value) when is_integer(value), do: value >= 0 and value <= 1
  defp probability?(value) when is_float(value), do: value >= 0.0 and value <= 1.0
  defp probability?(_value), do: false

  @spec as_float(number()) :: float()
  defp as_float(value) when is_integer(value), do: value / 1
  defp as_float(value) when is_float(value), do: value

  @spec put_skip(Context.t(), atom(), term()) :: Context.t()
  defp put_skip(context, adapter_id, reason) do
    Context.put_trace(context, {:router_adapter_skip, adapter_id, reason_code(reason)})
  end

  @spec put_failure(Context.t(), atom(), term()) :: Context.t()
  defp put_failure(context, adapter_id, reason) do
    error = {:router_adapter_failed, adapter_id, reason_code(reason)}

    context
    |> Context.put_error(error)
    |> Context.put_trace(error)
  end

  @spec reason_code(term()) :: atom()
  defp reason_code(reason) when is_atom(reason), do: reason

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> code
      _other -> :router_adapter_failure
    end
  end

  defp reason_code(%{reason: reason}), do: reason_code(reason)
  defp reason_code(_reason), do: :router_adapter_failure

  @spec elapsed_us(integer()) :: non_neg_integer()
  defp elapsed_us(started_at) do
    started_at
    |> then(&(System.monotonic_time() - &1))
    |> System.convert_time_unit(:native, :microsecond)
  end
end
