defmodule Spectre.Server.QuarantineReferenceTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.Failure

  test "a failed governed continuation retains durable fact references without copying its payload" do
    worker = %{command_id: "command:one", tag: :deleted}

    result = %{
      decision: %{ref: "decision:one"},
      act: %{ref: "act:one"},
      outcome: %{ref: "outcome:one", private_payload: "sensitive"}
    }

    state = state(%{"result:one" => %{worker: worker, result: {:governed, result}}})

    {next, failure} = Failure.quarantine(state, :handle_result, nil, %{kind: :exception})

    assert failure.source == %{
             command_id: "command:one",
             continuation: :deleted,
             decision_ref: "decision:one",
             act_ref: "act:one",
             outcome_ref: "outcome:one"
           }

    assert failure.interaction == nil
    assert next.inbox == %{}
    assert next.seen_events == %{"result:one" => true}
    refute inspect(failure) =~ "sensitive"
  end

  test "an uncertain governed result remains identifiable without inventing an Outcome reference" do
    result = %{decision: %{ref: "decision:one"}, act: %{ref: "act:one"}, outcome: nil}
    inbox = %{"result:one" => %{worker: %{tag: :deleted}, result: {:governed, result}}}
    {_state, failure} = Failure.quarantine(state(inbox), :handle_result, nil, :failed_callback)
    assert failure.source.outcome_ref == nil
    assert failure.source.act_ref == "act:one"
  end

  defp state(inbox) do
    %{
      processing_result: "result:one",
      inbox: inbox,
      dead_letters: %{},
      seen_events: %{},
      seen_event_order: [],
      opts: []
    }
  end
end
