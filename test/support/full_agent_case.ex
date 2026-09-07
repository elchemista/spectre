defmodule Spectre.Test.FullAgentCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  # Shared host wiring and assertions, not shared mutable Domain state. Each
  # test still bootstraps its own authority, Scope and supervised Instance.
  using do
    quote do
      import Spectre.Test.FullAgentCase,
        only: [
          turn: 2,
          turn: 3,
          input: 2,
          mind_options: 2,
          projection: 1,
          balance: 1,
          assert_success: 2,
          assert_replay: 1
        ]
    end
  end

  alias Spectre.{Agent, Audit, Definition, Instance, Ledger, Portable}
  alias Spectre.Attempt.Executor, as: ExecutorAPI
  alias Spectre.Domain.{Projection, Sequencer}
  alias Spectre.Mind.Turn
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule PaymentSkill do
    @moduledoc false

    use Spectre.Skill, namespace: "full-agent", name: "payment", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule ManualSkill do
    @moduledoc false

    use Spectre.Skill, namespace: "full-agent", name: "manual", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule PlainAgent do
    @moduledoc false

    use Spectre.Agent, namespace: "full-agent", name: "plain", revision: 1, declared_at: 0
    candidate("refund", class: "refund.issue", row: %{attempt: true, disclose: true, spend: true})
  end

  defmodule SkilledAgent do
    @moduledoc false

    use Spectre.Agent, namespace: "full-agent", name: "skilled", revision: 1, declared_at: 0
    install(PaymentSkill, as: "payment")
  end

  defmodule MultiSkillAgent do
    @moduledoc false

    use Spectre.Agent, namespace: "full-agent", name: "multi", revision: 1, declared_at: 0
    install(PaymentSkill, as: "payment")
    install(ManualSkill, as: "manual")
  end

  # Application routing stays outside the kernel. The same Mind can use a
  # portable declaration built directly or composed from Skills.
  defmodule Deliberation do
    @moduledoc false

    def run(turn, opts) do
      send(Keyword.fetch!(opts, :observer), {:deliberation, self(), turn, opts})

      case Keyword.get(opts, :behavior, :normal) do
        :raise -> raise "private-mind-diagnostic"
        :throw -> throw(:private_mind_diagnostic)
        :exit -> exit(:private_mind_diagnostic)
        :error -> {:error, :application_declined}
        :malformed -> {:ok, :not_a_candidate}
        :normal -> route(turn, opts)
      end
    end

    defp route(turn, opts) do
      input = Enum.max_by(turn.evidence, &{&1.observed_at, &1.ref})

      case input.payload["command"] do
        "refund" -> propose(turn, Keyword.fetch!(opts, :template), opts)
        "manual" -> propose(turn, "manual/refund", opts)
        _unknown -> {:ok, []}
      end
    end

    defp propose(turn, template, opts) do
      attrs = Keyword.fetch!(opts, :candidate_attrs)
      disclosure = Map.put(attrs.disclosure, :source_evidence_refs, Turn.evidence_refs(turn))
      attrs = Map.put(attrs, :disclosure, disclosure)
      Agent.candidate(Keyword.fetch!(opts, :definition), template, turn, attrs)
    end
  end

  defmodule StatelessMind do
    @moduledoc false

    use Spectre.Mind, ref: "mind:full-agent:stateless"
    @impl true
    defdelegate deliberate(turn, opts), to: Deliberation, as: :run
  end

  defmodule StatefulMind do
    @moduledoc false

    @behaviour Spectre.Mind
    @impl true
    def ref, do: "mind:full-agent:stateful"
    @impl true
    defdelegate deliberate(turn, opts), to: Deliberation, as: :run
    @impl true
    def deliberate(turn, state, opts) do
      with {:ok, proposals} <- Deliberation.run(turn, opts), do: {:ok, proposals, state + 1}
    end
  end

  defmodule RecordingExecutor do
    @moduledoc false

    @behaviour Spectre.Attempt.Executor
    @impl true
    defdelegate executor_ref(), to: Spectre.V04Test.Executor
    @impl true
    defdelegate contract_ref(), to: Spectre.V04Test.Executor

    @impl true
    def execute(act, attempt, capability, opts) do
      projection = Sequencer.projection(Keyword.fetch!(opts, :domain))

      send(
        Keyword.fetch!(opts, :observer),
        {:execution,
         %{
           act: act,
           attempt: attempt,
           capability: capability,
           attempt_durable: projection.attempts[attempt.ref] == attempt,
           pending: MapSet.member?(projection.pending_dispatches, act.ref)
         }}
      )

      case Keyword.fetch!(opts, :behavior) do
        :raise -> raise "private-executor-diagnostic"
        :malformed -> {:ok, %{raw_provider_response: capability}}
        status -> outcome(act, attempt, status)
      end
    end

    defp outcome(act, attempt, status) do
      {:ok, evidence} =
        ExecutorAPI.outcome_evidence(act, attempt, status, Runtime.now(), payload: "receipt")

      metadata = %{evidence: [evidence], details_ref: "receipt:full-agent"}
      if status == :succeeded, do: {:ok, metadata}, else: {:error, status, metadata}
    end
  end

  defmodule Payloads do
    @moduledoc false

    @behaviour Spectre.Payload.Store

    @impl true
    def verify(ref, opts) do
      case :ets.lookup(Keyword.fetch!(opts, :table), ref) do
        [] ->
          {:error, :not_found}

        [{^ref, value}] ->
          if Portable.content_ref!(:payload, value) == ref,
            do: :ok,
            else: {:error, :digest_mismatch}
      end
    end
  end

  setup tags do
    Runtime.reset(Fixture.default_now())
    authoring = Map.get(tags, :authoring, SkilledAgent)
    definition = authoring.definition()
    template = definition.body["candidates"] |> Map.values() |> hd()
    body = Map.put(definition.body, "candidates", %{"updated/refund" => template})
    {:ok, successor} = Definition.revise(definition, body, Runtime.now())
    mind = Map.get(tags, :mind, StatefulMind)
    namespace = "full-agent-#{System.unique_integer([:positive])}"
    ref = "v0.4:#{namespace}:domain"
    name = {:via, Registry, {Spectre.Domain.Registry, ref}}
    capability = {:host_payment_session, make_ref()}
    payload_table = :ets.new(__MODULE__, [:set, :public])
    payload_store = if tags[:external_payloads], do: {Payloads, table: payload_table}

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: name,
        mind: mind,
        consent: Map.get(tags, :consent, false),
        payload_store: payload_store,
        governance_allowed: true,
        emergency_mandate: Map.get(tags, :emergency_mandate, false),
        constitution_overrides: Map.get(tags, :constitution_overrides, %{}),
        duty_rules: Map.get(tags, :duty_rules, %{}),
        revocation_mode: Map.get(tags, :revocation_mode, :cascade),
        governance_classes: ["definition.revise"],
        governance_targets: [definition.ref, successor.ref],
        capability: capability,
        executors: [
          {RecordingExecutor,
           domain: name, observer: self(), behavior: Map.get(tags, :executor, :succeeded)}
        ]
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    assert {:ok, domain} = Spectre.lookup_domain(ref)
    assert {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))

    assert {:ok, admin} =
             Spectre.resume_scope(
               domain,
               Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
             )

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             Spectre.revise_definition(admin, definition,
               identity_key: "publish-definition",
               requested_mandate_ref: fixture.governance_mandate.ref,
               accountable_ref: fixture.refs.accountable,
               purpose_ref: fixture.refs.purpose,
               purpose_params: %{"currency" => "EUR"}
             )

    instance =
      start_supervised!({Instance, scope: scope, definition_ref: definition.ref, state: 0})

    %{
      fixture: fixture,
      admin: admin,
      scope: scope,
      instance: instance,
      definition: definition,
      successor: successor,
      capability: capability,
      payload_table: payload_table,
      template: if(authoring == PlainAgent, do: "refund", else: "payment/refund")
    }
  end

  def turn(c, command, opts \\ []),
    do:
      Instance.turn(c.instance, input(c, command),
        mind_opts: mind_options(c, opts),
        context_evidence_refs: Keyword.get(opts, :context, [])
      )

  def input(c, command) do
    c.fixture
    |> Fixture.paid_evidence(payload: %{"command" => command})
    |> Map.from_struct()
    |> Map.delete(:ref)
  end

  def mind_options(c, opts) do
    attrs =
      c.fixture
      |> Fixture.refund_candidate(Keyword.get(opts, :amount, 100),
        identity_key: Keyword.get(opts, :identity, "full-agent:refund")
      )
      |> Map.drop([:class, :row, :proposer_ref, :scope_ref, :evidence_refs])
      |> Map.put(:requested_mandate_ref, Keyword.get(opts, :mandate, c.fixture.mandate.ref))

    [
      definition: c.definition,
      template: c.template,
      candidate_attrs: attrs,
      observer: self(),
      behavior: Keyword.get(opts, :behavior, :normal)
    ]
  end

  def projection(c), do: Sequencer.projection(c.fixture.server)
  def balance(c), do: projection(c).meters[c.fixture.mandate.ref][c.fixture.refs.meter]

  def assert_success(c, result) do
    assert result.primary.decision.outcome == :admitted
    assert result.primary.outcome.status == :succeeded

    assert_receive {:execution,
                    %{
                      act: act,
                      attempt: attempt,
                      capability: capability,
                      attempt_durable: true,
                      pending: false
                    }}

    assert act == result.primary.act
    assert attempt == result.primary.attempt
    assert capability == c.capability
    refute inspect(result) =~ inspect(capability)
    assert_replay(c)
  end

  def assert_replay(c) do
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, recovered} = Projection.replay(snapshot, c.fixture.constitution)
    assert recovered == projection(c)
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, Runtime.now())
  end
end
