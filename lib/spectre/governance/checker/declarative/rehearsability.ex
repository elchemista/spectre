defmodule Spectre.Governance.Checker.Declarative.Rehearsability do
  @moduledoc """
  Defines the closed live behavior that the declarative checker can replay.

  Agent callbacks are sampled behind a protected boundary. Custom routers,
  effectful handlers, model-backed routing, stateful cases, and unmarked input
  plugs are refused rather than represented by optimistic test evidence.
  """

  alias Spectre.Definition
  alias Spectre.Eval.Case, as: EvalCase
  alias Spectre.Input.Pipeline.Spec
  alias Spectre.Router.Arbitrators.Default
  alias Spectre.Router.LLMClassifier
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime

  @required_callbacks [
    __spectre_config__: 0,
    __spectre_router__: 0,
    __spectre_rules__: 0
  ]

  @type agent_snapshot :: %{
          required(:agent) => module(),
          required(:config) => keyword(),
          required(:router) => keyword(),
          required(:rules) => [map()]
        }
  @type result :: :ok | {:error, term()}

  @doc false
  @spec agent_snapshot(keyword()) :: {:ok, agent_snapshot()} | {:error, term()}
  def agent_snapshot(opts) do
    case Keyword.get(opts, :agent) do
      agent when is_atom(agent) and not is_nil(agent) -> build_agent_snapshot(agent)
      _value -> {:error, :declarative_checker_agent_required}
    end
  end

  @doc false
  @spec verify_live_path(agent_snapshot()) :: result()
  def verify_live_path(snapshot) do
    input_pipeline = Keyword.get(snapshot.config, :input_pipeline, [])
    turn_handlers = Keyword.get(snapshot.config, :turn_handlers, [])
    custom_router_pipeline = Keyword.get(snapshot.router, :pipeline)
    arbitrator = Keyword.get(snapshot.router, :arbitrator)
    via = snapshot.router |> Keyword.get(:via, [:regex]) |> List.wrap()
    semantic_cache? = Keyword.get(snapshot.router, :semantic_cache?, true)

    with :ok <- turn_handlers_supported(turn_handlers),
         :ok <- router_pipeline_supported(custom_router_pipeline),
         :ok <- router_via_supported(via),
         :ok <- llm_router_supported(Keyword.get(snapshot.router, :llm_classifier?, false)),
         :ok <- arbitrator_supported(arbitrator, snapshot.router),
         :ok <- semantic_cache_supported(semantic_cache?, snapshot.rules) do
      input_pipeline_supported(input_pipeline)
    end
  end

  @doc false
  @spec verify_cases([EvalCase.t()]) :: result()
  def verify_cases(cases) do
    cases
    |> Enum.reduce_while(:ok, &verify_case/2)
    |> case do
      :ok -> :ok
      {:state, id} -> {:error, {:declarative_checker_state_not_rehearsable, id}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec verify_runtime(Runtime.t()) :: result()
  def verify_runtime(%Runtime{} = runtime) do
    Enum.reduce_while(runtime.mounts, :ok, &verify_mount/2)
  end

  @spec build_agent_snapshot(module()) :: {:ok, agent_snapshot()} | {:error, term()}
  defp build_agent_snapshot(agent) do
    if valid_agent?(agent) do
      with {:ok, config} <- invoke_agent_boundary(agent, :__spectre_config__),
           :ok <- callback_shape(:__spectre_config__, config, :keyword),
           {:ok, router} <- invoke_agent_boundary(agent, :__spectre_router__),
           :ok <- callback_shape(:__spectre_router__, router, :keyword),
           {:ok, rules} <- invoke_definition_rules(agent),
           :ok <- callback_shape(:definition_rules, rules, :rules) do
        {:ok, %{agent: agent, config: config, router: router, rules: rules}}
      end
    else
      {:error, {:invalid_declarative_checker_agent, agent}}
    end
  end

  @spec valid_agent?(module()) :: boolean()
  defp valid_agent?(agent) do
    Code.ensure_loaded?(agent) and
      Enum.all?(@required_callbacks, fn {function, arity} ->
        function_exported?(agent, function, arity)
      end)
  end

  @spec invoke_agent_boundary(module(), atom()) :: {:ok, term()} | {:error, term()}
  defp invoke_agent_boundary(agent, callback) do
    protect_agent_boundary(callback, fn -> apply(agent, callback, []) end)
  end

  @spec invoke_definition_rules(module()) :: {:ok, term()} | {:error, term()}
  defp invoke_definition_rules(agent) do
    protect_agent_boundary(:definition_rules, fn -> Definition.rules(agent) end)
  end

  @spec protect_agent_boundary(atom(), (-> term())) :: {:ok, term()} | {:error, term()}
  defp protect_agent_boundary(callback, function) do
    {:ok, function.()}
  rescue
    exception ->
      {:error,
       {:declarative_checker_agent_callback_failed, callback, {:exception, exception.__struct__}}}
  catch
    kind, _reason ->
      {:error, {:declarative_checker_agent_callback_failed, callback, {:signal, kind}}}
  end

  @spec callback_shape(atom(), term(), :keyword | :rules) :: result()
  defp callback_shape(callback, value, :keyword) when is_list(value) do
    if Keyword.keyword?(value),
      do: :ok,
      else: callback_reply_error(callback, value)
  end

  defp callback_shape(callback, value, :rules) when is_list(value) do
    if Enum.all?(value, &is_map/1),
      do: :ok,
      else: callback_reply_error(callback, value)
  end

  defp callback_shape(callback, value, _expected), do: callback_reply_error(callback, value)

  @spec callback_reply_error(atom(), term()) :: {:error, term()}
  defp callback_reply_error(callback, value) do
    {:error,
     {:declarative_checker_agent_callback_failed, callback, {:invalid_reply, shape(value)}}}
  end

  @spec turn_handlers_supported(term()) :: result()
  defp turn_handlers_supported(value) when value in [nil, false, []], do: :ok

  defp turn_handlers_supported(_value),
    do: {:error, :declarative_checker_turn_handlers_not_rehearsable}

  @spec router_pipeline_supported(term()) :: result()
  defp router_pipeline_supported(nil), do: :ok

  defp router_pipeline_supported(_pipeline),
    do: {:error, :declarative_checker_custom_router_pipeline_not_rehearsable}

  @spec router_via_supported([term()]) :: result()
  defp router_via_supported([]),
    do: {:error, {:declarative_checker_router_not_rehearsable, []}}

  defp router_via_supported(via) do
    if Enum.all?(via, &(&1 == :regex)),
      do: :ok,
      else: {:error, {:declarative_checker_router_not_rehearsable, via}}
  end

  @spec llm_router_supported(term()) :: result()
  defp llm_router_supported(true),
    do: {:error, :declarative_checker_llm_router_not_rehearsable}

  defp llm_router_supported(_value), do: :ok

  @spec arbitrator_supported(term(), keyword()) :: result()
  defp arbitrator_supported(arbitrator, router) do
    if default_arbitrator?(arbitrator, router),
      do: :ok,
      else: {:error, :declarative_checker_custom_arbitrator_not_rehearsable}
  end

  @spec semantic_cache_supported(term(), [map()]) :: result()
  defp semantic_cache_supported(value, _rules) when value not in [true, false],
    do: {:error, {:declarative_checker_invalid_semantic_cache, value}}

  defp semantic_cache_supported(true, rules) do
    if Enum.any?(rules, &Map.get(&1, :cache, true)),
      do: {:error, :declarative_checker_semantic_cache_not_rehearsable},
      else: :ok
  end

  defp semantic_cache_supported(false, _rules), do: :ok

  @spec input_pipeline_supported(term()) :: result()
  defp input_pipeline_supported(value) when value in [nil, false, []], do: :ok

  defp input_pipeline_supported(value) when is_list(value) do
    Enum.reduce_while(value, :ok, &check_input_plug/2)
  end

  defp input_pipeline_supported(value),
    do: {:error, {:declarative_checker_input_pipeline_not_rehearsable, shape(value)}}

  @spec check_input_plug(term(), :ok) :: {:cont, :ok} | {:halt, {:error, term()}}
  defp check_input_plug(spec, :ok) do
    case input_plug_module(spec) do
      {:ok, module} ->
        check_rehearsable_input_plug(module)

      :error ->
        {:halt, {:error, {:declarative_checker_input_pipeline_not_rehearsable, shape(spec)}}}
    end
  end

  @spec check_rehearsable_input_plug(module()) :: {:cont, :ok} | {:halt, {:error, term()}}
  defp check_rehearsable_input_plug(module) do
    if rehearsable_input_plug?(module),
      do: {:cont, :ok},
      else: {:halt, {:error, {:declarative_checker_input_plug_not_rehearsable, module}}}
  end

  @spec default_arbitrator?(term(), keyword()) :: boolean()
  defp default_arbitrator?(arbitrator, router) do
    case arbitrator do
      nil ->
        default_arbitrator_options?([], router)

      Default ->
        default_arbitrator_options?([], router)

      {Default, opts} when is_list(opts) ->
        closed_keyword?(opts) and default_arbitrator_options?(opts, router)

      _custom ->
        false
    end
  end

  # Mirror Arbitrate's option precedence. A non-standard miss policy or an LLM
  # override would make the live fallback differ from the model-free receipt.
  @spec default_arbitrator_options?(keyword(), keyword()) :: boolean()
  defp default_arbitrator_options?(arbitrator_opts, router) do
    effective = Keyword.merge(arbitrator_opts, router)

    Keyword.get(effective, :no_decision, :llm) == :llm and
      not LLMClassifier.enabled?(effective)
  end

  @spec closed_keyword?(list()) :: boolean()
  defp closed_keyword?(opts) do
    Keyword.keyword?(opts) and
      opts |> Keyword.keys() |> Enum.uniq() |> length() == length(opts)
  end

  @spec input_plug_module(term()) :: {:ok, module()} | :error
  defp input_plug_module(module) when is_atom(module) and not is_nil(module), do: {:ok, module}

  defp input_plug_module({module, opts})
       when is_atom(module) and not is_nil(module) and is_list(opts),
       do: if(Keyword.keyword?(opts), do: {:ok, module}, else: :error)

  defp input_plug_module(%Spec{module: module}) when is_atom(module) and not is_nil(module),
    do: {:ok, module}

  defp input_plug_module(_spec), do: :error

  @spec rehearsable_input_plug?(module()) :: boolean()
  defp rehearsable_input_plug?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :rehearsable?, 0) and
      module.rehearsable?() == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  @spec verify_case(EvalCase.t(), :ok | {:state, String.t()}) ::
          {:cont, :ok | {:state, String.t()}} | {:halt, {:error, term()}}
  defp verify_case(%EvalCase{max_duration_us: duration, id: id}, _state)
       when not is_nil(duration) do
    {:halt, {:error, {:declarative_checker_duration_not_rehearsable, id}}}
  end

  defp verify_case(%EvalCase{state: state, id: id}, :ok) when state not in [%{}, []],
    do: {:cont, {:state, id}}

  defp verify_case(%EvalCase{}, state), do: {:cont, state}

  @spec verify_mount({term(), Runtime.entry()}, :ok) :: {:cont, :ok} | {:halt, {:error, term()}}
  defp verify_mount({mount_id, entry}, :ok) do
    definition = entry.definition

    cond do
      SkillDefinition.operation_refs(definition) != [] ->
        {:halt, {:error, {:not_declarative, mount_id, :operations}}}

      SkillDefinition.works(definition) != [] ->
        {:halt, {:error, {:not_declarative, mount_id, :works}}}

      true ->
        {:cont, :ok}
    end
  end

  @spec shape(term()) :: :list | :map | :tuple | :other
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
