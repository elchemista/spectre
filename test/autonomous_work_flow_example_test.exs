defmodule SpectreAutonomousWorkFlowExampleTest.Operations do
  @moduledoc false

  def collect_context(%{topic: topic}, context) do
    send(
      Keyword.fetch!(context.opts, :test_pid),
      {:autonomous_context_collected, topic, context.attempt.id, self()}
    )

    {:ok,
     %{
       topic: topic,
       candidate_queries: [
         "#{topic} canonical state ownership",
         "#{topic} supervision and recovery"
       ]
     }}
  end

  def research(%{query: query, source: source}, context) do
    send(
      Keyword.fetch!(context.opts, :test_pid),
      {:autonomous_research_started, query, source, context.attempt.id}
    )

    {:ok,
     %{
       query: query,
       source: source,
       finding: "The Agent owns canonical state; temporary Runners execute one attempt."
     }}
  end
end

defmodule SpectreAutonomousWorkFlowExampleTest.ResearchWork do
  @moduledoc false

  use Spectre.Work,
    id: :autonomous_research,
    version: 1,
    input: :map,
    state: :map,
    waits: [:external],
    triggers: [:external],
    artifact_policy: %{publish_results: true, publish_artifacts: true},
    budget: [steps: 5, attempts: 5]

  uses_operation(:collect_autonomous_context)
  uses_operation(:run_autonomous_research)

  @impl true
  def init(%{topic: topic}, _context) do
    {:ok,
     %{
       topic: topic,
       phase: :collect_context,
       evidence: nil,
       internal_response: nil,
       finding: nil
     }}
  end

  @impl true
  def next(%{phase: :collect_context, topic: topic}, _context) do
    run(:collect_autonomous_context, %{topic: topic}, phase: :collecting_context)
  end

  def next(%{phase: :await_agent}, _context) do
    wait(:external,
      key: :next_research_query,
      reason: :agent_decision_required,
      payload: %{
        response_schema: %{query: :string, source: :string},
        allowed_sources: ["official documentation", "project documentation"]
      }
    )
  end

  def next(%{phase: :research, internal_response: response}, _context) do
    run(
      :run_autonomous_research,
      %{query: response.query, source: response.source},
      phase: :researching
    )
  end

  def next(%{phase: :done, finding: finding}, _context), do: complete(finding)

  @impl true
  def apply_result(state, %{operation: :collect_autonomous_context}, result, _context) do
    {:ok, %{state | phase: :await_agent, evidence: result.value}, phase: :awaiting_agent}
  end

  def apply_result(state, %{operation: :run_autonomous_research}, result, _context) do
    {:ok, %{state | phase: :done, finding: result.value}, phase: :finished}
  end

  @impl true
  def handle_trigger(
        state,
        {:external, %{query: query, source: source, request_event_id: event_id}},
        _context
      )
      when is_binary(query) and query != "" and is_binary(source) and source != "" do
    response = %{query: query, source: source, request_event_id: event_id}
    {:ok, %{state | phase: :research, internal_response: response}, phase: :researching}
  end

  def handle_trigger(_state, trigger, _context),
    do: {:error, {:invalid_internal_flow_response, trigger}}

  @impl true
  def complete(%{phase: :done, finding: finding, internal_response: response}, _context) do
    complete(%{response: response, finding: finding})
  end

  def complete(_state, _context), do: :continue
end

defmodule SpectreAutonomousWorkFlowExampleTest.Agent do
  @moduledoc false

  use Spectre.Agent

  alias SpectreAutonomousWorkFlowExampleTest.Operations

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  route_operation_events([:waiting])

  operation(:collect_autonomous_context, {Operations, :collect_context},
    input: :map,
    output: :map,
    side_effect: :none
  )

  operation(:run_autonomous_research, {Operations, :research},
    input: :map,
    output: :map,
    side_effect: :none
  )

  flow :autonomous_work do
    on :AUTONOMOUS_WORK_REQUEST, regex: ~r/^$/ do
      run(:resolve_autonomous_work_request)
    end
  end

  def resolve_autonomous_work_request(
        %{meta: %{spectre_event: %Spectre.Operation.Event{type: :waiting} = event}} = input,
        context
      ) do
    instance = Keyword.fetch!(context.opts, :instance_pid)
    test_pid = Keyword.fetch!(context.opts, :test_pid)

    with {:ok,
          %Spectre.Operation.View{
            definition: :autonomous_research,
            phase: :awaiting_agent,
            partial_results: [%{candidate_queries: [query | _]} | _]
          }} <- Spectre.loop(instance, event.loop_id),
         :ok <- await_test_release(test_pid, event),
         response = %{
           query: query,
           source: "official documentation",
           request_event_id: event.id
         },
         {:ok, resumed} <-
           Spectre.trigger_loop(instance, event.loop_id, {:external, response},
             correlation_id: event.correlation_id,
             causation_id: event.id,
             provenance: %{source: :internal_flow, operation_event_id: event.id}
           ) do
      send(
        test_pid,
        {:autonomous_flow_answered, event.id, event.loop_id, response, resumed.status}
      )

      decision = Map.put(response, :loop_id, event.loop_id)
      decisions = Map.get(context.state.data, :autonomous_decisions, [])

      state = %{
        context.state
        | data: Map.put(context.state.data, :autonomous_decisions, [decision | decisions])
      }

      {:ok,
       %Spectre.Result{
         input: input,
         route: context.route,
         state: state,
         metadata: %{
           internal_request_event_id: event.id,
           internal_response: response,
           operation_view: resumed
         }
       }}
    else
      {:ok, %Spectre.Operation.View{}} ->
        {:ok,
         %Spectre.Result{
           input: input,
           route: context.route,
           state: context.state,
           metadata: %{operation_event_ignored?: true}
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_test_release(test_pid, event) do
    send(test_pid, {:autonomous_flow_requested, event.id, event.loop_id, self()})

    receive do
      {:continue_autonomous_flow, event_id} when event_id == event.id -> :ok
    after
      1_000 -> {:error, :autonomous_flow_release_timeout}
    end
  end
end

defmodule SpectreAutonomousWorkFlowExampleTest do
  use ExUnit.Case, async: false

  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Operation.Ref
  alias Spectre.Operation.View
  alias Spectre.Subject

  @agent SpectreAutonomousWorkFlowExampleTest.Agent
  @work SpectreAutonomousWorkFlowExampleTest.ResearchWork

  test "a host-started Work activates an internal Flow and resumes without chat" do
    correlation_id = "autonomous-chain-#{System.unique_integer([:positive, :monotonic])}"
    instance = start_instance()

    assert {:ok, %Ref{kind: :work} = work_ref, %View{status: :queued}} =
             Spectre.start_work(instance, @work, %{topic: "Spectre OTP"},
               origin: :bootstrap,
               correlation_id: correlation_id,
               provenance: %{source: :host_bootstrap}
             )

    assert_receive {:autonomous_context_collected, "Spectre OTP", first_attempt_id, first_worker},
                   1_000

    assert_receive {:autonomous_flow_requested, request_event_id, loop_id, flow_worker}, 1_000

    assert loop_id == work_ref.id
    assert Process.alive?(flow_worker)
    refute Process.alive?(first_worker)

    assert {:ok, %View{status: :waiting, phase: :awaiting_agent}} =
             Spectre.loop(instance, work_ref)

    assert Instance.info(instance).operation_runners == %{}
    send(flow_worker, {:continue_autonomous_flow, request_event_id})

    assert_receive {:autonomous_flow_answered, ^request_event_id, ^loop_id, response, :queued},
                   1_000

    assert response.request_event_id == request_event_id
    assert response.query == "Spectre OTP canonical state ownership"
    assert response.source == "official documentation"

    assert_receive {:autonomous_research_started, query, source, attempt_id}, 1_000
    assert query == response.query
    assert source == response.source
    assert is_binary(attempt_id)
    assert attempt_id != first_attempt_id

    assert {:ok, completed} = eventually_loop(instance, work_ref, &(&1.status == :terminal))
    assert completed.terminal_category == :completed
    assert completed.attempts == 2
    assert Instance.info(instance).operation_runners == %{}

    canonical_work = canonical_work(instance, work_ref)

    assert canonical_work.state.internal_response == response

    assert canonical_work.outcome.result == %{
             response: response,
             finding: %{
               query: response.query,
               source: response.source,
               finding: "The Agent owns canonical state; temporary Runners execute one attempt."
             }
           }

    assert_eventually(fn ->
      instance
      |> Spectre.state()
      |> Map.fetch!(:data)
      |> Map.get(:autonomous_decisions, [])
      |> Enum.any?(&(&1.request_event_id == request_event_id and &1.loop_id == work_ref.id))
    end)

    events = Spectre.operation_events(instance)

    assert Enum.any?(events, fn event ->
             event.id == request_event_id and event.type == :waiting and
               event.loop_id == work_ref.id and event.correlation_id == correlation_id
           end)

    assert Enum.any?(events, fn event ->
             event.type == :triggered and event.loop_id == work_ref.id and
               event.causation_id == request_event_id and
               event.provenance.source == :internal_flow
           end)
  end

  defp start_instance do
    subject =
      Subject.new("autonomous-example-#{System.unique_integer([:positive, :monotonic])}")

    start_supervised!(
      {Instance, agent: @agent, subject: subject, idle: false, opts: [test_pid: self()]}
    )
  end

  defp eventually_loop(instance, ref, predicate, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_eventually_loop(instance, ref, predicate, deadline)
  end

  defp do_eventually_loop(instance, ref, predicate, deadline) do
    case Spectre.loop(instance, ref) do
      {:ok, view} = success ->
        if predicate.(view) do
          success
        else
          continue_eventually_loop(instance, ref, predicate, deadline)
        end

      _other ->
        continue_eventually_loop(instance, ref, predicate, deadline)
    end
  end

  defp continue_eventually_loop(instance, ref, predicate, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(5)
      do_eventually_loop(instance, ref, predicate, deadline)
    else
      flunk("autonomous Work did not reach the expected state")
    end
  end

  defp canonical_work(instance, ref) do
    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert {:ok, works} = Canonical.fetch(canonical, :work)
    Map.fetch!(works, ref.id)
  end

  defp assert_eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(5)
        do_assert_eventually(fun, deadline)
      else
        flunk("condition did not become true before timeout")
      end
    end
  end
end
