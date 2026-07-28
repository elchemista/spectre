defmodule Spectre.Inference.Selector.Default do
  @moduledoc """
  Compatibility selector for Agents without a cognitive-routing extension.
  """

  @behaviour Spectre.Inference.Selector

  alias Spectre.Inference.Selection

  @impl true
  def select(request, _profiles, _ctx, _opts) do
    model = Map.get(request.metadata, :model)

    if is_nil(model) do
      {:error, :missing_llm_adapter}
    else
      {:ok,
       Selection.new(%{
         request_id: request.id,
         level: :default,
         model: model,
         reason:
           if(Map.get(request.metadata, :explicit_model_override?),
             do: :explicit_model_override,
             else: :agent_default
           ),
         selector: __MODULE__,
         profile_hash: model_hash(model),
         fallback_chain: List.wrap(Map.get(request.metadata, :fallback)),
         attempt: request.attempt
       })}
    end
  end

  @spec model_hash(term()) :: String.t()
  defp model_hash(model) do
    safe_model =
      case model do
        {module, function, opts} when is_list(opts) ->
          {module, function, Keyword.drop(opts, [:api_key, :token, :secret, :credentials])}

        other ->
          other
      end

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(safe_model, [:deterministic]))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end
end
