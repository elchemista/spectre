defmodule SpectreProductionReadinessTest.Actions do
  @moduledoc false

  def perform(args, ctx) do
    send(Keyword.fetch!(ctx.opts, :test_pid), {:performed, args, ctx.opts[:idempotency_key]})
    {:ok, args}
  end
end

defmodule SpectreProductionReadinessTest.CASStore do
  @moduledoc false
  @behaviour Spectre.State.Store

  @impl Spectre.State.Store
  def load(_input, _agent, opts) do
    key = {__MODULE__, Keyword.get(opts, :conversation_id)}
    {:ok, :persistent_term.get(key, %Spectre.State{})}
  end

  @impl Spectre.State.Store
  def compare_and_swap(state, expected, _input, _agent, opts) do
    key = {__MODULE__, state.conversation_id || Keyword.get(opts, :conversation_id)}
    current = :persistent_term.get(key, %Spectre.State{})

    if current.revision == expected do
      :persistent_term.put(key, state)
      {:ok, state}
    else
      {:error, {:stale_state, current.revision}}
    end
  end
end

defmodule SpectreProductionReadinessTest.HangingStore do
  @moduledoc false

  def load(_input, _agent, _opts) do
    receive do
      :never -> {:ok, %Spectre.State{}}
    end
  end
end

defmodule SpectreProductionReadinessTest.HangingActions do
  @moduledoc false

  def perform(_args, _ctx) do
    receive do
      :never -> {:ok, :never}
    end
  end
end

defmodule SpectreProductionReadinessTest.Agent do
  @moduledoc false

  use Spectre.Agent

  actions(SpectreProductionReadinessTest.Actions)
  state(SpectreProductionReadinessTest.CASStore)

  flow :operations do
    on :PERFORM, regex: ~r/^perform$/ do
      action(:perform, args: %{source: :session})
    end
  end
end

defmodule SpectreProductionReadinessTest.HangingAgent do
  @moduledoc false

  use Spectre.Agent
  state(SpectreProductionReadinessTest.HangingStore)
end

defmodule SpectreProductionReadinessTest.HangingActionAgent do
  @moduledoc false

  use Spectre.Agent
  actions(SpectreProductionReadinessTest.HangingActions)

  flow :operations do
    on :PERFORM, regex: ~r/^perform$/ do
      action(:perform)
    end
  end
end

defmodule SpectreProductionReadinessTest do
  use ExUnit.Case, async: false

  alias Spectre.Effect
  alias Spectre.Lifecycle
  alias Spectre.Provider.Failure
  alias Spectre.State
  alias Spectre.State.Codec

  setup do
    conversation_id = "production-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      :persistent_term.erase({SpectreProductionReadinessTest.CASStore, conversation_id})
    end)

    %{conversation_id: conversation_id}
  end

  test "state codec round-trips scoped effects and rejects malformed enums" do
    effect =
      Effect.stage_action(
        %{name: :perform, args: %{count: 2}},
        SpectreProductionReadinessTest.Actions,
        {:skill, :support}
      )

    state =
      %State{
        revision: 7,
        conversation_id: "codec",
        current_flow: :operations,
        current_scope: {:skill, :support},
        data: %{nested: {:ok, DateTime.utc_now(:second)}}
      }
      |> State.put_pending_effect(effect, {{:skill, :support}, :confirm})
      |> State.trace(%{type: :codec_test, at: DateTime.utc_now(:second)})

    assert {:ok, json} = Codec.encode_json(state)
    assert {:ok, ^state} = Codec.decode(json)

    assert %Effect{
             owner: SpectreProductionReadinessTest.Actions,
             scope: {:skill, :support}
           } = State.pending_effect(state)

    refute Map.has_key?(effect.payload, :owner)
    refute Map.has_key?(effect.payload, :scope)

    assert {:ok, encoded} = Codec.encode(state)
    [pending] = encoded["pending_effects"]
    assert Map.has_key?(pending, "owner")
    assert Map.has_key?(pending, "scope")

    malformed = put_in(encoded, ["pending_effects"], [%{pending | "status" => "owned"}])

    assert {:error, {:invalid_enum, "status", "owned"}} = Codec.decode(malformed)

    missing_scope =
      put_in(encoded, ["pending_effects"], [Map.delete(pending, "scope")])

    assert {:ok, decoded_without_scope} = Codec.decode(missing_scope)
    assert %Effect{scope: nil} = State.pending_effect(decoded_without_scope)

    assert {:error, {:duplicate_or_unknown_field, :state, "surprise"}} =
             Codec.decode(Map.put(encoded, "surprise", true))
  end

  test "state codec migrates v3 payload scope into first-class effect fields" do
    effect =
      Effect.stage_action(
        %{name: :perform},
        SpectreProductionReadinessTest.Actions,
        {:skill, :support}
      )

    state = State.put_pending_effect(%State{}, effect, nil)

    assert {:ok, encoded} = Codec.encode(state)
    assert {:ok, restored} = encoded |> legacy_v3_state(true) |> Codec.decode()

    assert %Effect{owner: nil, scope: {:skill, :support}} =
             restored_effect =
             State.pending_effect(restored)

    refute Map.has_key?(restored_effect.payload, :owner)
    refute Map.has_key?(restored_effect.payload, :scope)
  end

  test "a legacy effect without scope decodes but fails before action execution" do
    effect =
      Effect.stage_action(
        %{name: :perform},
        SpectreProductionReadinessTest.Agent,
        :agent
      )

    state = State.put_pending_effect(%State{}, effect, nil)

    assert {:ok, encoded} = Codec.encode(state)
    assert {:ok, legacy_state} = encoded |> legacy_v3_state(false) |> Codec.decode()

    assert %Effect{id: effect_id, owner: nil, scope: nil} = State.pending_effect(legacy_state)

    assert {:error, {:effect_scope_missing, ^effect_id}} =
             Spectre.execute(legacy_state, %{
               agent: SpectreProductionReadinessTest.Agent,
               opts: [test_pid: self()]
             })

    refute_receive {:performed, _, _}
  end

  test "state codec enforces outer payload and bounded collection limits" do
    assert {:error, {:state_payload_too_large, 2_000_001, 2_000_000}} =
             Codec.decode(String.duplicate(" ", 2_000_001))

    oversized = %State{trace: Enum.to_list(1..257)}

    assert {:error, {:state_collection_too_large, :trace, 257, 256}} =
             Codec.encode(oversized)
  end

  test "lifecycle rejects forbidden transitions and replays terminal completion" do
    effect = Effect.stage(%{name: :perform})
    {:ok, staged} = Lifecycle.stage(%State{}, effect, :confirm)

    assert {:error, {:invalid_effect_transition, _, :waiting_policy, :completed}} =
             Lifecycle.complete_effect(staged.to, effect.id, :too_early)

    {:ok, approved} = Lifecycle.resolve_policy(staged.to, :accept, :accepted)
    {:ok, completed} = Lifecycle.complete_effect(approved.to, effect.id, :done)
    {:ok, replayed} = Lifecycle.complete_effect(completed.to, effect.id, :ignored)

    assert replayed.replayed?
    assert replayed.effect.result == :done
    assert replayed.to == completed.to
  end

  test "CAS persistence rejects a stale turn", %{conversation_id: conversation_id} do
    assert {:ok, first} =
             Spectre.ask(SpectreProductionReadinessTest.Agent, "perform",
               conversation_id: conversation_id,
               test_pid: self()
             )

    assert first.state.revision == 1

    stale = %State{conversation_id: conversation_id, revision: 0}

    assert {:error, {:stale_state, 0, 1}} =
             Spectre.ask(SpectreProductionReadinessTest.Agent, "perform",
               conversation_id: conversation_id,
               state: stale,
               test_pid: self()
             )
  end

  test "Session execution persists terminal state and repeats without another side effect", %{
    conversation_id: conversation_id
  } do
    session =
      start_supervised!(
        {Spectre.Session,
         agent: SpectreProductionReadinessTest.Agent,
         conversation_id: conversation_id,
         idle: false,
         opts: [test_pid: self()]}
      )

    assert {:ok, staged} = Spectre.ask(session, "perform")
    assert staged.state.revision == 1

    assert {:ok, completed} = Spectre.execute(session, staged, test_pid: self())
    assert completed.state.revision == 2
    assert Spectre.Result.action_outcome(completed) == {:ok, %{source: :session}}
    assert_receive {:performed, %{source: :session}, idempotency_key}
    assert is_binary(idempotency_key)

    assert {:ok, replayed} = Spectre.execute(session, staged, test_pid: self())
    assert [%Effect{status: :completed, result: %{source: :session}}] = replayed.effects
    refute_receive {:performed, _, _}
  end

  test "state adapters are deadline isolated" do
    assert {:error, %Failure{provider: :state, kind: :timeout, timeout: 10}} =
             Spectre.Runtime.restore_state(SpectreProductionReadinessTest.HangingAgent,
               state_timeout: 10
             )
  end

  test "action adapters are deadline isolated and timeout outcomes are not retried" do
    assert {:ok, staged} =
             Spectre.ask(SpectreProductionReadinessTest.HangingActionAgent, "perform")

    assert {:ok, failed} =
             Spectre.execute(SpectreProductionReadinessTest.HangingActionAgent, staged,
               action_timeout: 10
             )

    assert [%Effect{status: :failed, error: {:action_outcome_ambiguous, %Failure{} = failure}}] =
             failed.effects

    assert failure.provider == :action
    assert failure.kind == :timeout
    assert failed.state.pending_effects == []

    assert {:ok, replayed} =
             Spectre.execute(SpectreProductionReadinessTest.HangingActionAgent, failed,
               action_timeout: 10
             )

    assert replayed.state == failed.state
  end

  test "corrupt and oversized classifier artifacts fail safely" do
    artifact_dir =
      Path.join(
        System.tmp_dir!(),
        "spectre-corrupt-classifier-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(artifact_dir)
    on_exit(fn -> File.rm_rf(artifact_dir) end)
    artifact = Path.join(artifact_dir, "classifier.etf")

    File.write!(artifact, <<131, 255, 0, 1>>)

    assert {:error, {:invalid_classifier_artifact, _exception, _message}} =
             Spectre.Classifier.classify_once("classify me", artifact_dir: artifact_dir)

    File.write!(artifact, :erlang.term_to_binary(%{kind: :unsupported}))

    assert {:error, {:classifier_artifact_too_large, size, 1}} =
             Spectre.Classifier.classify_once("classify me",
               artifact_dir: artifact_dir,
               classifier_artifact_max_bytes: 1
             )

    assert size > 1
  end

  test "Session child specs are transient and stale idle generations are ignored" do
    assert %{restart: :transient} =
             Spectre.Session.child_spec(agent: SpectreProductionReadinessTest.Agent)

    pid =
      start_supervised!(
        {Spectre.Session,
         agent: SpectreProductionReadinessTest.Agent,
         id: :idle_generation_session,
         idle: 5_000,
         state: %State{}}
      )

    generation = :sys.get_state(pid).idle_generation
    send(pid, {:idle_shutdown, generation - 1})
    Process.sleep(5)
    assert Process.alive?(pid)
  end

  @spec legacy_v3_state(map(), boolean()) :: map()
  defp legacy_v3_state(encoded, include_scope?) do
    encoded
    |> Map.put("state_version", 3)
    |> Map.update!(
      "pending_effects",
      &Enum.map(&1, fn effect -> legacy_effect(effect, include_scope?) end)
    )
    |> Map.update!(
      "planned_effects",
      &Enum.map(&1, fn effect -> legacy_effect(effect, include_scope?) end)
    )
  end

  @spec legacy_effect(map(), boolean()) :: map()
  defp legacy_effect(effect, include_scope?) do
    payload =
      if include_scope? do
        scope_key = %{"$spectre" => "atom", "value" => "scope"}
        Map.update!(effect["payload"], "entries", &[[scope_key, effect["scope"]] | &1])
      else
        effect["payload"]
      end

    effect
    |> Map.drop(["owner", "scope"])
    |> Map.put("payload", payload)
  end
end
