defmodule Spectre.Agent.Learning do
  @moduledoc false

  alias Spectre.Agent.Wiring
  alias Spectre.Router.SemanticCache

  # Learning is an explicitly enabled, disposable host write after a confirmed
  # result. It never approves an example, alters admission or retries an effect.
  # Keep this policy separate from Router nomination and GAM Outcome semantics.
  @doc false
  def observe(runtime, owner, request, result) do
    with false <- runtime.learned?,
         %{status: :done} <- result,
         {operation, _} when operation in [:request, :ask] <- request.operation,
         %{routing: %{name: flow, declaration: declaration}, selection: selection}
         when not is_nil(selection) <- runtime.current,
         false <- selection.via == "semantic_cache",
         %{cache: name} <- declaration.binding,
         %{learn: :review} <- owner.plan.settings["semantic_cache/" <> to_string(name)],
         route when not is_nil(route) <- declaration.routes[selection.candidate],
         true <- route.rule["match"]["semantic_cache"] === true,
         {:ok, example} <- example(runtime.routing_input, request.ref, selection.rule) do
      reply =
        with {:ok, cache} <-
               Wiring.cache(name, owner.definition_ref, flow, runtime.wiring, owner.prefix),
             {:ok, %{id: id, revision: revision}}
             when id === request.ref and is_integer(revision) and revision > 0 <-
               SemanticCache.put(cache, example) do
          {:quarantined, id, revision}
        else
          {:ok, _invalid} -> {:error, :invalid_cache_put_receipt}
          {:error, _} = error -> error
        end

      # Even failed storage is not implicitly retried on later handler steps.
      # The host may repair by this request ID without re-executing the Act.
      {reply, %{runtime | learned?: true}}
    else
      _not_eligible -> {:not_requested, runtime}
    end
  end

  defp example(text, id, label) when is_binary(text),
    do: {:ok, %{id: id, text: text, label: label}}

  defp example(%{"text" => text} = input, id, label) when is_binary(text),
    do:
      {:ok,
       %{
         id: id,
         text: text,
         label: label,
         embedding: Map.get(input, "embedding"),
         profile_ref: Map.get(input, "profile_ref")
       }}

  defp example(_input, _id, _label), do: :not_text
end
