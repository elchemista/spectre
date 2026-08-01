defmodule Spectre.Operation.Executor do
  @moduledoc "Executes one closed-catalog operation inside a temporary Runner."

  alias Spectre.Action
  alias Spectre.ActionDispatcher
  alias Spectre.Effect
  alias Spectre.Effect.Executor, as: EffectExecutor
  alias Spectre.Inference
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Operation.Execution
  alias Spectre.Operation.ExecutionContext
  alias Spectre.Operation.Policy
  alias Spectre.Operation.Request
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Validator
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure

  @type result :: {:ok, term()} | {:error, term()} | {:ambiguous, term()}

  @spec execute(Spec.t(), Request.t(), ExecutionContext.t()) :: result()
  def execute(%Spec{} = spec, %Request{} = request, %ExecutionContext{} = context) do
    result =
      with :ok <- Validator.validate(spec.input, request.input, {:operation_input, spec.id}),
           :ok <- portable(request.input, [:operation, spec.id, :input]),
           :ok <- Policy.authorize(spec, request, context),
           {:ok, value} <- invoke(spec, request, context) do
        execution = Execution.normalize(value)

        case validate_execution(spec, execution) do
          :ok -> {:ok, execution}
          {:error, reason} -> cognitive_fallback(spec, request, context, reason)
        end
      end

    case result do
      {:ok, %Execution{}} = success -> success
      {:error, %Failure{} = failure} -> classify_failure(spec, failure)
      {:error, reason} -> classify_declared_error(spec, reason)
    end
  end

  @spec reconcile(Spec.t(), term(), ExecutionContext.t()) :: result()
  def reconcile(%Spec{reconcile: reconcile} = spec, receipt, %ExecutionContext{} = context) do
    if is_nil(reconcile) do
      {:error, {:operation_not_reconcilable, spec.id}}
    else
      with {:ok, value} <- call_registered(reconcile, receipt, context, spec) do
        execution = Execution.normalize(value)

        case validate_execution(spec, execution) do
          :ok -> {:ok, execution}
          {:error, _reason} = error -> error
        end
      end
    end
  end

  defp validate_execution(spec, %Execution{} = execution) do
    with :ok <- Execution.validate(execution),
         :ok <- Validator.validate(spec.output, execution.value, {:operation_output, spec.id}),
         :ok <-
           Validator.domain(
             spec.domain,
             domain_value(execution.value),
             {:operation_domain, spec.id}
           ) do
      portable(execution, [:operation, spec.id, :output])
    end
  end

  defp cognitive_fallback(
         %Spec{kind: :cognitive, fallback: fallback} = spec,
         request,
         context,
         reason
       )
       when not is_nil(fallback) do
    current_attempt = context.attempt.retry_number + 1

    if current_attempt >= spec.retry.max_attempts do
      input = %{input: request.input, error: reason, attempt: current_attempt}

      case call_registered(fallback, input, context, spec) do
        {:ok, value} ->
          execution = Execution.normalize(value)

          execution = %{
            execution
            | metadata:
                execution.metadata
                |> Map.put(:cognitive_fallback, true)
                |> Map.put(:primary_error, reason)
          }

          case validate_execution(spec, execution) do
            :ok ->
              {:ok, execution}

            {:error, fallback_reason} ->
              {:error, {:cognitive_fallback_invalid, spec.id, reason, fallback_reason}}
          end

        {:error, fallback_reason} ->
          {:error, {:cognitive_fallback_failed, spec.id, reason, fallback_reason}}
      end
    else
      {:error, reason}
    end
  end

  defp cognitive_fallback(_spec, _request, _context, reason), do: {:error, reason}

  defp invoke(%Spec{kind: :function, executor: executor} = spec, request, context),
    do: call_registered(executor, request.input, context, spec)

  defp invoke(%Spec{kind: :cognitive, executor: :inference}, request, context),
    do: inference(request.input, context)

  defp invoke(%Spec{kind: :cognitive, executor: executor} = spec, request, context),
    do: call_registered(executor, request.input, context, spec)

  defp invoke(%Spec{kind: :planner, executor: executor} = spec, request, context) do
    with {:ok, proposal} <- call_registered(executor, request.input, context, spec),
         {:ok, selected} <- selected_operation(proposal),
         true <- selected in spec.catalog do
      {:ok, proposal}
    else
      false -> {:error, {:planner_operation_outside_catalog, spec.id}}
      {:error, _reason} = error -> error
    end
  end

  defp invoke(%Spec{kind: :action} = spec, request, context) do
    attrs = if is_list(spec.executor), do: Map.new(spec.executor), else: spec.executor
    name = Map.get(attrs, :name, Map.get(attrs, "name", spec.id))
    via = Map.get(attrs, :via, Map.get(attrs, "via", :local))
    owner = Map.get(attrs, :owner, Map.get(attrs, "owner", context.agent))
    scope = Map.get(attrs, :scope, Map.get(attrs, "scope", :agent))

    action =
      Action.new(name,
        via: via,
        args: normalize_args(request.input),
        mode: Map.get(attrs, :mode, Map.get(attrs, "mode")),
        metadata: Map.get(attrs, :metadata, Map.get(attrs, "metadata", %{}))
      )

    effect = action |> Action.to_effect_attrs() |> Effect.stage_action(owner, scope)
    ActionDispatcher.dispatch(effect, spectre_context(context), operation_opts(spec, context))
  end

  defp invoke(%Spec{kind: :effect, executor: nil} = spec, request, context) do
    dispatch_effect(request.input, spec, context)
  end

  defp invoke(%Spec{kind: :effect, executor: executor} = spec, request, context) do
    with {:ok, effect} <- call_registered(executor, request.input, context, spec) do
      dispatch_effect(effect, spec, context)
    end
  end

  defp dispatch_effect(%Effect{kind: :action} = effect, spec, context),
    do: ActionDispatcher.dispatch(effect, spectre_context(context), operation_opts(spec, context))

  defp dispatch_effect(%Effect{} = effect, spec, context),
    do: EffectExecutor.dispatch(effect, spectre_context(context), operation_opts(spec, context))

  defp dispatch_effect(value, spec, _context),
    do: {:error, {:invalid_operation_effect, spec.id, shape(value)}}

  defp call_registered({module, function}, input, context, spec),
    do: call_registered(module, function, input, context, spec)

  defp call_registered(module, input, context, spec) when is_atom(module),
    do: call_registered(module, :execute, input, context, spec)

  defp call_registered(module, function, input, context, spec) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:operation_executor_not_loaded, spec.id, module}}

      function_exported?(module, function, 2) ->
        bounded_call(spec, fn -> normalize_reply(apply(module, function, [input, context])) end)

      function_exported?(module, function, 1) ->
        bounded_call(spec, fn -> normalize_reply(apply(module, function, [input])) end)

      true ->
        {:error, {:operation_executor_missing, spec.id, module, function}}
    end
  end

  defp bounded_call(spec, callback) do
    Call.run(
      :run,
      callback,
      run_timeout: spec.timeout,
      purpose: :operational_loop
    )
  end

  defp inference(%InferenceRequest{} = request, context) do
    Inference.complete(context.agent, request, spectre_context(context))
  end

  defp inference(value, _context), do: {:error, {:invalid_cognitive_request, shape(value)}}

  defp spectre_context(context) do
    input =
      case context.input do
        %Spectre.Input{} = input -> input
        value when is_binary(value) or is_map(value) -> Spectre.Input.new(value)
        _other -> Spectre.Input.new("")
      end

    %Spectre.Context{
      agent: context.agent,
      input: input,
      state: context.state,
      opts: context.opts,
      assigns: %{
        operation_loop_id: context.loop_id,
        operation_attempt: context.attempt.id,
        cognitive: context.cognitive
      }
    }
  end

  defp operation_opts(spec, context) do
    context.opts
    |> Keyword.put(:operation_id, spec.id)
    |> Keyword.put(:operation_attempt_id, context.attempt.id)
    |> Keyword.put(:idempotency_key, context.attempt.idempotency_key)
  end

  defp normalize_reply({:ok, _value} = result), do: result
  defp normalize_reply({:error, _reason} = result), do: result
  defp normalize_reply(value), do: {:ok, value}

  defp classify_failure(spec, %Failure{kind: kind} = failure)
       when kind in [:timeout, :exception, :exit, :throw, :crash] and
              spec.side_effect != :none,
       do: {:ambiguous, failure}

  defp classify_failure(_spec, failure), do: {:error, failure}

  defp classify_declared_error(_spec, {:action_outcome_ambiguous, _reason} = reason),
    do: {:ambiguous, reason}

  defp classify_declared_error(_spec, {:effect_outcome_ambiguous, _kind, _reason} = reason),
    do: {:ambiguous, reason}

  defp classify_declared_error(_spec, reason), do: {:error, reason}

  defp selected_operation(%{operation: operation}), do: {:ok, operation}
  defp selected_operation(%{"operation" => operation}), do: {:ok, operation}
  defp selected_operation(%Action{name: name}), do: {:ok, name}
  defp selected_operation(value) when is_atom(value) or is_binary(value), do: {:ok, value}
  defp selected_operation(value), do: {:error, {:invalid_planner_proposal, shape(value)}}

  defp domain_value(%Spectre.Inference.Response{text: text}), do: text
  defp domain_value(%{value: value}), do: value
  defp domain_value(value), do: value

  defp normalize_args(value) when is_map(value), do: value
  defp normalize_args(nil), do: %{}
  defp normalize_args(value), do: %{value: value}

  defp portable(value, path) do
    case Spectre.Run.Value.validate(value, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operation_value, reason}}
    end
  end

  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp shape(_value), do: :other
end
