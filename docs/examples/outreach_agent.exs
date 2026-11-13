# Application sketch, not a standalone script. See docs/GETTING_STARTED.md
# for host-owned model, action catalog, browser and GAM configuration.
defmodule MyApp.OutreachAI do
  use Spectre.Stack

  install Spectre.Lens do
    backend(SpectreLens.Browsers.Lightpanda, instances: 1)
  end

  # MailActions declares SEND EMAIL and its typed arguments; planning does not send.
  install(Spectre.Kinetic,
    mode: :closed_moves,
    actions: MyApp.MailActions,
    modes: [send_email: :write]
  )
end

defmodule MyApp.OutreachServer do
  use Spectre.Server, tools: MyApp.OutreachAI, prompt_root: "priv/outreach/prompts"

  def init(_arg, ctx) do
    # Preserve restored work/history; initialize only missing values.
    {:ok,
     ctx
     |> assign(:job, ctx.assigns[:job])
     |> assign(:history, Map.get(ctx.assigns, :history, []))}
  end

  def handle_flow({:outreach, :new_link}, input, ctx) do
    # One active job: another link cannot replace an email awaiting approval.
    if ctx.assigns.job do
      respond(ctx, "A job is already open. Ask for status or finish its confirmation.")
    else
      ctx
      |> assign(:job, %{url: input.text, status: :reading})
      |> lens({:open, input.text}, on_result: :opened)
    end
  end

  def handle_flow({:outreach, :status}, _input, ctx) do
    status = if ctx.assigns.job, do: ctx.assigns.job.status, else: :idle
    respond(ctx, "Job status: #{status}")
  end

  def handle_flow({:outreach, :info}, _input, ctx),
    do:
      respond(
        ctx,
        "Send a URL. I find its contact email, draft a message and ask before sending."
      )

  def handle_flow({:outreach, :history}, _input, ctx) do
    lines = Enum.map_join(ctx.assigns.history, "\n", &"#{&1.url}: #{&1.status}")
    respond(ctx, if(lines == "", do: "No completed jobs yet.", else: lines))
  end

  def handle_flow(:unmatched, _input, ctx),
    do: respond(ctx, "Send a URL, or ask for status, info or history.")

  def handle_result(:opened, {:ok, tab}, ctx),
    do: ctx |> assign(:tab, tab) |> lens({:look, tab}, on_result: :looked)

  # Close the known tab even if reading failed, before moving to the model.
  def handle_result(:looked, result, ctx),
    do: ctx |> assign(:page_result, result) |> lens({:close, ctx.assigns.tab}, on_result: :closed)

  def handle_result(:closed, {:ok, _}, ctx) do
    with {:ok, view} <- ctx.assigns.page_result,
         # Application parser: returns {:ok, email} only for an address in the page.
         {:ok, email} <- MyApp.Contacts.email_from(view) do
      ctx
      |> assign(:job, Map.merge(ctx.assigns.job, %{email: email, status: :drafting}))
      |> generate(:contact,
        assigns: %{page: view.context, email: email},
        planning: false,
        on_result: :drafted
      )
    else
      :not_found -> finish(ctx, :no_email, "No contact email found on this page.")
      {:error, _} -> finish(ctx, :read_failed, "Could not inspect the contact page.")
    end
  end

  # The model generates AL; Kinetic interprets the consolidated response.
  def handle_result(:drafted, {:generated, response}, ctx),
    do: kinetic(ctx, response, on_result: :prepared)

  def handle_result(
        :prepared,
        {:prepared, %{actions: [%{operation: {:kinetic, :send_email}} = p]}},
        ctx
      ) do
    ctx
    |> assign(:job, %{ctx.assigns.job | status: :awaiting_confirmation})
    # GAM's host binding below presents the exact recipient and body for consent.
    |> propose(p.operation, p.args, proposal_metadata: p.metadata, on_result: :sent)
  end

  def handle_result(:prepared, {:prepared, _}, ctx),
    do: finish(ctx, :invalid_draft, "Expected exactly one email proposal; nothing was sent.")

  def handle_result(:sent, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: finish(ctx, :sent, "The mail service confirmed the send operation.")

  def handle_result(:sent, {:governed, %{decision: %{outcome: :refused}}}, ctx),
    do: finish(ctx, :refused, "The email operation was not permitted.")

  def handle_result(:sent, {:consent, status}, ctx)
      when status in [:rejected, :expired, :closed_by_policy],
      do: finish(ctx, status, "The email was not sent.")

  # Uncertain results keep the job open for host reconciliation; no blind retry.
  def handle_result(_tag, result, ctx)
      when elem(result, 0) in [:governed_unknown, :tool_unknown, :governed, :error] do
    ctx
    |> assign(:job, %{ctx.assigns.job | status: :verification_required})
    |> respond("The operation needs verification before another job can start.")
  end

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)

  def handle_pending(%{kind: :consent} = pending, input, ctx) do
    case String.downcase(String.trim(input.text)) do
      "confirm" -> confirm_pending(ctx, pending.id)
      "cancel" -> reject_pending(ctx, pending.id)
      # Informational flows may run without replacing the pending email.
      word when word in ["status", "info", "history"] -> route_current_input(ctx)
      _ -> explain_pending(ctx, pending.id)
    end
  end

  def handle_pending(pending, input, ctx), do: super(pending, input, ctx)

  defp finish(ctx, status, message) do
    entry = %{url: ctx.assigns.job.url, status: status}

    ctx
    |> assign(:history, Enum.take([entry | ctx.assigns.history], 20))
    |> assign(:job, nil)
    |> respond(message)
  end
end

defmodule MyApp.OutreachAgent do
  use Spectre.Agent, stack: MyApp.OutreachAI, server: MyApp.OutreachServer
  model(MyApp.TextModel)
  router(strategies: [:regex])

  flow :outreach do
    on(:new_link, regex: ~r/^https?:\/\/\S+$/i, collect_intent: false)
    on(:status, regex: ~r/^status$/i)
    on(:info, regex: ~r/^info$/i)
    on(:history, regex: ~r/^history$/i)
  end
end
