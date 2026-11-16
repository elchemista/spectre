defmodule Spectre.Server.Services do
  @moduledoc """
  Compatibility services for the 0.3 Stack, used in Server workers.

  Generations prepare provider-neutral plans and never execute their actions.
  The Server submits consolidated proposals to its configured GAM bridge.
  Applications may replace either callback through the `:services` bindings.
  """
  alias Spectre.Inference
  alias Spectre.Inference.Request

  def generate(request, context, opts) do
    ctx = Spectre.Server.ServiceContext.legacy(context, request.input, opts, request.assigns)

    with {:ok, plan} <- Spectre.Prompt.build(ctx.agent, request.prompt, ctx, ctx.opts),
         inference <- Request.for_response(plan, ctx, ctx.opts),
         {:ok, response} <- complete(request, inference, ctx, context),
         {:ok, generated} <- consolidate(response.text, request.planning, ctx) do
      {:generated, Map.put(generated, :inference, response)}
    end
  end

  def classify(request, context, opts) do
    ctx = Spectre.Server.ServiceContext.legacy(context, request.input, opts, %{})
    choices = request.choices || []
    pending_context = classification_context(request.context)
    assigns = Keyword.get(ctx.opts, :classifier_assigns, %{}) |> Map.new()

    opts =
      ctx.opts
      |> Keyword.put(:spectre_agent, context.agent)
      |> Keyword.put(:pending_context, pending_context)
      |> Keyword.put(:classifier_assigns, Map.put(assigns, :pending_context, pending_context))

    case Spectre.Router.LLMClassifier.classify(ctx.input.text, choices, opts) do
      {:ok, route} -> {:classified, route.label}
      {:error, _} = error -> error
      other -> {:error, {:invalid_classifier_result, other}}
    end
  end

  defp classification_context(%{presentation: %Spectre.GAM.Presentation{} = presentation}) do
    # Public material only. Candidate, authority handles, input envelopes and
    # executor data must not leak into a classifier prompt through `inspect`.
    Spectre.JSON.encode!(%{
      material: Spectre.GAM.Presentation.material(presentation),
      rendered_payload: presentation.rendered_payload
    })
  end

  defp classification_context(text) when is_binary(text), do: text
  defp classification_context(_), do: nil

  def respond(content, context, opts) when is_atom(content) do
    ctx = Spectre.Server.ServiceContext.legacy(context, context.input, opts, %{})

    case Spectre.Runner.reply(content, ctx.input, ctx, ctx.opts) do
      {:ok, result} -> {:rendered, result.reply_text}
      {:error, _} = error -> error
    end
  end

  defp complete(%{stream: false}, request, ctx, _context),
    do: Inference.complete(ctx.agent, request, ctx)

  defp complete(request, inference, ctx, context) do
    # Selection and immutable descriptor reuse the existing cognitive boundary;
    # the new stream worker owns transport rather than creating an Instance.
    with {:ok, prepared} <- Inference.prepare(ctx.agent, inference, ctx) do
      Spectre.Server.Stream.run(prepared, request, context, ctx.opts)
    end
  end

  defp consolidate(text, false, ctx) do
    {:ok,
     %{
       text:
         Spectre.ActionPlanner.clean_reply(text, ctx, Spectre.Server.Catalog.planner_options(ctx)),
       proposals: [],
       planning: false,
       model_output: text
     }}
  end

  defp consolidate(text, true, ctx) do
    with {:ok, result} <- Spectre.Server.Planning.prepare_context(text, ctx) do
      {:ok, %{text: result.text, proposals: result.actions, planning: true}}
    end
  end
end
