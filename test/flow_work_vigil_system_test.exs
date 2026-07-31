defmodule SpectreFlowWorkVigilSystemTest.Operations do
  @moduledoc false

  def fetch_page(%{page: page, block?: block?}, context) do
    test_pid = Keyword.fetch!(context.opts, :test_pid)
    send(test_pid, {:example_page_started, page, context.attempt, self()})

    if block? do
      receive do
        {:release_example_page, ^page} -> :ok
      end
    end

    {:ok, %{page: page, title: "Page #{page}"}}
  end

  def read_weather(%{city: city, round: round}, context) do
    reading = %{
      city: city,
      round: round,
      temperature: 20 + round * 15,
      alert: round > 0
    }

    send(
      Keyword.fetch!(context.opts, :test_pid),
      {:example_weather_observed, reading, context.attempt, self()}
    )

    {:ok, reading}
  end

  def fail(%{reason: reason}, context) do
    send(
      Keyword.fetch!(context.opts, :test_pid),
      {:example_failure_started, reason, context.attempt, self()}
    )

    {:error, reason}
  end
end

defmodule SpectreFlowWorkVigilSystemTest.ResearchWork do
  @moduledoc false

  use Spectre.Work,
    id: :example_research,
    version: 1,
    input: :map,
    state: :map,
    update: :map,
    update_fields: [:pages],
    artifact_policy: %{publish_results: true, publish_artifacts: true},
    budget: [steps: 20, attempts: 20]

  uses_operation(:fetch_example_page)

  @impl true
  def init(input, _context) do
    {:ok,
     %{
       queue: input.pages,
       pages: [],
       block_page: Map.get(input, :block_page)
     }}
  end

  @impl true
  def next(%{queue: [page | _], block_page: block_page}, _context) do
    run(
      :fetch_example_page,
      %{page: page, block?: page == block_page},
      phase: :reading_pages
    )
  end

  def next(%{queue: []}, _context), do: complete(:all_pages_read)

  @impl true
  def apply_result(%{queue: [_ | rest]} = state, _request, result, _context) do
    {:ok, %{state | queue: rest, pages: state.pages ++ [result.value]}}
  end

  @impl true
  def complete(%{queue: [], pages: pages}, _context), do: complete(pages)
  def complete(_state, _context), do: :continue

  @impl true
  def apply_update(state, input, update, _context) do
    additions = update.payload.pages
    known = Enum.map(state.pages, & &1.page) ++ state.queue
    additions = Enum.reject(additions, &(&1 in known))

    next_state = %{
      state
      | queue: state.queue ++ additions,
        block_page: nil
    }

    next_input = Map.put(input, :pages, Enum.uniq(input.pages ++ additions))
    {:ok, next_state, next_input}
  end
end

defmodule SpectreFlowWorkVigilSystemTest.WeatherVigil do
  @moduledoc false

  use Spectre.Vigil,
    id: :example_weather,
    version: 1,
    input: :map,
    state: :map,
    waits: [:external],
    triggers: [:external],
    artifact_policy: %{publish_results: true, publish_artifacts: false},
    budget: [steps: 20, attempts: 20]

  uses_operation(:read_example_weather)

  @impl true
  def init(input, _context) do
    {:ok, %{city: input.city, round: 0, ready?: true, readings: []}}
  end

  @impl true
  def next(%{ready?: true, city: city, round: round}, _context) do
    observe(:read_example_weather, %{city: city, round: round}, phase: :observing_weather)
  end

  def next(%{ready?: false}, _context), do: wait(:external, reason: :next_observation)

  @impl true
  def apply_result(state, _request, result, _context) do
    significance = if result.value.alert, do: :significant, else: :silent

    {:ok,
     %{
       state
       | ready?: false,
         round: state.round + 1,
         readings: state.readings ++ [result.value]
     }, significance: significance}
  end

  @impl true
  def handle_trigger(state, :external, _context), do: {:ok, %{state | ready?: true}}
  def handle_trigger(state, {:external, _payload}, _context), do: {:ok, %{state | ready?: true}}
end

defmodule SpectreFlowWorkVigilSystemTest.FailingWork do
  @moduledoc false

  use Spectre.Work,
    id: :example_failure,
    version: 1,
    input: :map,
    state: :map,
    budget: [steps: 2, attempts: 1]

  uses_operation(:fail_example_operation)

  @impl true
  def init(input, _context), do: {:ok, %{reason: input.reason}}

  @impl true
  def next(%{reason: reason}, _context), do: run(:fail_example_operation, %{reason: reason})

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: :continue
end

defmodule SpectreFlowWorkVigilSystemTest.Renderer do
  @moduledoc false

  def render(:pong, _input, _context), do: "pong"
end

defmodule SpectreFlowWorkVigilSystemTest.Agent do
  @moduledoc false

  use Spectre.Agent

  alias SpectreFlowWorkVigilSystemTest.FailingWork
  alias SpectreFlowWorkVigilSystemTest.Operations
  alias SpectreFlowWorkVigilSystemTest.Renderer
  alias SpectreFlowWorkVigilSystemTest.ResearchWork
  alias SpectreFlowWorkVigilSystemTest.WeatherVigil

  router(via: [:regex], semantic_cache?: false, classification_log?: false)
  route_operation_events([:completed, :failed, :observation_significant])

  operation(:fetch_example_page, {Operations, :fetch_page},
    input: :map,
    output: :map,
    side_effect: :none
  )

  operation(:read_example_weather, {Operations, :read_weather},
    input: :map,
    output: :map,
    side_effect: :none
  )

  operation(:fail_example_operation, {Operations, :fail},
    input: :map,
    output: :map,
    side_effect: :none,
    retry: [max_attempts: 1]
  )

  flow :operational_examples do
    on :START_RESEARCH, regex: ~r/^research$/i do
      work(ResearchWork,
        input: %{pages: [1, 2], block_page: 1},
        origin: :chat,
        reply_text: "research started"
      )
    end

    on :RESEARCH_STATUS, regex: ~r/^research status$/i do
      run(:research_status)
    end

    on :ADD_RESEARCH_PAGE, regex: ~r/^add page 3$/i do
      run(:add_research_page)
    end

    on :START_WEATHER_VIGIL, regex: ~r/^watch [a-z]+$/i do
      run(:register_weather_vigil)
    end

    on :START_FAILURE, regex: ~r/^fail work$/i do
      work(FailingWork,
        input: %{reason: :source_unavailable},
        origin: :chat,
        reply_text: "failure probe started"
      )
    end

    on :PING, regex: ~r/^ping$/i do
      reply(:pong, renderer: {Renderer, :render})
    end

    on :OPERATION_EVENT, regex: ~r/^$/ do
      run(:record_operation_event)
    end
  end

  def research_status(input, context) do
    case resolve_research(context) do
      {:ok, view} ->
        result(input, context, "research #{view.status}:#{view.phase}", %{operation_view: view})

      {:error, :operation_loop_not_found} ->
        result(input, context, "research not found")

      {:error, reason} ->
        {:error, reason}
    end
  end

  def add_research_page(input, context) do
    run_id = Keyword.fetch!(context.opts, :run_id)

    with {:ok, view} <- resolve_research(context),
         {:ok, updated} <-
           Spectre.update_and_resume_loop(
             Keyword.fetch!(context.opts, :instance_pid),
             view.id,
             %{pages: [3]},
             command_id: "add-page-#{run_id}",
             correlation_id: run_id,
             causation_id: run_id,
             provenance: %{source: :flow, route: :ADD_RESEARCH_PAGE}
           ) do
      result(input, context, "research update requested", %{operation_view: updated})
    end
  end

  def register_weather_vigil(input, context) do
    city = input.text |> String.split(" ", parts: 2) |> List.last() |> String.capitalize()
    run_id = Keyword.fetch!(context.opts, :run_id)

    with {:ok, ref, view} <-
           Spectre.register_vigil(
             Keyword.fetch!(context.opts, :instance_pid),
             WeatherVigil,
             %{city: city},
             origin: :chat,
             correlation_id: run_id,
             causation_id: run_id,
             turn_id: run_id,
             provenance: %{source: :flow, route: :START_WEATHER_VIGIL}
           ) do
      result(input, context, "weather vigil registered for #{city}", %{
        operation_ref: ref,
        operation_view: view
      })
    end
  end

  def record_operation_event(
        %{meta: %{spectre_event: %Spectre.Operation.Event{} = event}} = input,
        context
      ) do
    if test_pid = Keyword.get(context.opts, :test_pid) do
      send(test_pid, {:example_flow_observed_event, event.type, event.loop_id, event.id})
    end

    entry = %{id: event.id, type: event.type, loop_id: event.loop_id, kind: event.loop_kind}
    previous = Map.get(context.state.data, :operation_events, [])
    recorded = Enum.uniq_by([entry | previous], & &1.id)
    state = %{context.state | data: Map.put(context.state.data, :operation_events, recorded)}

    {:ok,
     %Spectre.Result{
       input: input,
       route: context.route,
       state: state,
       metadata: %{operation_event_id: event.id}
     }}
  end

  defp resolve_research(context) do
    Spectre.resolve_loop(
      Keyword.fetch!(context.opts, :instance_pid),
      kind: :work,
      definition: :example_research,
      active: true
    )
  end

  defp result(input, context, reply_text, metadata \\ %{}) do
    {:ok,
     %Spectre.Result{
       input: input,
       route: context.route,
       state: context.state,
       reply_text: reply_text,
       metadata: metadata
     }}
  end
end

defmodule SpectreFlowWorkVigilSystemTest do
  use ExUnit.Case, async: false

  alias Spectre.Instance
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Ref
  alias Spectre.Operation.View
  alias Spectre.Subject
  alias Spectre.Turn

  @agent SpectreFlowWorkVigilSystemTest.Agent
  @research_work SpectreFlowWorkVigilSystemTest.ResearchWork
  @weather_vigil SpectreFlowWorkVigilSystemTest.WeatherVigil
  @failing_work SpectreFlowWorkVigilSystemTest.FailingWork

  test "the example Agent exposes closed Flow, Work and Vigil definitions" do
    operation_ids =
      @agent.__spectre_config__()
      |> Keyword.fetch!(:operations)
      |> Enum.map(& &1.id)

    assert operation_ids == [
             :fetch_example_page,
             :read_example_weather,
             :fail_example_operation
           ]

    assert {:ok, %Definition{} = work} = Definition.load(@research_work)
    assert work.kind == :work
    assert work.imports == [:fetch_example_page]
    assert work.operations == %{}
    assert work.update_fields == [:pages]

    assert {:ok, %Definition{} = vigil} = Definition.load(@weather_vigil)
    assert vigil.kind == :vigil
    assert vigil.imports == [:read_example_weather]
    assert vigil.waits == [:external]
    assert vigil.triggers == [:external]

    assert {:ok, %Definition{} = failure} = Definition.load(@failing_work)
    assert failure.kind == :work
    assert failure.imports == [:fail_example_operation]

    rules = @agent.__spectre_rules__()

    assert %{handler: {:work, @research_work, opts}} =
             Enum.find(rules, &(&1.label == :START_RESEARCH))

    assert opts[:input] == %{pages: [1, 2], block_page: 1}
    assert opts[:reply_text] == "research started"

    assert %{handler: {:run, :record_operation_event, []}} =
             Enum.find(rules, &(&1.label == :OPERATION_EVENT))
  end

  test "a Flow starts, inspects and updates a real Work while remaining responsive" do
    instance = start_instance()

    assert {:ok,
            %Turn{
              decision: {:reply, start_result},
              observable: {:reply, "research started", _turn_ref}
            }} = Spectre.turn(instance, "research")

    assert start_result.route.flow == :operational_examples
    assert start_result.route.label == :START_RESEARCH
    assert %Ref{kind: :work} = work_ref = start_result.metadata.operation_ref

    assert %View{status: :queued, definition: :example_research} =
             start_result.metadata.operation_view

    assert_receive {:example_page_started, 1, first_attempt, first_worker}, 1_000

    assert {:ok, %Turn{observable: {:reply, status, _status_ref}}} =
             Spectre.turn(instance, "research status")

    assert status =~ "research active:reading_pages"
    assert Process.alive?(first_worker)

    assert {:ok,
            %Turn{
              decision: {:reply, update_result},
              observable: {:reply, "research update requested", _update_ref}
            }} = Spectre.turn(instance, "add page 3")

    assert update_result.metadata.operation_view.pause_requested

    assert {:ok, %Turn{observable: {:reply, "pong", _ping_ref}}} =
             Spectre.turn(instance, "ping")

    assert Process.alive?(first_worker)
    send(first_worker, {:release_example_page, 1})

    assert_receive {:example_page_started, 2, second_attempt, _second_worker}, 1_000
    assert_receive {:example_page_started, 3, third_attempt, _third_worker}, 1_000

    assert Enum.uniq([first_attempt.id, second_attempt.id, third_attempt.id]) ==
             [first_attempt.id, second_attempt.id, third_attempt.id]

    assert Enum.uniq([
             first_attempt.fencing_token,
             second_attempt.fencing_token,
             third_attempt.fencing_token
           ]) == [
             first_attempt.fencing_token,
             second_attempt.fencing_token,
             third_attempt.fencing_token
           ]

    assert {:ok, completed} = eventually_loop(instance, work_ref, &(&1.status == :terminal))
    assert completed.terminal_category == :completed
    assert completed.context_revision == 1
    assert completed.last_update.status == :applied
    assert Enum.sort_by(completed.partial_results, & &1.page) == expected_pages()
    assert Instance.info(instance).operation_runners == %{}

    assert_receive {:example_flow_observed_event, :completed, loop_id, completed_event_id},
                   1_000

    assert loop_id == work_ref.id
    assert_flow_recorded(instance, completed_event_id, :completed, work_ref.id)

    assert Enum.any?(
             Spectre.operation_events(instance, types: [:completed]),
             &(&1.id == completed_event_id and &1.loop_id == work_ref.id)
           )

    assert canonical_loop(instance, :work, work_ref).outcome.result == expected_pages()
  end

  test "a Flow registers a Vigil that waits, pauses, resumes and routes significance" do
    instance = start_instance()

    assert {:ok,
            %Turn{
              decision: {:reply, result},
              observable: {:reply, "weather vigil registered for Rome", _turn_ref}
            }} = Spectre.turn(instance, "watch rome")

    assert result.route.label == :START_WEATHER_VIGIL
    assert %Ref{kind: :vigil} = vigil_ref = result.metadata.operation_ref

    assert_receive {:example_weather_observed, first_reading, first_attempt, first_worker},
                   1_000

    assert first_reading == %{
             city: "Rome",
             round: 0,
             temperature: 20,
             alert: false
           }

    assert {:ok, waiting} = eventually_loop(instance, vigil_ref, &(&1.status == :waiting))
    assert waiting.observations == 1
    assert waiting.partial_results == [first_reading]
    refute Process.alive?(first_worker)
    assert Instance.info(instance).operation_runners == %{}
    refute_receive {:example_flow_observed_event, :observation_silent, _, _}, 50

    assert {:ok, paused} = Spectre.pause_loop(instance, vigil_ref)
    assert paused.status == :paused

    assert {:error, {:loop_not_active, :paused}} =
             Spectre.trigger_loop(instance, vigil_ref, :external)

    assert {:ok, resumed} = Spectre.resume_loop(instance, vigil_ref)
    assert resumed.status == :waiting

    assert {:ok, triggered} =
             Spectre.trigger_loop(instance, vigil_ref, {:external, %{source: :test}},
               generation: resumed.trigger_generation
             )

    assert triggered.status == :queued

    assert_receive {:example_weather_observed, second_reading, second_attempt, second_worker},
                   1_000

    assert second_reading.alert
    assert second_reading.round == 1
    assert first_attempt.id != second_attempt.id
    assert first_attempt.fencing_token != second_attempt.fencing_token

    assert {:ok, waiting_again} =
             eventually_loop(instance, vigil_ref, &(&1.status == :waiting))

    assert waiting_again.observations == 2
    refute Process.alive?(second_worker)

    assert_receive {:example_flow_observed_event, :observation_significant, loop_id, event_id},
                   1_000

    assert loop_id == vigil_ref.id
    assert_flow_recorded(instance, event_id, :observation_significant, vigil_ref.id)

    assert {:ok, stopped} = Spectre.stop_loop(instance, vigil_ref, :example_complete)
    assert stopped.status == :terminal
    assert stopped.terminal_category == :cancelled
  end

  test "a failed Work is reported to the Flow without breaking later turns" do
    instance = start_instance()

    assert {:ok,
            %Turn{
              decision: {:reply, result},
              observable: {:reply, "failure probe started", _turn_ref}
            }} = Spectre.turn(instance, "fail work")

    assert %Ref{kind: :work} = work_ref = result.metadata.operation_ref
    assert_receive {:example_failure_started, :source_unavailable, attempt, worker}, 1_000
    assert attempt.retry_number == 0

    assert {:ok, failed} = eventually_loop(instance, work_ref, &(&1.status == :terminal))
    assert failed.terminal_category == :failed
    refute Process.alive?(worker)

    assert_receive {:example_flow_observed_event, :failed, loop_id, event_id}, 1_000
    assert loop_id == work_ref.id
    assert_flow_recorded(instance, event_id, :failed, work_ref.id)

    assert canonical_loop(instance, :work, work_ref).outcome.reason == :source_unavailable

    assert {:ok, %Turn{observable: {:reply, "pong", _ping_ref}}} =
             Spectre.turn(instance, "ping")
  end

  test "checkpoint recovery restores Flow, Work and Vigil together with fresh fencing" do
    subject = unique_subject("whole-system-recovery")
    instance = start_instance(subject: subject)

    assert {:ok, %Turn{decision: {:reply, work_result}}} =
             Spectre.turn(instance, "research")

    work_ref = work_result.metadata.operation_ref
    assert_receive {:example_page_started, 1, old_attempt, old_worker}, 1_000

    assert {:ok, %Turn{decision: {:reply, vigil_result}}} =
             Spectre.turn(instance, "watch rome")

    vigil_ref = vigil_result.metadata.operation_ref
    assert_receive {:example_weather_observed, %{round: 0}, _vigil_attempt, _vigil_worker}, 1_000
    assert {:ok, _waiting} = eventually_loop(instance, vigil_ref, &(&1.status == :waiting))

    flow_before_restart = Spectre.state(instance)
    assert flow_before_restart.revision >= 2

    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    child_id = {Instance, Instance.ref(instance).key}
    old_worker_monitor = Process.monitor(old_worker)
    assert :ok = stop_supervised(child_id)
    assert_receive {:DOWN, ^old_worker_monitor, :process, _pid, _reason}, 1_000

    restored = start_instance(subject: subject, canonical_checkpoint: checkpoint)

    assert Spectre.state(restored) == flow_before_restart

    assert_receive {:example_page_started, 1, recovered_attempt, recovered_worker}, 1_000
    assert recovered_attempt.id != old_attempt.id
    assert recovered_attempt.snapshot_id != old_attempt.snapshot_id
    assert recovered_attempt.fencing_token != old_attempt.fencing_token
    assert recovered_attempt.epoch != old_attempt.epoch

    assert {:ok, restored_vigil} = Spectre.loop(restored, vigil_ref)
    assert restored_vigil.status == :waiting
    assert restored_vigil.observations == 1
    refute_receive {:example_weather_observed, _, _, _}, 50

    assert {:ok, %Turn{observable: {:reply, "pong", _ping_ref}}} =
             Spectre.turn(restored, "ping")

    send(recovered_worker, {:release_example_page, 1})
    assert_receive {:example_page_started, 2, _second_attempt, _second_worker}, 1_000
    assert {:ok, completed} = eventually_loop(restored, work_ref, &(&1.status == :terminal))
    assert completed.terminal_category == :completed

    assert {:ok, _triggered} = Spectre.trigger_loop(restored, vigil_ref, :external)

    assert_receive {:example_weather_observed, %{round: 1, alert: true}, _attempt, _worker},
                   1_000

    assert {:ok, waiting_again} =
             eventually_loop(restored, vigil_ref, &(&1.status == :waiting))

    assert waiting_again.observations == 2

    assert_receive {:example_flow_observed_event, :completed, completed_loop_id, _event_id},
                   1_000

    assert completed_loop_id == work_ref.id

    assert_receive {:example_flow_observed_event, :observation_significant, vigil_loop_id,
                    _event_id},
                   1_000

    assert vigil_loop_id == vigil_ref.id
  end

  defp start_instance(extra \\ []) do
    {subject, extra} = Keyword.pop(extra, :subject, unique_subject("whole-system"))

    opts =
      [
        agent: @agent,
        subject: subject,
        idle: false,
        opts: [test_pid: self()]
      ]
      |> Keyword.merge(extra)

    start_supervised!({Instance, opts})
  end

  defp unique_subject(prefix) do
    Subject.new("#{prefix}-#{System.unique_integer([:positive, :monotonic])}")
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
      flunk("operational example did not reach the expected state")
    end
  end

  defp assert_flow_recorded(instance, event_id, type, loop_id) do
    assert_eventually(fn ->
      instance
      |> Spectre.state()
      |> Map.get(:data)
      |> Map.get(:operation_events, [])
      |> Enum.any?(&(&1.id == event_id and &1.type == type and &1.loop_id == loop_id))
    end)
  end

  defp canonical_loop(instance, section, ref) do
    assert {:ok, checkpoint} = Spectre.checkpoint(instance)
    assert {:ok, canonical} = Codec.decode(checkpoint)
    assert {:ok, loops} = Canonical.fetch(canonical, section)
    Map.fetch!(loops, ref.id)
  end

  defp expected_pages do
    [
      %{page: 1, title: "Page 1"},
      %{page: 2, title: "Page 2"},
      %{page: 3, title: "Page 3"}
    ]
  end

  defp assert_eventually(fun, attempts \\ 200)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
