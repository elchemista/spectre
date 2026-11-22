defmodule Spectre.Server.Command do
  @moduledoc false
  @enforce_keys [:kind, :args]
  defstruct [:kind, :args, opts: []]

  alias Spectre.Server.Checkpoint
  alias Spectre.Stack.Value, as: StackValue

  @type t :: %__MODULE__{kind: atom(), args: list(), opts: keyword()}

  @kinds [
    :respond,
    :generate,
    :classify,
    :propose,
    :call_actor,
    :delegate,
    :tool,
    :call_tool,
    :start_activity,
    :signal_activity,
    :cancel_activity,
    :complete_activity,
    :fail_activity,
    :await_reply,
    :resolve_await,
    :confirm_pending,
    :reject_pending,
    :explain_pending,
    :resume_pending,
    :close_pending,
    :close_pending_after,
    :cancel_pending_close,
    :route_current_input,
    :no_response
  ]

  def validate(%__MODULE__{kind: kind, args: args, opts: opts})
      when kind in @kinds and is_list(args) and is_list(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_options}

      Keyword.has_key?(opts, :tool_origin) ->
        {:error, :reserved_tool_options}

      Keyword.has_key?(opts, :external_submission) ->
        {:error, :reserved_submission_options}

      Keyword.has_key?(opts, :lifecycle_recorded) or
          Keyword.has_key?(opts, :lifecycle_authorized) ->
        {:error, :reserved_lifecycle_options}

      true ->
        validate_args(kind, args, opts)
    end
  end

  def validate(_), do: {:error, :invalid_command}

  def validate_internal(%__MODULE__{kind: :tool_call, args: [%{tool: tool}, _args], opts: opts})
      when is_list(opts) do
    if activity_name(tool) == :ok or tool_reference?(tool),
      do: timeout(opts),
      else: {:error, :invalid_tool_ref}
  end

  def validate_internal(%__MODULE__{kind: :tool_rejected, args: [_result], opts: opts})
      when is_list(opts), do: :ok

  def validate_internal(%__MODULE__{kind: :delegate_route, args: [_id], opts: opts}),
    do: timeout(opts)

  def validate_internal(%__MODULE__{kind: :propose, opts: opts} = command),
    do: validate(%{command | opts: Keyword.delete(opts, :external_submission)})

  def validate_internal(command), do: validate(command)

  defp validate_args(:respond, [content], _opts) when is_binary(content) or is_atom(content),
    do: :ok

  defp validate_args(:generate, [prompt], opts) when is_atom(prompt) or is_binary(prompt),
    do: generation(opts)

  defp validate_args(:classify, [_input], opts), do: timeout(opts)

  defp validate_args(:propose, [name, args], opts)
       when (is_atom(name) or is_binary(name) or is_tuple(name)) and is_map(args),
       do:
         if(Keyword.has_key?(opts, :timeout),
           do: {:error, :governed_timeout_owned_by_host},
           else: :ok
         )

  defp validate_args(:tool, [name, _input, expected], opts)
       when is_atom(name) and is_map(expected), do: timeout(opts)

  defp validate_args(:call_tool, [ref, _input], opts),
    do: if(tool_reference?(ref), do: timeout(opts), else: {:error, :invalid_tool_ref})

  defp validate_args(:start_activity, [type, args], opts) do
    with :ok <- activity_type(type),
         :ok <- activity_key(Keyword.get(opts, :as)),
         :ok <- activity_scope(Keyword.get(opts, :scope, :all)),
         :ok <- activity_options(opts, [:as, :on_result, :scope]) do
      Checkpoint.validate_value(args)
    end
  end

  defp validate_args(:signal_activity, [target, signal], opts) do
    with :ok <- activity_control(target, opts),
         :ok <- Spectre.Server.ActivityBinding.validate_signal({:signal, signal}),
         do: Checkpoint.validate_value(signal)
  end

  defp validate_args(:cancel_activity, [target], opts), do: activity_control(target, opts)

  defp validate_args(kind, [value], []) when kind in [:complete_activity, :fail_activity],
    do: Checkpoint.validate_value(value)

  defp validate_args(:delegate, [id, input], opts) when not is_nil(id) do
    with :ok <- Spectre.Server.Skills.validate_input(input), do: timeout(opts)
  end

  defp validate_args(:call_actor, [_actor, _request], opts), do: timeout(opts)

  defp validate_args(:await_reply, [id], opts) when not is_nil(id) do
    with :ok <- timeout(opts), do: Spectre.Server.InputWait.validate(opts)
  end

  defp validate_args(:resolve_await, [id, _result], _opts) when not is_nil(id), do: :ok

  defp validate_args(kind, [id], opts)
       when kind in [:close_pending, :cancel_pending_close] and not is_nil(id),
       do: pending_lifecycle_options(opts)

  defp validate_args(:close_pending_after, [id, delay], opts)
       when not is_nil(id) and is_integer(delay) and delay >= 0 and delay <= 4_294_967_295,
       do: pending_lifecycle_options(opts)

  defp validate_args(kind, [id], _opts)
       when kind in [:confirm_pending, :reject_pending, :explain_pending, :resume_pending] and
              not is_nil(id),
       do: :ok

  defp validate_args(:route_current_input, [], _opts), do: :ok
  defp validate_args(:no_response, [], _opts), do: :ok
  defp validate_args(_, _, _), do: {:error, :invalid_command_arguments}

  defp activity_type({installation, type}) do
    if StackValue.valid_id?(installation),
      do: activity_name(type),
      else: {:error, :invalid_activity_type}
  end

  defp activity_type(type), do: activity_name(type)

  defp activity_key(nil), do: :ok
  defp activity_key(key), do: activity_name(key)

  defp activity_name(name) when is_atom(name) and name not in [nil, true, false], do: :ok
  defp activity_name(_name), do: {:error, :invalid_activity_name}

  defp activity_target(ref) when is_binary(ref) and byte_size(ref) > 0, do: :ok
  defp activity_target(key), do: activity_name(key)

  defp activity_scope(:all), do: :ok

  defp activity_scope(scope) when is_list(scope) do
    if Enum.all?(scope, &tool_reference?/1), do: :ok, else: {:error, :invalid_activity_scope}
  end

  defp activity_scope(_), do: {:error, :invalid_activity_scope}

  defp tool_reference?({installation, operation}),
    do: StackValue.valid_id?(installation) and activity_name(operation) == :ok

  defp tool_reference?(_), do: false

  defp activity_control(target, opts) do
    with :ok <- activity_target(target),
         :ok <- activity_options(opts, [:if_revision, :on_result]) do
      case Keyword.get(opts, :if_revision) do
        nil -> :ok
        revision when is_integer(revision) and revision >= 0 -> :ok
        _ -> {:error, :invalid_activity_revision}
      end
    end
  end

  defp activity_options(opts, allowed) do
    keys = Keyword.keys(opts)

    if Enum.uniq(keys) == keys and keys -- allowed == [],
      do: Checkpoint.validate_value(opts),
      else: {:error, :invalid_activity_options}
  end

  defp timeout(opts) do
    case Keyword.get(opts, :timeout, 30_000) do
      n when is_integer(n) and n > 0 -> :ok
      :infinity -> :ok
      _ -> {:error, :invalid_timeout}
    end
  end

  defp generation(opts) do
    with :ok <- timeout(opts) do
      if is_boolean(Keyword.get(opts, :planning, false)) and
           is_boolean(Keyword.get(opts, :stream, false)) and
           Keyword.get(opts, :preview, :auto) in [:auto, :off, :required],
         do: :ok,
         else: {:error, :invalid_generation_options}
    end
  end

  defp pending_lifecycle_options(opts) do
    with :ok <- close_reason(Keyword.get(opts, :reason, :policy)),
         :ok <- pending_revision(Keyword.get(opts, :if_revision)),
         :ok <- pending_reference(Keyword.get(opts, :policy_ref), :invalid_pending_policy_ref),
         :ok <- pending_reference(Keyword.get(opts, :if_schedule), :invalid_pending_schedule) do
      timer_owner(Keyword.get(opts, :timer, :runtime))
    end
  end

  defp close_reason(reason) when is_atom(reason) or is_binary(reason), do: :ok
  defp close_reason(_), do: {:error, :invalid_pending_close_reason}
  defp pending_revision(nil), do: :ok
  defp pending_revision(revision) when is_integer(revision) and revision > 0, do: :ok
  defp pending_revision(_), do: {:error, :invalid_pending_revision}
  defp pending_reference(nil, _error), do: :ok
  defp pending_reference(ref, _error) when is_binary(ref) and byte_size(ref) > 0, do: :ok
  defp pending_reference(_, error), do: {:error, error}
  defp timer_owner(owner) when owner in [:runtime, :application], do: :ok
  defp timer_owner(_), do: {:error, :invalid_pending_timer_owner}
end
