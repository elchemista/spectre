defmodule Spectre.Operation.Policy do
  @moduledoc """
  Deterministic authorization gate for a registered operational capability.

  Registration is the default authorization boundary. Sensitive operations can
  additionally name a stable module or `{module, function}` callback in their
  `policy:` option. The callback executes inside the temporary Runner and may
  return `:ok`, `true`, or `{:error, reason}`.
  """

  alias Spectre.Operation.ExecutionContext
  alias Spectre.Operation.Request
  alias Spectre.Operation.Spec

  @spec authorize(Spec.t(), Request.t(), ExecutionContext.t()) :: :ok | {:error, term()}
  def authorize(%Spec{policy: policy}, _request, _context) when policy in [nil, :registered],
    do: :ok

  def authorize(%Spec{} = spec, %Request{} = request, %ExecutionContext{} = context) do
    {module, function} = normalize_ref(spec.policy)

    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:operation_policy_not_loaded, spec.id, module}}

      function_exported?(module, function, 3) ->
        normalize(apply(module, function, [spec, request, context]), spec)

      function_exported?(module, function, 2) ->
        normalize(apply(module, function, [request, context]), spec)

      true ->
        {:error, {:operation_policy_callback_missing, spec.id, module, function}}
    end
  rescue
    exception -> {:error, {:operation_policy_exception, spec.id, exception.__struct__}}
  catch
    kind, reason -> {:error, {:operation_policy_failure, spec.id, kind, reason}}
  end

  defp normalize_ref({module, function}), do: {module, function}
  defp normalize_ref(module), do: {module, :authorize}

  defp normalize(:ok, _spec), do: :ok
  defp normalize(true, _spec), do: :ok
  defp normalize({:ok, _authorization}, _spec), do: :ok
  defp normalize(false, spec), do: {:error, {:operation_not_authorized, spec.id}}

  defp normalize({:error, reason}, spec),
    do: {:error, {:operation_not_authorized, spec.id, reason}}

  defp normalize(value, spec),
    do: {:error, {:invalid_operation_policy_reply, spec.id, value}}
end
