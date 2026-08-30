defmodule SpectreStableReleaseRegressionTest.Guards do
  @moduledoc false

  def suppress(_action, _ctx), do: {:suppress, "blocked by provider guard"}
end

defmodule SpectreStableReleaseRegressionTest.GuardedAgent do
  @moduledoc false

  use Spectre.Agent

  before_action({:lens, :navigate},
    run: {SpectreStableReleaseRegressionTest.Guards, :suppress}
  )

  protect({:lens, :navigate}, with: :first_policy)
  protect({:lens, :navigate}, with: :second_policy)

  after_action({:lens, :navigate}, on: :delivered, run: :first_hook)
  after_action({:lens, :navigate}, on: :delivered, run: :second_hook)

  policy :first_policy do
    accept(:yes, regex: ~r/^yes$/)
  end

  policy :second_policy do
    accept(:yes, regex: ~r/^yes$/)
  end

  def first_hook(_result, _ctx), do: :ok
  def second_hook(_result, _ctx), do: :ok
end

defmodule SpectreStableReleaseRegressionTest.AllGuardAgent do
  @moduledoc false

  use Spectre.Agent

  before_action(:all,
    run: {SpectreStableReleaseRegressionTest.Guards, :suppress}
  )
end

defmodule SpectreStableReleaseRegressionTest.NonportableAgent do
  @moduledoc false

  use Spectre.Agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :regression do
    on :BAD_STATE, regex: ~r/^bad state$/ do
      run(:put_nonportable_state)
    end
  end

  def put_nonportable_state(input, ctx) do
    state = %{ctx.state | data: Map.put(ctx.state.data, :worker, self())}
    {:ok, %Spectre.Result{input: input, route: ctx.route, state: state, reply_text: "bad"}}
  end
end

defmodule SpectreStableReleaseRegressionTest.Delivery do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, _opts), do: {:ok, text}
end

defmodule SpectreStableReleaseRegressionTest.DispatcherActions do
  @moduledoc false

  def step(args, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:dispatcher_step, args.step})
    {:ok, args}
  end
end

defmodule SpectreStableReleaseRegressionTest.DispatcherAgent do
  @moduledoc false

  use Spectre.Agent
  actions(SpectreStableReleaseRegressionTest.DispatcherActions)
end

defmodule SpectreStableReleaseRegressionTest.Embedding do
  @moduledoc false
  @behaviour Spectre.Classifier.Embedding

  @impl true
  def load(_model, _opts), do: {:ok, 2}

  @impl true
  def embed(text, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:embedding_regression_call, text})
    {:ok, [1.0, 0.0]}
  end
end

defmodule SpectreStableReleaseRegressionTest.EmbeddingAgent do
  @moduledoc false

  use Spectre.Agent

  embedding(SpectreStableReleaseRegressionTest.Embedding)
  router(via: [:embedding], semantic_cache?: false, classification_log?: false)

  flow :embedding_cache do
    on :CACHED_EXAMPLE, embedding: ["fixed rule example"] do
      reply(:cached_example)
    end
  end
end

defmodule SpectreStableReleaseRegressionTest do
  use ExUnit.Case, async: false

  alias Spectre.Action
  alias Spectre.ActionGuards
  alias Spectre.Effect
  alias Spectre.Execution
  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec, as: CanonicalCodec
  alias Spectre.Journal.Record
  alias Spectre.Lifecycle
  alias Spectre.Operation.Budget
  alias Spectre.Result
  alias Spectre.Router.Arbitration
  alias Spectre.Router.Arbitrators.Default
  alias Spectre.Router.Candidate
  alias Spectre.Run.Value
  alias Spectre.State
  alias Spectre.Subject
  alias Spectre.Turn
  alias Spectre.Turn.Dispatcher
  alias SpectreStableReleaseRegressionTest.AllGuardAgent
  alias SpectreStableReleaseRegressionTest.Delivery
  alias SpectreStableReleaseRegressionTest.DispatcherAgent
  alias SpectreStableReleaseRegressionTest.EmbeddingAgent
  alias SpectreStableReleaseRegressionTest.GuardedAgent
  alias SpectreStableReleaseRegressionTest.NonportableAgent

  test "provider-qualified before_action refs match without tuple string conversion" do
    effect = provider_effect("run-a")
    ctx = %{agent: GuardedAgent, opts: [run_id: "run-a", instance_run_lifecycle?: true]}

    assert {:suppress, "blocked by provider guard"} = ActionGuards.check(effect, ctx, [])
  end

  test "before_action :all guards provider-qualified actions" do
    effect =
      :navigate
      |> Action.new(via: :lens)
      |> Action.to_effect_attrs()
      |> Effect.stage_action(AllGuardAgent, :agent)
      |> Effect.bind_run("run-all")

    ctx = %{agent: AllGuardAgent, opts: [run_id: "run-all", instance_run_lifecycle?: true]}

    assert {:suppress, "blocked by provider guard"} = ActionGuards.check(effect, ctx, [])
  end

  test "suppression cancels only the owning run's lifecycle work" do
    first = provider_effect("run-a")
    second = provider_effect("run-b")

    {:ok, first_transition} = Lifecycle.stage(%State{}, first)
    {:ok, second_transition} = Lifecycle.stage(first_transition.to, second)

    ctx = %{
      agent: GuardedAgent,
      input: Spectre.Input.new("navigate"),
      opts: [run_id: "run-a", instance_run_lifecycle?: true]
    }

    assert {:ok, %Result{} = result} = Execution.execute_pending(second_transition.to, ctx)
    assert result.reply_text == "blocked by provider guard"
    assert [%Effect{run_id: "run-b", id: second_id}] = result.state.pending_effects
    assert second_id == second.id
    assert hd(result.events).effect_id == first.id
  end

  test "protect and after_action metadata retain declaration order" do
    definition = GuardedAgent.__spectre_definition__()

    assert Enum.map(definition.protections, & &1.policy) == [:first_policy, :second_policy]
    assert Enum.map(definition.after_actions, & &1.run) == [:first_hook, :second_hook]
  end

  test "canonical and journal JSON codecs wrap JSONB-hostile binaries" do
    opaque = <<0, 255, 128, 1>>
    nul_atom = :erlang.binary_to_atom(<<0>>, :utf8)

    assert {:ok, encoded_value} = Value.encode(%{opaque: opaque})
    assert {:ok, %{opaque: ^opaque}} = Value.decode(encoded_value)
    assert {:ok, _json} = Spectre.JSON.encode(encoded_value)

    assert {:ok, encoded_atom} = Value.encode(nul_atom)
    assert {:ok, ^nul_atom} = Value.decode(encoded_atom)
    assert {:ok, atom_json} = Spectre.JSON.encode(encoded_atom)
    refute atom_json =~ "\\u0000"

    assert {:ok, state_json} =
             Spectre.State.Codec.encode_json(%State{data: %{hostile_atom: nul_atom}})

    refute state_json =~ "\\u0000"

    assert {:ok, %State{data: %{hostile_atom: ^nul_atom}}} =
             Spectre.State.Codec.decode(state_json)

    {:ok, canonical} =
      Canonical.new(%{
        flow: %State{data: %{opaque: opaque}},
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: "jsonb-regression"},
        events: %{records: [], ids: %{}}
      })

    assert {:ok, json} = CanonicalCodec.encode_json(canonical)
    assert {:ok, restored_canonical} = CanonicalCodec.decode(json)
    assert {:ok, %State{data: %{opaque: ^opaque}}} = Canonical.fetch(restored_canonical, :flow)

    record =
      Record.new(
        agent: __MODULE__,
        phase: :policy,
        metadata: %{opaque => :hostile_key, opaque: opaque, nul_atom: nul_atom}
      )

    persisted = record |> Record.to_json_map() |> Spectre.JSON.encode!() |> Spectre.JSON.decode!()

    assert {:ok, restored_record} = Record.restore(persisted)
    assert restored_record.phase == :policy
    assert restored_record.metadata["opaque"] == opaque

    assert restored_record.metadata[
             "$spectre:binary-key:" <> Base.url_encode64(opaque, padding: false)
           ] ==
             "hostile_key"

    assert restored_record.metadata["nul_atom"] == <<0>>
    assert %DateTime{} = restored_record.occurred_at
  end

  test "semantic-cache evidence outranks bag similarity" do
    semantic = candidate(:CACHE, :semantic_cache_search, 0.91)
    bag = candidate(:BAG, :bag, 0.99)

    arbitration = %Arbitration{
      input: Spectre.Input.new("cached"),
      state: %State{},
      rules: [],
      labels: [:CACHE, :BAG],
      candidates: [bag, semantic]
    }

    assert {:ok, route} = Default.decide(arbitration, conflict: :best)
    assert route.label == :CACHE
    assert route.strategy == :semantic_cache_search
  end

  test "rule-example embeddings are reused across requests" do
    namespace = make_ref()

    opts = [
      test_pid: self(),
      embedding_cache_namespace: namespace,
      embedding_example_cache_capacity: 8
    ]

    assert {:ok, first} = Spectre.Router.evaluate(EmbeddingAgent, "first query", opts)
    assert first.label == :CACHED_EXAMPLE
    assert_receive {:embedding_regression_call, "first query"}
    assert_receive {:embedding_regression_call, "fixed rule example"}

    assert {:ok, second} = Spectre.Router.evaluate(EmbeddingAgent, "second query", opts)
    assert second.label == :CACHED_EXAMPLE
    assert_receive {:embedding_regression_call, "second query"}
    refute_receive {:embedding_regression_call, "fixed rule example"}, 50
  end

  test "the final allowed dispatcher transition can deliver its terminal decision" do
    effects =
      Enum.map(1..4, fn step ->
        :step
        |> Action.new(args: %{step: step})
        |> Action.to_effect_attrs()
        |> Effect.stage_action(DispatcherAgent, :agent)
        |> Effect.bind_run("dispatcher-run")
      end)

    # A restored/extension-owned queue can expose more than one sequential
    # effect for the same lifecycle run. Each execution is one dispatcher step.
    state = %State{pending_effects: effects, planned_effects: effects}

    result = %Result{
      input: Spectre.Input.new("navigate"),
      state: state,
      effects: effects,
      metadata: %{lifecycle_run_id: "dispatcher-run"},
      reply_text: "queued"
    }

    turn = %Turn{
      agent: DispatcherAgent,
      input: result.input,
      opts: [],
      result: result,
      decision: {:needs, hd(state.pending_effects), result}
    }

    assert {:ok, "%{step: 4}"} = Dispatcher.dispatch(turn, Delivery, test_pid: self())
    assert_received {:dispatcher_step, 1}
    assert_received {:dispatcher_step, 2}
    assert_received {:dispatcher_step, 3}
    assert_received {:dispatcher_step, 4}
  end

  test "a nonportable Flow result fails its run without terminating the Instance" do
    subject = Subject.new("stable-nonportable-#{System.unique_integer([:positive, :monotonic])}")

    instance =
      start_supervised!({Instance, agent: NonportableAgent, subject: subject, idle: false})

    assert {:error, {:canonical_flow_commit_failed, _reason}} =
             Instance.ask(instance, "bad state")

    assert Process.alive?(instance)
    assert %State{data: %{}} = Spectre.state(instance)
  end

  test "stable API edge contracts fail closed and match their docs" do
    assert :centroid in Spectre.Classifier.artifact_schema_atoms()

    assert %Spectre.Route{label: :hello, accepted?: true} =
             Spectre.Route.new(label: :hello, accepted?: true)

    assert_raise ArgumentError, ~r/unknown operational budget key/, fn ->
      Budget.new(steps: 2, typo_limit: 1)
    end

    assert_raise ArgumentError, ~r/unknown operational budget consumption/, fn ->
      Budget.new(limits: %{attempts: 2}, consumed: %{attemps: 1})
    end

    assert {:skip, :invalid_agent} =
             Spectre.Router.SemanticCache.learn_eligibility(:not_an_agent, %{
               label: :ROUTE,
               accepted?: true,
               strategy: :llm_classifier
             })
  end

  test "history limits and summarizer callbacks are validated at compile time" do
    suffix = System.unique_integer([:positive, :monotonic])

    assert_raise ArgumentError, ~r/invalid_history_limit/, fn ->
      Code.compile_string("""
      defmodule SpectreInvalidHistory#{suffix} do
        use Spectre.Agent
        history(-1)
      end
      """)
    end

    assert_raise ArgumentError, ~r/invalid_history_summarizer/, fn ->
      Code.compile_string("""
      defmodule SpectreInvalidSummarizer#{suffix} do
        use Spectre.Agent
        history(2, summary: {String, :definitely_missing})
      end
      """)
    end
  end

  defp provider_effect(run_id) do
    :navigate
    |> Action.new(via: :lens)
    |> Action.to_effect_attrs()
    |> Effect.stage_action(GuardedAgent, :agent)
    |> Effect.bind_run(run_id)
  end

  defp candidate(label, provider, score) do
    Candidate.new(%{
      label: label,
      provider: provider,
      score: score,
      margin: 0.2,
      strength: :medium,
      accepted?: true,
      handler: {:reply, label, []},
      scope: :agent
    })
  end
end
