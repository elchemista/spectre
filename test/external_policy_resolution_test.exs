defmodule SpectreExternalPolicyResolutionTest.Actions do
  @moduledoc false

  def transfer(args, _ctx), do: {:ok, {:transferred, args}}
  def delete(args, _ctx), do: {:ok, {:deleted, args}}
  def status(args, _ctx), do: {:ok, {:status, args}}
end

defmodule SpectreExternalPolicyResolutionTest.Renderer do
  @moduledoc false

  def render(:approval_requested, _input, _ctx), do: "approval requested"
  def render(:approval_pending, _input, _ctx), do: "approval already pending"
  def render(:chat, input, _ctx), do: "chat:#{input.text}"
end

defmodule SpectreExternalPolicyResolutionTest.JournalStore do
  @moduledoc false
  @behaviour Spectre.Journal.Store

  @impl Spectre.Journal.Store
  def append(record, opts) do
    if pid = Keyword.get(opts, :pid), do: send(pid, {:external_policy_journal, record})
    :ok
  end
end

defmodule SpectreExternalPolicyResolutionTest.Agent do
  @moduledoc false

  use Spectre.Agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  actions SpectreExternalPolicyResolutionTest.Actions do
    protect(:transfer, with: :admin_approval, resolver: :external)
    protect(:delete, with: :admin_approval, resolver: :external)
  end

  approval_pending_reply(
    :approval_pending,
    renderer: {SpectreExternalPolicyResolutionTest.Renderer, :render}
  )

  policy :admin_approval do
    accept(:approved, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  flow :external_policy do
    on :TRANSFER, regex: ~r/^transfer$/i do
      action(:transfer,
        args: %{amount: 42},
        reply: :approval_requested,
        renderer: {SpectreExternalPolicyResolutionTest.Renderer, :render}
      )
    end

    on :DELETE, regex: ~r/^delete$/i do
      action(:delete,
        args: %{resource: "record"},
        reply: :approval_requested,
        renderer: {SpectreExternalPolicyResolutionTest.Renderer, :render}
      )
    end

    on :STATUS, regex: ~r/^status$/i do
      action(:status, args: %{scope: :current})
    end

    on :CHAT, regex: ~r/\S/u do
      reply(:chat, renderer: {SpectreExternalPolicyResolutionTest.Renderer, :render})
    end
  end
end

defmodule SpectreExternalPolicyResolutionTest do
  use ExUnit.Case, async: false

  alias Spectre.Awaitable
  alias Spectre.Context
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Instance
  alias Spectre.Policy
  alias Spectre.Policy.Resolution
  alias Spectre.Result
  alias Spectre.Run.Boundary
  alias Spectre.Runtime
  alias Spectre.State
  alias Spectre.State.Codec
  alias Spectre.Subject

  @agent SpectreExternalPolicyResolutionTest.Agent

  test "the DSL carries only explicit external resolver metadata" do
    protections = Spectre.Definition.protections(@agent)

    assert Enum.all?(protections, &(&1.resolver == :external))
    assert Enum.map(protections, & &1.policy) == [:admin_approval, :admin_approval]
  end

  test "State v5 round-trips external resolvers and defaults old payloads to conversation" do
    state = external_policy_state()

    assert {:ok, encoded} = Codec.encode(state)
    assert [encoded_awaitable] = encoded["awaitables"]
    assert encoded_awaitable["resolver"] == "external"

    assert {:ok, %State{awaitables: [%Awaitable{resolver: :external}]}} =
             Codec.decode(encoded)

    old_v5 = put_in(encoded, ["awaitables"], [Map.delete(encoded_awaitable, "resolver")])

    assert {:ok, %State{awaitables: [%Awaitable{resolver: :conversation}]}} =
             Codec.decode(old_v5)

    assert {:ok, conversation_encoded} = Codec.encode(Codec.decode!(old_v5))

    refute conversation_encoded
           |> Map.fetch!("awaitables")
           |> hd()
           |> Map.has_key?("resolver")

    invalid = put_in(encoded, ["awaitables", Access.at(0), "resolver"], "unknown")
    assert {:error, {:invalid_enum, "resolver", "unknown"}} = Codec.decode(invalid)

    invalid_state =
      put_in(
        state,
        [Access.key!(:awaitables), Access.at(0), Access.key!(:resolver)],
        :unknown
      )

    assert {:error, {:invalid_awaitable_resolver, :unknown}} = Codec.encode(invalid_state)
  end

  test "external policy guards reject malformed, foreign, and conversation resolutions" do
    state = external_policy_state()
    awaitable = State.open_policy_awaitable(state)
    input = Input.new("yes")
    ctx = %Context{agent: @agent, input: input, state: state}

    assert Policy.awaiting?(state)
    assert Policy.awaiting?(state, nil)
    refute Policy.captures_conversation?(state)

    conversation =
      put_in(
        state,
        [Access.key!(:awaitables), Access.at(0), Access.key!(:resolver)],
        :conversation
      )

    assert Policy.captures_conversation?(conversation)

    assert {:error, {:policy_resolution_source_not_allowed, id, :external, :conversation}} =
             Policy.resume(input, ctx)

    assert id == awaitable.id

    assert {:error, {:invalid_policy_resolution, ^id, :invalid}} =
             Policy.resolve(id, :invalid, input, ctx)

    wrong_kind =
      put_in(
        state,
        [Access.key!(:awaitables), Access.at(0), Access.key!(:kind)],
        :inference
      )

    assert {:error, {:policy_awaitable_kind_mismatch, ^id, :inference}} =
             Policy.resolve(id, {:accept, :approved}, input, %{ctx | state: wrong_kind})

    foreign =
      state
      |> put_in([Access.key!(:awaitables), Access.at(0), Access.key!(:run_id)], "owner-run")

    foreign_ctx = %{
      ctx
      | state: foreign,
        opts: [instance_run_lifecycle?: true, run_id: "foreign-run"]
    }

    assert {:error, {:policy_awaitable_not_owned, ^id, "foreign-run"}} =
             Policy.resolve(id, {:accept, :approved}, input, foreign_ctx)

    invalid_resolver =
      put_in(
        state,
        [Access.key!(:awaitables), Access.at(0), Access.key!(:resolver)],
        :unknown
      )

    assert {:error, {:invalid_policy_resolver, ^id, :unknown}} =
             Policy.resolve(
               id,
               {:accept, :approved},
               input,
               %{ctx | state: invalid_resolver}
             )
  end

  test "external policy lifecycle and Run fencing fail closed" do
    state = external_policy_state()
    awaitable = State.open_policy_awaitable(state)

    second =
      %{Effect.stage_action(%{name: :delete}, @agent, :agent) | run_id: "another-run"}

    assert {:error, {:approval_pending, id}} =
             Spectre.Lifecycle.stage(
               state,
               second,
               %{policy: :admin_approval, resolver: :external}
             )

    assert id == awaitable.id

    assert {:error, {:invalid_policy_resolver, :unknown}} =
             Spectre.Lifecycle.stage(
               %State{},
               Effect.stage_action(%{name: :transfer}, @agent, :agent),
               %{policy: :admin_approval, resolver: :unknown}
             )

    assert {:continue, started} = Runtime.start(@agent, "transfer")

    assert {:boundary, %Boundary{ref: policy_ref}, policy_run} = Runtime.advance(started)

    run_awaitable = State.open_policy_awaitable(policy_run.state)

    assert {:error, {:external_policy_requires_awaitable_id, run_id}, ^policy_run} =
             Runtime.resume(policy_run, {:policy, policy_ref, {:accept, :approved}})

    assert run_id == run_awaitable.id

    assert {:error, {:policy_awaitable_not_found, "missing"}, ^policy_run} =
             Runtime.resume(
               policy_run,
               {:policy, policy_ref, "missing", {:accept, :approved}}
             )

    assert {:error, {:unknown_policy_resolution_label, _policy, :accept, :unknown}, ^policy_run} =
             Runtime.resume(
               policy_run,
               {:policy, policy_ref, run_awaitable.id, {:accept, :unknown}}
             )

    assert {:error, {:invalid_policy_resolution, ^run_id, :invalid}, ^policy_run} =
             Runtime.resume(
               policy_run,
               {:policy, policy_ref, run_awaitable.id, :invalid}
             )

    wrong_kind_run = update_run_awaitable(policy_run, &%{&1 | kind: :inference})

    assert {:error, {:policy_awaitable_kind_mismatch, ^run_id, :inference}, ^wrong_kind_run} =
             Runtime.resume(
               wrong_kind_run,
               {:policy, policy_ref, run_awaitable.id, {:accept, :approved}}
             )

    closed_run = update_run_awaitable(policy_run, &%{&1 | status: :accepted})

    assert {:error, {:policy_awaitable_not_open, ^run_id, :accepted}, ^closed_run} =
             Runtime.resume(
               closed_run,
               {:policy, policy_ref, run_awaitable.id, {:accept, :approved}}
             )

    foreign_run = update_run_awaitable(policy_run, &%{&1 | run_id: "foreign-run"})

    assert {:error, {:policy_awaitable_not_owned, ^run_id, owned_run_id}, ^foreign_run} =
             Runtime.resume(
               foreign_run,
               {:policy, policy_ref, run_awaitable.id, {:accept, :approved}},
               instance_run_lifecycle?: true
             )

    assert owned_run_id == policy_run.id

    invalid_resolver_run = update_run_awaitable(policy_run, &%{&1 | resolver: :unknown})

    assert {:error, {:invalid_policy_resolver, ^run_id, :unknown}, ^invalid_resolver_run} =
             Runtime.resume(
               invalid_resolver_run,
               {:policy, policy_ref, run_awaitable.id, {:accept, :approved}}
             )

    no_policy_run = put_run_state(policy_run, %{policy_run.state | awaitables: []})

    assert {:error, :no_open_policy, ^no_policy_run} =
             Runtime.resume(no_policy_run, {:policy, policy_ref, {:accept, :approved}})

    assert {:await, _invocation, approved_run} =
             Runtime.resume(
               policy_run,
               {:policy, policy_ref, run_awaitable.id, {:accept, :approved}}
             )

    assert approved_run.revision == policy_run.revision + 1
  end

  test "policy lifecycle rejects orphaned and cross-Run gates without mutation" do
    state = external_policy_state()
    awaitable = State.open_policy_awaitable(state)
    effect = hd(state.pending_effects)

    mismatched = %{
      state
      | pending_effects: [%{effect | run_id: "effect-run"}],
        awaitables: [%{awaitable | run_id: "awaitable-run"}]
    }

    assert {:error, {:policy_lifecycle_run_mismatch, id, "awaitable-run"}} =
             Spectre.Lifecycle.resolve_policy(
               mismatched,
               awaitable.id,
               :accept,
               :approved
             )

    assert id == awaitable.id

    assert {:error, {:policy_lifecycle_run_mismatch, ^id, "awaitable-run"}} =
             Spectre.Lifecycle.resolve_policy(
               mismatched,
               awaitable.id,
               :reject,
               :rejected
             )

    orphaned = %{state | pending_effects: []}

    assert {:error, :pending_effect_not_found} =
             Policy.resolve(
               awaitable.id,
               {:accept, :approved},
               Input.new("host approval"),
               %Context{agent: @agent, state: orphaned}
             )

    assert {:error, {:invalid_policy_resolution, ^id, :maybe, :approved}} =
             Spectre.Lifecycle.resolve_policy(state, awaitable.id, :maybe, :approved)
  end

  test "an external gate does not capture Session turns and only a host can resolve its id" do
    session = start_session()

    assert {:ok, opened_turn} = Spectre.turn(session, "transfer")

    assert {:awaiting, %Awaitable{resolver: :external} = awaitable, _result} =
             opened_turn.decision

    assert opened_turn.result.reply_text == "approval requested"

    assert {:ok, chat_turn} = Spectre.turn(session, "yes")
    assert {:reply, %Result{reply_text: "chat:yes"}} = chat_turn.decision

    current = Spectre.state(session)

    assert %Awaitable{id: id, resolver: :external, attempts: 0, status: :open} =
             State.open_policy_awaitable(current)

    assert id == awaitable.id
    assert [%Effect{status: :waiting_policy}] = current.pending_effects

    before_user_resolution = current
    assert {:ok, user_resolution} = Resolution.new(:accept, :approved, :user)

    assert {:error, {:external_policy_requires_awaitable_id, ^id}} =
             Spectre.resolve_policy(session, opened_turn.result, {:accept, :approved})

    assert Spectre.state(session) == before_user_resolution

    assert {:error, {:policy_resolution_source_not_allowed, ^id, :external, :user}} =
             Spectre.resolve_policy(session, {:awaitable, id}, user_resolution)

    assert Spectre.state(session) == before_user_resolution

    assert {:error, {:policy_awaitable_not_found, "missing"}} =
             Spectre.resolve_policy(session, {:awaitable, "missing"}, {:accept, :approved})

    assert Spectre.state(session) == before_user_resolution

    journal =
      {SpectreExternalPolicyResolutionTest.JournalStore,
       [events: :all, mode: :sync, store_opts: [pid: self()]]}

    assert {:ok, approved} =
             Spectre.resolve_policy(
               session,
               {:awaitable, id},
               {:accept, :approved},
               journal: journal
             )

    assert approved.state.revision == before_user_resolution.revision + 1

    assert %Awaitable{status: :accepted, resolver: :external} =
             Enum.find(approved.state.awaitables, &(&1.id == id))

    assert Enum.any?(approved.events, fn event ->
             match?(
               %{type: :policy_resolved, source: :host, resolver: :external},
               event
             )
           end)

    assert_receive {:external_policy_journal,
                    %Spectre.Journal.Record{
                      phase: :policy,
                      policy: %{source: :host, resolver: :external}
                    }},
                   1_000

    after_approval = Spectre.state(session)

    assert {:error, {:policy_awaitable_not_open, ^id, :accepted}} =
             Spectre.resolve_policy(session, {:awaitable, id}, {:accept, :approved})

    assert Spectre.state(session) == after_approval

    assert {:ok, completed} = Spectre.execute(session, approved)
    assert completed.state.pending_effects == []
    assert Enum.any?(completed.effects, &match?(%Effect{status: :completed}, &1))
  end

  test "the addressed Agent API uses supplied current state and expiration is unchanged" do
    state = external_policy_state()
    awaitable = State.open_policy_awaitable(state)
    current = %{state | data: %{conversation_progress: 3}, revision: 7}

    assert {:ok, approved} =
             Spectre.resolve_policy(
               @agent,
               {:awaitable, awaitable.id},
               {:accept, :approved},
               state: current
             )

    assert approved.state.data == %{conversation_progress: 3}
    assert approved.state.revision == 8

    expiring = external_policy_state()
    expiring_awaitable = State.open_policy_awaitable(expiring)

    assert {:ok, transition} =
             Spectre.Lifecycle.expire_policy(expiring, expiring_awaitable.id)

    assert transition.to.pending_effects == []

    assert %Awaitable{status: :expired, resolver: :external, attempts: 0} =
             Enum.find(transition.to.awaitables, &(&1.id == expiring_awaitable.id))

    assert Enum.any?(transition.to.planned_effects, &match?(%Effect{status: :cancelled}, &1))
  end

  test "a second protected action is rejected with the configured reply and no second gate" do
    session = start_session()

    assert {:ok, opened} = Spectre.ask(session, "transfer")
    first = Result.open_awaitable(opened)

    assert {:ok, rejected} = Spectre.ask(session, "delete")
    assert rejected.reply_text == "approval already pending"

    assert rejected.metadata.policy_rejection == %{
             code: :approval_pending,
             awaitable_id: first.id
           }

    state = Spectre.state(session)
    assert [%Effect{name: :transfer, status: :waiting_policy}] = state.pending_effects
    assert [%Awaitable{id: id, attempts: 0, status: :open}] = state.awaitables
    assert id == first.id
  end

  test "an unprotected Session action gets the same approval-pending surface" do
    session = start_session()

    assert {:ok, opened} = Spectre.ask(session, "transfer")
    first = Result.open_awaitable(opened)
    before_rejection = Spectre.state(session)

    assert {:ok, rejected} = Spectre.ask(session, "status")
    assert rejected.reply_text == "approval already pending"

    assert rejected.metadata.policy_rejection == %{
             code: :approval_pending,
             awaitable_id: first.id
           }

    after_rejection = Spectre.state(session)
    assert after_rejection.pending_effects == before_rejection.pending_effects
    assert after_rejection.planned_effects == before_rejection.planned_effects
    assert after_rejection.awaitables == before_rejection.awaitables
    assert after_rejection.revision == before_rejection.revision + 1
  end

  test "approval-pending reply configuration remains optional and validated" do
    state = external_policy_state()
    awaitable = State.open_policy_awaitable(state)

    assert {:error, {:approval_pending, id}} =
             Spectre.ask(
               @agent,
               "delete",
               state: state,
               approval_pending_reply: nil
             )

    assert id == awaitable.id

    assert {:error, {:invalid_approval_pending_reply, :invalid}} =
             Spectre.ask(
               @agent,
               "delete",
               state: state,
               approval_pending_reply: :invalid
             )
  end

  test "an Instance keeps external approval pending while conversation Runs continue" do
    instance = start_instance()

    assert {:ok, opened_turn} = Spectre.turn(instance, "transfer")
    assert %{request: %{id: request_id}} = opened_turn.boundary
    assert opened_turn.boundary.request.metadata.resolver == :external

    assert %Awaitable{resolver: :external, attempts: 0} =
             Result.open_awaitable(opened_turn.result)

    assert {:ok, chat_turn} = Spectre.turn(instance, "yes")
    assert {:reply, %Result{reply_text: "chat:yes"}} = chat_turn.decision
    assert {:reply, "chat:yes", _ref} = chat_turn.observable

    assert {:ok, status_turn} = Spectre.turn(instance, "status")

    assert {:needs, %Effect{name: :status, status: :pending}, status_result} =
             status_turn.decision

    assert {:ok, status_completed} = Spectre.execute(instance, status_result)
    assert {:ok, {:status, %{scope: :current}}} = Result.action_outcome(status_completed)

    assert %Awaitable{attempts: 0, status: :open, resolver: :external} =
             State.open_policy_awaitable(Spectre.state(instance))

    assert_eventually_quiescent(instance)

    before_state = Spectre.state(instance)
    before_info = Instance.info(instance)
    assert {:ok, before_run} = Instance.run(instance, opened_turn.ref.run_id)
    assert {:ok, user_resolution} = Resolution.new(:accept, :approved, :user)

    assert {:error, {:policy_resolution_source_not_allowed, _id, :external, :user}} =
             Spectre.resolve_policy(
               instance,
               {:awaitable, request_id},
               user_resolution
             )

    assert Spectre.state(instance) == before_state
    assert Instance.info(instance).canonical_revision == before_info.canonical_revision
    assert Instance.run(instance, opened_turn.ref.run_id) == {:ok, before_run}

    assert {:ok, approved} =
             Spectre.resolve_policy(
               instance,
               {:awaitable, request_id},
               {:accept, :approved}
             )

    assert %Effect{status: :approved} = Result.pending_effect(approved)
    assert {:ok, completed} = Spectre.execute(instance, approved)
    assert completed.state.pending_effects == []
  end

  test "lifecycle command compatibility preserves typed policy outcomes" do
    refute Result.visible_reply?(%Result{reply_text: nil})

    assert {:error, :pending_effect_not_found} =
             Spectre.Lifecycle.apply(%State{}, {:approve_effect, "missing"})

    assert {:error, :no_open_policy} =
             Spectre.Lifecycle.apply(
               %State{},
               {:resolve_policy, "missing", :accept, :approved}
             )

    state = external_policy_state()
    awaitable = State.open_policy_awaitable(state)

    assert {:ok, transition} =
             Spectre.Lifecycle.apply(state, {:resolve_policy, :accept, :approved})

    assert transition.awaitable.id == awaitable.id
    assert transition.awaitable.status == :accepted

    addressed_state = external_policy_state()
    addressed = State.open_policy_awaitable(addressed_state)

    assert {:ok, addressed_transition} =
             Spectre.Lifecycle.apply(
               addressed_state,
               {:resolve_policy, addressed.id, :reject, :rejected}
             )

    assert addressed_transition.awaitable.status == :rejected

    invalid_effect =
      %{Effect.stage_action(%{name: :transfer}, @agent, :agent) | status: :completed}

    assert {:error, {:invalid_effect_transition, _id, :completed, :staged}} =
             Spectre.Lifecycle.stage(%State{}, invalid_effect)
  end

  defp external_policy_state do
    effect = Effect.stage_action(%{name: :transfer}, @agent, :agent)

    {:ok, transition} =
      Spectre.Lifecycle.stage(
        %State{},
        effect,
        %{policy: :admin_approval, resolver: :external}
      )

    transition.to
  end

  defp update_run_awaitable(run, callback) do
    state = %{run.state | awaitables: Enum.map(run.state.awaitables, callback)}
    put_run_state(run, state)
  end

  defp put_run_state(run, state), do: %{run | state: state, result: %{run.result | state: state}}

  defp start_session do
    start_supervised!(%{
      id: {:external_policy_session, System.unique_integer([:positive])},
      start: {Spectre.Session, :start_link, [[agent: @agent, state: %State{}, idle: false]]}
    })
  end

  defp start_instance do
    subject = Subject.new("external-policy-#{System.unique_integer([:positive])}")

    start_supervised!(%{
      id: {:external_policy_instance, System.unique_integer([:positive])},
      start:
        {Instance, :start_link,
         [[agent: @agent, subject: subject, checkpoint_mode: :manual, idle: false]]}
    })
  end

  defp assert_eventually_quiescent(instance, attempts \\ 100)

  defp assert_eventually_quiescent(instance, attempts) when attempts > 0 do
    info = Instance.info(instance)

    if is_nil(info.active_run) and info.ready == [] do
      :ok
    else
      Process.sleep(5)
      assert_eventually_quiescent(instance, attempts - 1)
    end
  end

  defp assert_eventually_quiescent(instance, 0) do
    flunk("Instance did not quiesce: #{inspect(Instance.info(instance))}")
  end
end
