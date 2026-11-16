# Run with: mix run docs/examples/external_approval.exs
# Two real AgentServers; the UI and browser effect are deterministic fixtures.
defmodule ExternalApproval.Transport do
  @behaviour Spectre.Server.GAM.Managed.Approval

  def send_message(message, opts) do
    send(Keyword.fetch!(opts, :receiver), {:wire, message})
    {:ok, :queued}
  end
end

defmodule ExternalApproval.Effect do
  @behaviour Spectre.Server.GAM.EffectAdapter

  def execute_effect(:open, args, _) do
    send(Process.whereis(ExternalApproval.Consumer), {:opened, args})
    {:ok, %{simulated: true}}
  end
end

defmodule ExternalApproval.Package do
  use Spectre.Stack.Installable, id: :external_approval_example, version: "0.1.0"

  def effects(_) do
    %{
      browser_open: %{
        contract: 1,
        adapter: ExternalApproval.Effect,
        operation: :open,
        side_effect: :non_idempotent,
        material: :arguments,
        partition: [],
        schema_hash: nil,
        config: %{}
      }
    }
  end
end

defmodule ExternalApproval.AI do
  use Spectre.Stack
  install(ExternalApproval.Package)
end

defmodule ExternalApproval.Server do
  use Spectre.Server

  def handle_flow({:web, :open}, input, ctx),
    do: propose(ctx, :browser_open, %{"url" => input.text}, on_result: :opened)

  def handle_result(:opened, result, ctx) do
    send(Process.whereis(ExternalApproval.Consumer), {:completed, result})
    no_response(ctx)
  end

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)
end

defmodule ExternalApproval.Customer do
  use Spectre.Agent, stack: ExternalApproval.AI, server: ExternalApproval.Server

  flow :web do
    on(:open, regex: ~r/^https:\/\//)
  end
end

defmodule ExternalApproval.Owner do
  use Spectre.Agent, stack: ExternalApproval.AI, server: ExternalApproval.Server
end

defmodule ExternalApproval.Demo do
  alias Spectre.Server

  def run(choice) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    human = %{kind: :human, attributes: %{"subject" => "owner"}}
    authorization = "owner:customer-browser-consent"
    deadline = System.system_time(:millisecond) + 30_000
    transport = {ExternalApproval.Transport, [receiver: self()]}

    {:ok, customer} =
      Server.start_link(
        agent: ExternalApproval.Customer,
        consumer: self(),
        identity: %{subject: "customer"},
        gam: [
          operations: %{
            browser_open: [
              confirm: true,
              message: "Open a browser at this URL for the customer?",
              approver: {:external, "spectre://owner/assistant"}
            ]
          },
          approvals: [
            address: "spectre://customer/assistant",
            transport: transport,
            approvers: %{
              "spectre://owner/assistant" => [
                principal: human,
                public_key: public,
                mandate_ref: authorization,
                expires_at: deadline
              ]
            }
          ]
        ]
      )

    {:ok, owner} =
      Server.start_link(
        agent: ExternalApproval.Owner,
        consumer: self(),
        identity: %{subject: "owner"},
        gam: [
          approvals: [
            address: "spectre://owner/assistant",
            transport: transport,
            signer: [
              principal: human,
              private_key: private,
              mandate_ref: authorization,
              expires_at: deadline
            ]
          ]
        ]
      )

    try do
      {:ok, customer_view} = Server.gam_view(customer)
      {:ok, owner_view} = Server.gam_view(owner)
      true = customer_view.opening.domain_ref != owner_view.opening.domain_ref
      {:ok, _} = Server.input(customer, "https://example.test")
      request = wire("approval.request")
      :ok = Server.receive_approval(owner, request)

      receive do
        {Server, ^owner, {:approval_request, ^request}} ->
          IO.puts("Owner sees: " <> request["rendered_payload"])
      after
        5_000 -> raise "Owner did not receive the request"
      end

      no_effect!()
      # The test consumer simulates rendering and this explicit human choice.
      :ok = Server.approval_presented(owner, request["id"])
      :ok = Server.receive_approval(customer, wire("approval.presented"))

      receive do
        {Server, ^customer, {:pending, _, _}} -> :ok
      after
        5_000 -> raise "Customer did not acquire its consent wait"
      end

      no_effect!()
      :ok = Server.approval_decide(owner, request["id"], choice)
      decision = wire("approval.decision")
      {:ok, _} = Server.receive_approval(customer, decision)

      receive do
        {:completed, {:governed, %{outcome: %{status: :succeeded}}}} when choice == :confirm ->
          receive do
            {:opened, %{"url" => "https://example.test"}} -> :ok
          after
            5_000 -> raise "Approved effect did not execute"
          end

        {:completed, {:consent, :rejected}} when choice == :reject ->
          no_effect!()
      after
        5_000 -> raise "Decision did not complete"
      end

      {:error, _} = Server.receive_approval(customer, decision)
      no_effect!()
      IO.puts("#{choice}: passed; independent Domains, signed consent, replay rejected")
    after
      GenServer.stop(customer)
      GenServer.stop(owner)
    end
  end

  defp wire(type) do
    receive do
      {:wire, %{"type" => ^type} = message} -> message
    after
      5_000 -> raise "Missing protocol message: #{type}"
    end
  end

  defp no_effect! do
    receive do
      {:opened, _} -> raise "Unexpected or duplicate effect"
    after
      0 -> :ok
    end
  end
end

Process.register(self(), ExternalApproval.Consumer)
ExternalApproval.Demo.run(:confirm)
ExternalApproval.Demo.run(:reject)
