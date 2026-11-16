defmodule Spectre.Server.Planning do
  @moduledoc """
  Prepares action candidates from consolidated model output without execution.

  Package adapters receive a Server service context and may call `prepare/2`.
  The Agent's registered planner and closed provider catalog are used with the
  original event's owner and scope. Returned actions include the metadata needed
  by `Spectre.Server.propose/4`; they are not admitted or executed by this API.
  """
  alias Spectre.Server.{Catalog, ServiceContext}

  @spec prepare(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def prepare(text, service_context) when is_binary(text) and is_map(service_context) do
    context = ServiceContext.legacy(service_context, service_context.input, [], %{})
    prepare_context(text, context)
  end

  @doc false
  def prepare_context(text, %Spectre.Context{} = context) do
    with {:ok, result} <-
           Spectre.ActionPlanner.plan_response(text, context, Catalog.planner_options(context)) do
      {:ok, %{text: result.reply_text, actions: Enum.map(result.effects, &proposal/1)}}
    end
  end

  defp proposal(effect) do
    action = Spectre.Action.from_effect(effect)

    %{
      operation: Catalog.operation(action, effect.scope),
      args: effect.args,
      metadata: %{
        provider: action.via,
        schema_hash: action.schema_hash,
        owner: effect.owner,
        scope: effect.scope
      }
    }
  end
end
