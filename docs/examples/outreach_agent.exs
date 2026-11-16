# Application sketch, not a standalone script. See docs/GETTING_STARTED.md
# for host-owned model, action catalog, browser and GAM configuration.
# 1. Stack: install capabilities shared by recognition and execution.
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

# 2. Agent: the readable map of user intentions, before their implementation.
defmodule MyApp.OutreachAgent do
  use Spectre.Agent, stack: MyApp.OutreachAI, server: MyApp.OutreachServer

  # Writes the email draft.
  model(MyApp.TextModel)
  # Recognizes intent; may be another model.
  classifier(:llm, MyApp.IntentModel)
  # Encodes text for semantic similarity.
  embedding(MyApp.Embeddings)

  # :intent_dataset below uses the built-in example store by default.
  # Bind intent_dataset(MyApp.Dataset, ...) only for a custom store adapter.

  # Regex recognizes explicit commands; the dataset reuses reviewed examples;
  # embeddings compare meaning; the intent model handles less explicit wording.
  # Arbitration chooses a declared route; not every provider runs on every input.
  router(strategies: [:regex, :intent_dataset, :embedding, :llm_classifier])

  # Every match below dispatches to handle_flow({:outreach, intent}, input, ctx).
  # Collect eligible informational examples for review/training, not model replies.
  flow :outreach, defaults: [collect_intent: true] do
    # A URL starts page inspection -> contact extraction -> draft -> GAM consent.
    # Restrict this route to URL input; Lens validates the destination.
    # Classifiers must not turn arbitrary text into a browser destination.
    # Do not collect URLs as intent-training examples.
    on(:new_link,
      regex: ~r/^https?:\/\/\S+$/i,
      match_with: [:regex],
      dataset_lookup: false,
      collect_intent: false
    )

    # "status" matches directly; these examples also recognize natural questions.
    # -> handle_flow({:outreach, :status}, ...): report the current job's progress.
    on(:status,
      regex: ~r/^status$/i,
      semantic_examples: ["How is the work going?", "Are you waiting for my confirmation?"]
    )

    # Explain what the agent can do, without opening a page or proposing an email.
    # -> handle_flow({:outreach, :info}, ...).
    on(:info,
      regex: ~r/^(info|help)$/i,
      semantic_examples: ["What can you do?", "How does contacting a website work?"]
    )

    # Show previous job summaries, not the current job or the full GAM audit log.
    # -> handle_flow({:outreach, :history}, ...).
    on(:history,
      regex: ~r/^history$/i,
      semantic_examples: ["Show previous jobs", "Which websites have you already processed?"]
    )
  end
end

# 3. Server: implement the declared intentions and continue asynchronous results.
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

  # No accepted route (including ambiguous recognition): clarify, never invent one.
  def handle_flow(:unmatched, _input, ctx) do
    case ctx.pending do
      %{kind: :consent, id: id} -> explain_pending(ctx, id)
      _ -> respond(ctx, "Send a URL, or ask about progress, capabilities or previous jobs.")
    end
  end

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
      # Let the same router recognize natural questions such as "How is it going?".
      # The pending email stays open: routing an information request is not consent.
      # Unmatched input reaches handle_flow(:unmatched, ...) and re-explains it.
      _ -> route_current_input(ctx)
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
