defmodule Spectre.Server.Command do
  @moduledoc false
  @enforce_keys [:kind, :args]
  defstruct [:kind, :args, opts: []]

  @type t :: %__MODULE__{kind: atom(), args: list(), opts: keyword()}

  @kinds [
    :respond,
    :generate,
    :classify,
    :propose,
    :call_actor,
    :delegate,
    :tool,
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

  def validate_internal(%__MODULE__{kind: :tool_call, args: [identity, _args], opts: opts})
      when is_map(identity) and is_list(opts), do: timeout(opts)

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

  defp validate_args(:delegate, [id, input], opts) when not is_nil(id) do
    with :ok <- Spectre.Server.Skills.validate_input(input), do: timeout(opts)
  end

  defp validate_args(:call_actor, [_actor, _request], opts), do: timeout(opts)
  defp validate_args(:await_reply, [id], opts) when not is_nil(id), do: timeout(opts)
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
