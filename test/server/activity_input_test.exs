defmodule Spectre.Server.ActivityInputTest do
  use ExUnit.Case, async: true

  alias Spectre.Server
  alias Spectre.Server.{Activities, Runtime}

  @timeout 5_000

  defmodule Report do
    use Spectre.Activity

    def handle_start(:selection_only, ctx),
      do: await_input(ctx, :document, prompt: "Which document?", timeout: :infinity)

    def handle_start(timeout, ctx) do
      await_input(ctx, :document,
        accept: ~r/^D\d+$/,
        prompt: "Which document?",
        timeout: timeout
      )
    end

    def handle_result(:document, {:ok, %Spectre.Input{text: id}}, ctx), do: complete(ctx, id)
    def handle_result(:document, {:error, reason}, ctx), do: fail(ctx, reason)

    def handle_result(:description, {:ok, %Spectre.Input{text: text}}, ctx),
      do: assign(ctx, :description, text)

    def handle_signal({:effect, _}, ctx), do: fail(ctx, :unexpected_effect)

    def handle_signal(:ask_description, ctx) do
      await_input(ctx, :description, prompt: "Describe the document", timeout: :infinity)
    end

    def handle_signal(signal, ctx), do: super(signal, ctx)
  end

  defmodule Stack do
    use Spectre.Stack
    activity(:report, Report)
  end

  defmodule Root do
    use Spectre.Server

    def handle_call({:report, timeout}, _from, ctx),
      do: {:reply, :ok, start_activity(ctx, :report, timeout)}

    def handle_call(message, from, ctx), do: super(message, from, ctx)
    def handle_flow({:chat, :ping}, _input, ctx), do: respond(ctx, "pong")
    def handle_flow({nil, :cancel}, _input, ctx), do: respond(ctx, "root interrupted")
    def handle_flow(flow, input, ctx), do: super(flow, input, ctx)
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: Root
    router(strategies: [:regex])
    interrupt(:cancel, regex: ~r/^cancel$/)

    flow :chat do
      on(:ping, regex: ~r/^ping$/)
    end
  end

  test "matching ordinary input resolves the focused Activity wait" do
    root = start_root()
    {ref, _target} = ask(root)

    assert {:ok, _} = Server.input(root, "D12")
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "D12"}}}, @timeout
  end

  test "a waiter yields unrelated chat and accepts only an authorized targeted answer" do
    root = start_root()
    {ref, target} = ask(root)

    assert {:ok, turn} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout

    unauthorized =
      Task.async(fn -> Server.input(root, "D12", activity: ref, pending: target) end)

    assert Task.await(unauthorized) == {:error, :activity_input_not_authorized}

    assert {:error, :reserved_activity_signal} =
             Server.signal_activity(root, ref, {:effect, {:governed, %{}}})

    assert {:ok, _} = Server.input(root, "D34", activity: ref, pending: target)
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "D34"}}}, @timeout

    assert {:error, :stale_pending} =
             Server.input(root, "D56", activity: ref, pending: target)
  end

  test "an expired wait reaches its Activity and rejects the old target" do
    root = start_root()
    {ref, target} = ask(root, 100)

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:failed, :expired}}}, @timeout

    assert {:error, :stale_pending} =
             Server.input(root, "D12", activity: ref, pending: target)
  end

  test "a wait without a matcher accepts only a targeted answer" do
    root = start_root()
    {ref, target} = ask(root, :selection_only)

    assert {:ok, turn} = Server.input(root, "D12")

    assert_receive {Server, ^root, {:response, ^turn, "I could not understand the request.", _}},
                   @timeout

    assert {:ok, _} = Server.input(root, "D34", activity: ref, pending: target)
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "D34"}}}, @timeout
  end

  test "an addressed Activity answer bypasses Root interrupts and history" do
    root = start_root()
    {ref, target} = ask(root, :selection_only)
    assert {:ok, turn} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout

    assert {:ok, answer} = Server.input(root, "cancel", activity: ref, pending: target)
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "cancel"}}}, @timeout

    assert [%{id: ^turn, user: "ping"}] = :sys.get_state(root).history
    refute_received {Server, ^root, {:response, ^answer, "root interrupted", _}}
  end

  test "a targeted-only question can coexist with the focused Activity question" do
    root = start_root()
    {ref, _document} = ask(root)
    assert {:ok, _} = Server.signal_activity(root, ref, :ask_description)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:waiting_input,
                      %{id: id, revision: revision, prompt: "Describe the document"}}}},
                   @timeout

    description = {id, revision}

    assert {:ok, _} =
             Server.input(root, "Annual report", activity: ref, pending: description)

    assert {:error, :stale_pending} =
             Server.input(root, "Duplicate", activity: ref, pending: description)

    assert {:ok, _} = Server.input(root, "D12")
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "D12"}}}, @timeout
  end

  test "addressed replies reject missing activity owners and require the Root transport" do
    root = start_root()

    assert {:error, :stale_pending} =
             Server.input(root, "answer", activity: "unknown", pending: {"missing", 1})

    {ref, target} = ask(root, :selection_only)
    coordinator = coordinator(root)

    assert {:error, :untrusted_activity_transport} =
             Activities.input(coordinator, {ref, target}, Spectre.Input.new("answer"))

    assert {:ok, _} = Server.input(root, "valid", activity: ref, pending: target)
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "valid"}}}, @timeout
  end

  test "an addressed input timeout permits a later answer from the Activity" do
    root = start_root()
    {ref, target} = ask(root, :selection_only)
    coordinator = coordinator(root)
    assert :ok = :sys.suspend(coordinator)

    try do
      assert {:error, :activity_input_outcome_unknown} =
               Server.input(root, "delayed reply", activity: ref, pending: target)
    after
      :sys.resume(coordinator)
    end

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "delayed reply"}}},
                   @timeout

    assert :sys.get_state(root).history == []
  end

  test "an uncertain focused reply is not also routed as a new Root conversation" do
    root = start_root()
    {ref, _target} = ask(root)
    coordinator = coordinator(root)
    assert :ok = :sys.suspend(coordinator)

    turn =
      try do
        assert {:ok, turn} = Server.input(root, "D12")

        assert_receive {Server, ^root,
                        {:activity_input_error, ^turn, {:error, :activity_input_outcome_unknown}}},
                       @timeout

        turn
      after
        :sys.resume(coordinator)
      end

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "D12"}}}, @timeout
    refute_received {Server, ^root, {:response, ^turn, _, _}}
  end

  test "queued answers from older checkpoints keep their exact target" do
    root = start_root()
    {ref, target} = ask(root, :selection_only)
    valid = legacy_activity_answer(ref, target, "cancel")
    stale = legacy_activity_answer(ref, {"stale", 1}, "duplicate")

    %{control: control} =
      :sys.replace_state(root, &%{&1 | queue: :queue.from_list([valid, stale])})

    send(root, {Runtime, control, :pump})
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "cancel"}}}, @timeout

    stale_id = stale.id

    assert_receive {Server, ^root, {:activity_input_error, ^stale_id, {:error, :stale_pending}}},
                   @timeout

    assert :sys.get_state(root).history == []
  end

  test "an in-flight answer restored by recovery keeps its exact target" do
    root = start_root()
    {ref, target} = ask(root, :selection_only)
    event = legacy_activity_answer(ref, target, "cancel")
    %{control: control} = :sys.replace_state(root, &%{&1 | current: event})

    send(root, {Runtime, control, :recover})
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, "cancel"}}}, @timeout
    assert :sys.get_state(root).history == []
  end

  defp start_root, do: start_supervised!({Server, agent: Agent, consumer: self()})

  defp coordinator(root) do
    %{activity_connection: {coordinator, _token}} = :sys.get_state(root)
    coordinator
  end

  defp legacy_activity_answer(ref, target, text) do
    %{
      id: Spectre.Identity.uuid7(),
      input: Spectre.Input.new(text),
      phase: :preparing,
      received_at: System.system_time(:millisecond),
      routing: %{},
      sequence: 1,
      steps: 0,
      target_activity: {ref, target},
      target_pending: nil
    }
  end

  defp ask(root, timeout \\ @timeout) do
    assert :ok = GenServer.call(root, {:report, timeout})

    assert_receive {Server, ^root,
                    {:activity, %{ref: ref},
                     {:waiting_input, %{id: id, revision: revision, prompt: "Which document?"}}}},
                   @timeout

    {ref, {id, revision}}
  end
end
