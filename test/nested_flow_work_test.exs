defmodule NestedFlowWorkTest.QuickWork do
  @moduledoc false

  use Spectre.Work,
    id: :nested_quick_work,
    version: 1,
    input: :map,
    state: :map

  @impl true
  def init(input, _context), do: {:ok, %{input: input}}

  @impl true
  def next(state, _context), do: complete(state)

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(state, _context), do: complete(state)
end

defmodule NestedFlowWorkTest.Renderer do
  @moduledoc false

  def render(prompt, _input, _ctx), do: "reply:#{prompt}"
end

defmodule NestedFlowWorkTest.Agent do
  @moduledoc false

  use Spectre.Agent

  alias NestedFlowWorkTest.QuickWork
  alias NestedFlowWorkTest.Renderer

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :operations do
    on :OPERATIONS_HELP, regex: ~r/^operations help$/i do
      reply(:operations_help, renderer: {Renderer, :render})
    end

    flow :research do
      on :START_RESEARCH, regex: ~r/^start research$/i do
        work(QuickWork,
          input: %{topic: "nested flows"},
          origin: :chat,
          reply_text: "research started"
        )
      end
    end
  end

  interrupt :PING, regex: ~r/^ping$/i do
    reply(:pong, renderer: {Renderer, :render})
  end
end

defmodule NestedFlowWorkTest do
  use ExUnit.Case

  alias Spectre.Instance
  alias Spectre.Operation.Ref
  alias Spectre.Operation.View
  alias Spectre.Subject
  alias Spectre.Turn

  @agent NestedFlowWorkTest.Agent

  test "a work handler declared in a nested flow starts and completes a real Work" do
    instance = start_instance()

    assert {:ok,
            %Turn{
              decision: {:reply, start_result},
              observable: {:reply, "research started", _turn_ref}
            }} = Spectre.turn(instance, "start research")

    assert start_result.route.label == :START_RESEARCH
    assert start_result.route.flow == :research
    assert start_result.route.rule.flow_path == [:operations, :research]

    assert %Ref{kind: :work} = work_ref = start_result.metadata.operation_ref
    assert %View{definition: :nested_quick_work} = start_result.metadata.operation_view
    assert Enum.any?(start_result.events, &(&1.type == :work_started))

    assert {:ok, %View{status: :terminal, terminal_category: :completed}} =
             eventually_loop(instance, work_ref, &(&1.status == :terminal))
  end

  test "interrupts and sibling flows stay routable around the nested work flow" do
    instance = start_instance()

    assert {:ok, %Turn{observable: {:reply, "reply:pong", _ping_ref}}} =
             Spectre.turn(instance, "ping")

    assert {:ok, %Turn{decision: {:reply, help_result}}} =
             Spectre.turn(instance, "operations help")

    assert help_result.route.label == :OPERATIONS_HELP
    assert help_result.route.rule.flow_path == [:operations]
  end

  defp start_instance do
    subject = Subject.new("nested-flow-work-#{System.unique_integer([:positive, :monotonic])}")

    start_supervised!(
      {Instance, agent: @agent, subject: subject, idle: false, opts: [test_pid: self()]}
    )
  end

  defp eventually_loop(instance, ref, predicate, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_loop(instance, ref, predicate, deadline)
  end

  defp poll_loop(instance, ref, predicate, deadline) do
    case Spectre.loop(instance, ref) do
      {:ok, view} ->
        cond do
          predicate.(view) -> {:ok, view}
          System.monotonic_time(:millisecond) >= deadline -> {:error, {:timeout, view}}
          true -> retry(instance, ref, predicate, deadline)
        end

      {:error, _reason} = error ->
        if System.monotonic_time(:millisecond) >= deadline do
          error
        else
          retry(instance, ref, predicate, deadline)
        end
    end
  end

  defp retry(instance, ref, predicate, deadline) do
    Process.sleep(20)
    poll_loop(instance, ref, predicate, deadline)
  end
end
