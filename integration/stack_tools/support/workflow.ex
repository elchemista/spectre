defmodule Outreach.AI do
  use Spectre.Stack

  install(Spectre.Kinetic,
    mode: :closed_moves,
    actions: Outreach.Actions,
    modes: [send_email: :write]
  )

  install Spectre.Mnemonic, automatic: false, bind: [remember: :save_report] do
    isolate_by([:agent, :subject])
  end

  install Spectre.Lens do
    backend(Outreach.FakeBrowser, instances: 1)
    # Only this deterministic fake backend: no DNS or network access occurs.
    policy(SpectreLens.URLPolicy, network_policy: :any)
  end

  install Spectre.Prism do
    provider(:test, Outreach.FakeModel)
    model(:fast, id: "deterministic-test-model")
    default(:fast)
  end

  install Spectre.Beam, bind: [deliver: :send_notice] do
    channel(:email, adapter: Outreach.FakeChannel)
  end

  install(Spectre.Directive)
  install(Spectre.Pulse)
  install(Spectre.Ledger)
  install(Spectre.Lab)
end

defmodule Outreach.Server do
  use Spectre.Server, tools: Outreach.AI, prompt_root: Path.expand("../prompts", __DIR__)

  # Test-only fault injection: production callbacks should not block the owner.
  def init({:pause_model, observer}, ctx),
    do: {:ok, ctx |> put_private(:observer, observer) |> put_private(:pause_model, true)}

  def init(observer, ctx), do: {:ok, put_private(ctx, :observer, observer)}

  def handle_flow({:outreach, :start}, _input, ctx) do
    directive(ctx, {:new, %{mission: "Inspect site and contact Luca", reasoner: :model}},
      on_result: :directive
    )
  end

  def handle_flow({:outreach, :status}, _input, ctx),
    do: respond(ctx, "Report is awaiting permission.")

  def handle_flow({:outreach, :resume}, _input, ctx) do
    pending =
      Enum.find_value(ctx.pending_by_id, fn {_id, p} ->
        if p[:operation] == :save_report, do: p
      end)

    if pending, do: resume_pending(ctx, pending.id), else: respond(ctx, "Nothing pending.")
  end

  def handle_flow(route, input, ctx), do: super(route, input, ctx)

  # Business restrictions can narrow configured authority. They cannot bypass
  # GAM admission, grant consumption, confirmation or outcome recording.
  def handle_action(%{operation: operation, args: args} = action, ctx)
      when operation in [{:kinetic, :send_email}, {{:skill, :outreach}, :kinetic, :send_email}] do
    if args["to"] == "dev@example.com",
      do: super(action, ctx),
      else: {:reject, :recipient_not_allowed}
  end

  def handle_action(action, ctx), do: super(action, ctx)

  def handle_pending(pending, %Spectre.Input{text: text}, ctx) do
    case text do
      "yes" ->
        confirm_pending(ctx, pending.id)

      "no" ->
        reject_pending(ctx, pending.id)

      "status" ->
        ctx
        |> close_pending_after(pending.id, 120_000, reason: :topic_changed)
        |> route_current_input(suspend: pending.id)

      _ ->
        explain_pending(ctx, pending.id)
    end
  end

  def handle_result(tag, result, ctx) do
    send(ctx.private.observer, {:outreach_result, tag, result})

    if tag == :model and ctx.private[:pause_model] do
      send(ctx.private.observer, {:model_callback_waiting, self()})

      receive do
        :continue_model -> :ok
      end
    end

    next(tag, result, ctx)
  end

  defp next(:directive, {:directive, _}, ctx),
    do: prism(ctx, %{purpose: :response_generation}, on_result: :prism)

  defp next(:prism, {:selected, _}, ctx),
    do: mnemonic(ctx, {:recall, "Luca Shopify"}, on_result: :recall)

  defp next(:recall, {:ok, memories}, ctx),
    do:
      ctx
      |> assign(:memories, memories)
      |> lens({:open, "https://shop.example.test"}, on_result: :opened)

  defp next(:opened, {:ok, tab}, ctx),
    do: ctx |> assign(:tab, tab) |> lens({:look, tab}, on_result: :looked)

  defp next(:looked, {:ok, view}, ctx),
    do: ctx |> assign(:page, view) |> lens({:close, ctx.assigns.tab}, on_result: :closed)

  defp next(:closed, {:ok, _}, ctx),
    do:
      generate(ctx, :contact,
        assigns: %{page: ctx.assigns.page, memories: ctx.assigns.memories},
        on_result: :model
      )

  defp next(:model, {:generated, response}, ctx), do: kinetic(ctx, response, on_result: :kinetic)

  defp next(:kinetic, {:prepared, %{actions: [proposal]}}, ctx) do
    propose(ctx, proposal.operation, proposal.args,
      proposal_metadata: proposal.metadata,
      on_result: :email
    )
  end

  defp next(:email, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: beam(ctx, {:endpoints}, on_result: :beam)

  defp next(:beam, {:ok, _}, ctx) do
    beam(
      ctx,
      {:deliver, :email,
       %{to: "owner@example.com", content: %{type: :text, text: "One email accepted"}}},
      on_result: :notice
    )
  end

  defp next(:notice, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: pulse(ctx, {:protocol}, on_result: :pulse)

  defp next(:pulse, {:ok, _}, ctx), do: ledger(ctx, {:head}, on_result: :ledger)

  defp next(:ledger, {:ok, %{revision: _}}, ctx),
    do: lab(ctx, {:inspect, :checkpoint}, on_result: :lab)

  defp next(:lab, {:ok, _}, ctx),
    do:
      mnemonic(ctx, {:remember, "Luca was contacted about his Shopify site."}, on_result: :saved)

  defp next(:saved, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
    do: mnemonic(ctx, {:recall, "Luca Shopify"}, on_result: :recalled_after_save)

  defp next(:saved, {:consent, status}, ctx)
       when status in [:rejected, :expired, :closed_by_policy],
       do: respond(ctx, "Report not saved.")

  defp next(:recalled_after_save, {:ok, _}, ctx),
    do: respond(ctx, "Report saved after confirmation.")

  defp next(_tag, _result, ctx), do: respond(ctx, "Workflow stopped for inspection.")
end

defmodule Outreach.Agent do
  use Spectre.Agent, stack: Outreach.AI, server: Outreach.Server

  flow :outreach do
    on(:start, regex: ~r/^start$/)
    on(:status, regex: ~r/^status$/)
    on(:resume, regex: ~r/^resume$/)
  end
end
