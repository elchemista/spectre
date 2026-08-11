defmodule Spectre.Governance.Checker.Declarative do
  @moduledoc """
  Model-free replay and regression checker for closed declarative Skill replies.

  It resolves both Definitions from the Store, runs the canonical evaluation
  cases through the same Skill runtime loader used by live turns, and binds
  route, outcome, context and optional exact output to the protected corpus
  digest. Candidates containing Operation or Work handlers are refused.
  """

  alias Spectre.Eval.Case, as: EvalCase
  alias Spectre.Gate.Receipt
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Input
  alias Spectre.Input.Pipeline
  alias Spectre.Input.Pipeline.Spec
  alias Spectre.Router
  alias Spectre.Router.Receipt, as: RouterReceipt
  alias Spectre.Runtime.SkillDispatch
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime
  alias Spectre.Skill.Runtime.Loader
  alias Spectre.State

  @checker_id "spectre.check.declarative"
  @checker_version 2
  @profile_ref "spectre.declarative.routing/2"

  @doc "Returns the checker versions trusted by the built-in Morph workflow."
  @spec checker_versions() :: map()
  def checker_versions do
    %{
      replay: {@checker_id, @checker_version},
      regression: {@checker_id, @checker_version}
    }
  end

  @doc "Runs protected and Candidate-owned cases against exact parent/Candidate refs."
  @spec run(term(), term(), [EvalCase.t() | map()], keyword()) ::
          {:ok, EvaluationDelta.t(), [Receipt.t()]} | {:error, term()}
  def run(store, candidate, cases, opts \\ [])

  def run(store, %{governance: %CandidateState{} = governance}, cases, opts)
      when is_list(cases) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: run_checked(store, governance, cases, opts),
      else: {:error, {:invalid_declarative_check, shape(cases), shape(opts)}}
  end

  def run(_store, _candidate, cases, opts),
    do: {:error, {:invalid_declarative_check, shape(cases), shape(opts)}}

  defp run_checked(store, governance, cases, opts) do
    issued_at = Keyword.get(opts, :issued_at, 0)
    protected = Keyword.get(opts, :protected_cases, cases)
    candidate_ids = governance.candidate_case_ids || []
    candidate_cases = governance.candidate_cases || []

    with {:ok, agent} <- checker_agent(opts),
         :ok <- live_path_supported(agent),
         {:ok, protected} <- normalize_cases(protected),
         {:ok, owned_cases} <- normalize_cases(candidate_cases),
         :ok <- candidate_case_ids(owned_cases, candidate_ids),
         {:ok, all_cases} <- normalize_cases(protected ++ owned_cases),
         :ok <- rehearsable_case_contract(all_cases),
         {:ok, parent} <- load(store, governance.parent_definition_ref, agent),
         {:ok, proposed} <- load(store, governance.candidate_definition_ref, agent),
         :ok <- declarative_only(parent.runtime),
         :ok <- declarative_only(proposed.runtime),
         {:ok, parent_results} <- evaluate(parent, protected),
         {:ok, candidate_results} <- evaluate(proposed, all_cases),
         {:ok, delta} <-
           EvaluationDelta.new(parent_results, candidate_results,
             protected_cases: Enum.map(protected, &EvalCase.to_data/1),
             candidate_case_ids: candidate_ids
           ),
         {:ok, receipts} <- receipts(governance, delta, issued_at) do
      {:ok, delta, receipts}
    end
  end

  defp checker_agent(opts) do
    case Keyword.get(opts, :agent) do
      agent when is_atom(agent) and not is_nil(agent) ->
        if Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_config__, 0) and
             function_exported?(agent, :__spectre_router__, 0) and
             function_exported?(agent, :__spectre_rules__, 0) do
          {:ok, agent}
        else
          {:error, {:invalid_declarative_checker_agent, agent}}
        end

      _value ->
        {:error, :declarative_checker_agent_required}
    end
  end

  defp load(store, definition_ref, agent) do
    Loader.load(store, definition_ref, agent, runtime_only?: true)
  end

  defp normalize_cases(cases) when is_list(cases) do
    cases
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, normalized} ->
      case EvalCase.new(value) do
        {:ok, evaluation_case} -> {:cont, {:ok, [evaluation_case | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_declarative_eval_case, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp normalize_cases(value),
    do: {:error, {:invalid_declarative_eval_cases, shape(value)}}

  defp candidate_case_ids(cases, expected) do
    actual = cases |> Enum.map(& &1.id) |> Enum.sort()

    if actual == Enum.sort(expected),
      do: :ok,
      else: {:error, {:declarative_candidate_cases_mismatch, expected, actual}}
  end

  defp evaluate(loaded, cases) do
    Enum.reduce_while(cases, {:ok, []}, fn evaluation_case, {:ok, results} ->
      case decide(loaded, evaluation_case) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end)
  end

  defp decide(loaded, %EvalCase{} = evaluation_case) do
    started_at = System.monotonic_time()

    with {:ok, context} <- evaluation_context(evaluation_case, loaded.surface),
         {:ok, input} <- normalize_input(loaded.agent, evaluation_case.input) do
      observed =
        observe(loaded, evaluation_case, input, context)
        |> Map.put(:duration_us, elapsed_us(started_at))

      {:ok,
       %{
         case_id: evaluation_case.id,
         passed: expectation_met?(evaluation_case, observed)
       }}
    end
  end

  defp observe(loaded, %EvalCase{state: state}, input, context) do
    runtime = loaded.runtime
    runtime_result = Runtime.respond(runtime, input, context, expected_revision: runtime.revision)
    state = State.new(state)
    input = Input.new(input)

    case runtime_result do
      {:ok, response, _runtime} ->
        runtime_observation(loaded.agent, state, input, response)

      {:error, :runtime_skill_route_not_found} ->
        loaded.agent
        |> compiled_observation(state, input)
        |> Map.delete(:accepted?)

      {:error, _reason} ->
        %{outcome: :error, route: nil, strategy: nil, llm_called?: false, output: nil}
    end
  end

  defp runtime_observation(agent, state, input, response) do
    case SkillDispatch.compiled_deterministic_route(agent, state, input) do
      {:ok, _label} ->
        %{outcome: :error, route: nil, strategy: nil, llm_called?: false, output: nil}

      :not_found ->
        %{
          outcome: :route,
          route: EvalCase.canonical(response.route_label),
          strategy: "RUNTIME_SKILL",
          llm_called?: false,
          output: response.output
        }
    end
  end

  defp compiled_observation(agent, state, input) do
    {:ok, %RouterReceipt{} = receipt} =
      Router.evaluate(agent, input, state: state, input_pipeline: [])

    %{
      outcome: receipt.outcome,
      route: EvalCase.canonical(receipt.label),
      strategy: EvalCase.canonical(receipt.strategy),
      llm_called?: receipt.llm_called? == true,
      output: nil,
      accepted?: receipt.accepted? == true
    }
  end

  defp expectation_met?(evaluation_case, observed) do
    routes = EvalCase.expected_routes(evaluation_case)

    evaluation_case.expected_outcome == observed.outcome and
      route_expectation_met?(routes, observed.route) and
      strategy_expectation_met?(evaluation_case.expected_strategy, observed.strategy) and
      llm_expectation_met?(evaluation_case.llm, observed.llm_called?) and
      duration_expectation_met?(evaluation_case.max_duration_us, observed.duration_us) and
      output_expectation_met?(evaluation_case.expected_output, observed.output)
  end

  defp route_expectation_met?([], _observed), do: true
  defp route_expectation_met?(routes, observed), do: observed in routes

  defp strategy_expectation_met?(nil, _observed), do: true

  defp strategy_expectation_met?(expected, observed),
    do: EvalCase.canonical(expected) == observed

  defp duration_expectation_met?(nil, _observed), do: true
  defp duration_expectation_met?(maximum, observed), do: observed <= maximum

  defp output_expectation_met?(nil, _observed), do: true
  defp output_expectation_met?(expected, observed), do: expected == observed

  defp llm_expectation_met?(:forbidden, called?), do: called? == false
  defp llm_expectation_met?(:required, called?), do: called? == true
  defp llm_expectation_met?(:allowed, _called?), do: true

  defp live_path_supported(agent) do
    config = agent.__spectre_config__()
    router = agent.__spectre_router__()
    input_pipeline = Keyword.get(config, :input_pipeline, [])
    turn_handlers = Keyword.get(config, :turn_handlers, [])
    custom_router_pipeline = Keyword.get(router, :pipeline)
    arbitrator = Keyword.get(router, :arbitrator)
    via = router |> Keyword.get(:via, [:regex]) |> List.wrap()
    rules = Spectre.Definition.rules(agent)
    semantic_cache? = Keyword.get(router, :semantic_cache?, true)

    with :ok <- turn_handlers_supported(turn_handlers),
         :ok <- router_pipeline_supported(custom_router_pipeline),
         :ok <- router_via_supported(via),
         :ok <- llm_router_supported(Keyword.get(router, :llm_classifier?, false)),
         :ok <- arbitrator_supported(arbitrator, router),
         :ok <- semantic_cache_supported(semantic_cache?, rules) do
      input_pipeline_supported(input_pipeline)
    end
  end

  defp turn_handlers_supported(value) when value in [nil, false, []], do: :ok

  defp turn_handlers_supported(_value),
    do: {:error, :declarative_checker_turn_handlers_not_rehearsable}

  defp router_pipeline_supported(nil), do: :ok

  defp router_pipeline_supported(_pipeline),
    do: {:error, :declarative_checker_custom_router_pipeline_not_rehearsable}

  defp router_via_supported([]),
    do: {:error, {:declarative_checker_router_not_rehearsable, []}}

  defp router_via_supported(via) do
    if Enum.all?(via, &(&1 == :regex)),
      do: :ok,
      else: {:error, {:declarative_checker_router_not_rehearsable, via}}
  end

  defp llm_router_supported(true),
    do: {:error, :declarative_checker_llm_router_not_rehearsable}

  defp llm_router_supported(_value), do: :ok

  defp arbitrator_supported(arbitrator, router) do
    if default_arbitrator?(arbitrator, router),
      do: :ok,
      else: {:error, :declarative_checker_custom_arbitrator_not_rehearsable}
  end

  defp semantic_cache_supported(value, _rules) when value not in [true, false],
    do: {:error, {:declarative_checker_invalid_semantic_cache, value}}

  defp semantic_cache_supported(true, rules) do
    if Enum.any?(rules, &Map.get(&1, :cache, true)),
      do: {:error, :declarative_checker_semantic_cache_not_rehearsable},
      else: :ok
  end

  defp semantic_cache_supported(false, _rules), do: :ok

  defp input_pipeline_supported(value) when value in [nil, false, []], do: :ok

  defp input_pipeline_supported(value) when is_list(value) do
    Enum.reduce_while(value, :ok, &check_input_plug/2)
  end

  defp input_pipeline_supported(value),
    do: {:error, {:declarative_checker_input_pipeline_not_rehearsable, shape(value)}}

  defp check_input_plug(spec, :ok) do
    case input_plug_module(spec) do
      {:ok, module} ->
        check_rehearsable_input_plug(module)

      :error ->
        {:halt, {:error, {:declarative_checker_input_pipeline_not_rehearsable, shape(spec)}}}
    end
  end

  defp check_rehearsable_input_plug(module) do
    if rehearsable_input_plug?(module),
      do: {:cont, :ok},
      else: {:halt, {:error, {:declarative_checker_input_plug_not_rehearsable, module}}}
  end

  defp default_arbitrator?(arbitrator, router) do
    case arbitrator do
      nil ->
        default_arbitrator_options?([], router)

      Spectre.Router.Arbitrators.Default ->
        default_arbitrator_options?([], router)

      {Spectre.Router.Arbitrators.Default, opts} when is_list(opts) ->
        if closed_keyword?(opts), do: default_arbitrator_options?(opts, router), else: false

      _custom ->
        false
    end
  end

  # Mirror Arbitrate's option precedence. A non-standard miss policy or an LLM
  # override would make the live fallback differ from the model-free receipt.
  defp default_arbitrator_options?(arbitrator_opts, router) do
    effective = Keyword.merge(arbitrator_opts, router)

    Keyword.get(effective, :no_decision, :llm) == :llm and
      not Spectre.Router.LLMClassifier.enabled?(effective)
  end

  defp closed_keyword?(opts) do
    Keyword.keyword?(opts) and
      opts |> Keyword.keys() |> Enum.uniq() |> length() == length(opts)
  end

  defp input_plug_module(module) when is_atom(module) and not is_nil(module), do: {:ok, module}

  defp input_plug_module({module, opts})
       when is_atom(module) and not is_nil(module) and is_list(opts),
       do: if(Keyword.keyword?(opts), do: {:ok, module}, else: :error)

  defp input_plug_module(%Spec{module: module}) when is_atom(module) and not is_nil(module),
    do: {:ok, module}

  defp input_plug_module(_spec), do: :error

  defp rehearsable_input_plug?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :rehearsable?, 0) and
      module.rehearsable?() == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp rehearsable_case_contract(cases) do
    with nil <- Enum.find(cases, &(not is_nil(&1.max_duration_us))),
         nil <- Enum.find(cases, &(&1.state not in [%{}, []])) do
      :ok
    else
      %{max_duration_us: duration, id: id} when not is_nil(duration) ->
        {:error, {:declarative_checker_duration_not_rehearsable, id}}

      %{id: id} ->
        {:error, {:declarative_checker_state_not_rehearsable, id}}
    end
  end

  defp normalize_input(agent, input) do
    config = agent.__spectre_config__()
    specs = Keyword.get(config, :input_pipeline, [])
    input = Input.new(input)

    normalized =
      if specs in [nil, false, []] do
        {:ok, input}
      else
        Pipeline.run(input, %{agent: agent, opts: []}, specs)
      end

    with {:ok, input} <- normalized,
         :ok <- input_size(input, Keyword.get(config, :input_max_bytes, 64_000)) do
      {:ok, input}
    end
  rescue
    error -> {:error, {:declarative_checker_input_pipeline_failed, error.__struct__}}
  catch
    kind, _reason -> {:error, {:declarative_checker_input_pipeline_failed, kind}}
  end

  defp input_size(%Input{text: text}, max_bytes) when is_binary(text) do
    if is_integer(max_bytes) and max_bytes > 0 and byte_size(text) <= max_bytes,
      do: :ok,
      else: {:error, {:payload_too_large, :input, byte_size(text), max_bytes}}
  end

  defp elapsed_us(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> max(0)
  end

  defp evaluation_context(%EvalCase{context: context}, _surface) when map_size(context) > 0,
    do: {:ok, context}

  defp evaluation_context(%EvalCase{}, %{scope_ceiling: [scope]}),
    do: {:ok, %{"scope" => scope}}

  defp evaluation_context(%EvalCase{}, %{scope_ceiling: scopes}),
    do: {:error, {:declarative_eval_context_required, scopes}}

  defp declarative_only(runtime) do
    Enum.reduce_while(runtime.mounts, :ok, fn {mount_id, entry}, :ok ->
      definition = entry.definition

      cond do
        SkillDefinition.operation_refs(definition) != [] ->
          {:halt, {:error, {:not_declarative, mount_id, :operations}}}

        SkillDefinition.works(definition) != [] ->
          {:halt, {:error, {:not_declarative, mount_id, :works}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp receipts(governance, delta, issued_at) do
    [:replay, :regression]
    |> Enum.reduce_while({:ok, []}, fn gate, {:ok, receipts} ->
      attrs = %{
        gate_class: gate,
        candidate_digest: governance.proposal_digest,
        parent_definition_ref: governance.parent_definition_ref,
        candidate_definition_ref: governance.candidate_definition_ref,
        closure_digest: governance.closure_digest,
        checker_id: @checker_id,
        checker_version: @checker_version,
        evaluation_cases_digest: governance.evaluation_cases_digest,
        profile_ref: if(gate == :replay, do: @profile_ref),
        issued_at: issued_at,
        status: if(delta.passed, do: :passed, else: :failed),
        result_digest: EvaluationDelta.digest(delta),
        provenance: %{source: :declarative_routing, model_free: true}
      }

      case Receipt.new(attrs) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | receipts]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, receipts} -> {:ok, Enum.reverse(receipts)}
      {:error, _reason} = error -> error
    end)
  end

  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
