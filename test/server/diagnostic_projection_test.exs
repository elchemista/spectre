defmodule Spectre.Server.DiagnosticProjectionTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.{Checkpoint, Command, Diagnostics}

  defp encoded(changes \\ %{}) do
    snapshot =
      Map.merge(%{version: 1, sequence: 1, pending: %{}, inbox: %{}, outbox: %{}}, changes)

    {:ok, bytes} = Checkpoint.encode_value(snapshot)
    bytes
  end

  test "projection accepts actual Command records without exposing their arguments" do
    bytes =
      encoded(%{
        outbox: %{
          "c1" => %{
            event: %{id: "i1", input: "PRIVATE INPUT"},
            command: %Command{
              kind: :generate,
              args: ["PRIVATE PROMPT"],
              opts: [on_result: :generated]
            }
          }
        }
      })

    assert {:ok, %{commands: [%{kind: :generate, tag: :generated}]} = result} =
             Diagnostics.checkpoint(bytes)

    refute inspect(result) =~ "PRIVATE"

    assert {:ok, %{total: 1, records: [%{command_id: "c1"}]} = trace} =
             Diagnostics.trace(bytes, "i1")

    refute inspect(trace) =~ "PRIVATE"
  end

  test "malformed nested records are rejected before projection" do
    for value <- [:invalid, [1, 2], %Command{kind: :generate, args: []}],
        field <- [:event, :worker] do
      bytes = encoded(%{outbox: %{command: %{field => value}}})
      assert {:error, :not_a_server_checkpoint} = Diagnostics.checkpoint(bytes)
      assert {:error, :not_a_server_checkpoint} = Diagnostics.trace(bytes, "i1")
    end

    for command <- [:invalid, %{opts: :invalid}] do
      bytes = encoded(%{outbox: %{command: %{command: command}}})
      assert {:error, :not_a_server_checkpoint} = Diagnostics.checkpoint(bytes)
    end
  end

  test "trace correlates retained worker results and operation continuations by original interaction" do
    bytes =
      encoded(%{
        operations: %{"operation" => %{event: %{id: "i1"}, tag: :operation_finished}},
        inbox: %{
          "inbox-key" => %{
            worker: %{command_id: "work-1", kind: :generate, tag: :generated, event: %{id: "i1"}},
            result: "PRIVATE RESULT"
          }
        },
        dead_letters: %{
          "dead-key" => %{
            interaction: "i1",
            source: %{command_id: "work-2", continuation: :inspected},
            reason: "PRIVATE FAILURE"
          }
        },
        outbox: %{"unrelated" => %{event: %{id: "i2"}}}
      })

    assert {:ok, %{total: 3, records: records, coverage: %{complete: false}} = result} =
             Diagnostics.trace(bytes, "i1")

    assert Enum.any?(records, &match?(%{collection: :operations, tag: :operation_finished}, &1))

    assert Enum.any?(
             records,
             &match?(%{collection: :inbox, command_id: "work-1", tag: :generated}, &1)
           )

    assert Enum.any?(
             records,
             &match?(%{collection: :dead_letters, command_id: "work-2", tag: :inspected}, &1)
           )

    refute inspect(result) =~ "PRIVATE"
    refute inspect(result) =~ "unrelated"
  end

  test "diagnostic options are closed and bounded" do
    for opts <- [[scope: :domain], [limit: 1, limit: 2], [limit: 1, admin: true], :invalid] do
      assert {:error, :invalid_diagnostic_options} = Diagnostics.checkpoint(encoded(), opts)
      assert {:error, :invalid_diagnostic_options} = Diagnostics.trace(encoded(), "i1", opts)
    end

    for limit <- [0, 101, :infinity] do
      assert {:error, :invalid_diagnostic_limit} = Diagnostics.checkpoint(encoded(), limit: limit)
    end
  end

  defmodule UnavailableStore do
    def fetch(_, _), do: {:error, :temporarily_unavailable}
  end

  @tag :tmp_dir
  test "missing storage and malformed retained data fail closed without diagnostic payloads", %{
    tmp_dir: path
  } do
    assert {:error, :server_checkpoint_required} = Diagnostics.read(%{opts: []}, [])
    store = start_supervised!({Spectre.Server.Store.Disk, path: Path.join(path, "checkpoint")})
    state = %{opts: [checkpoint: {store, :missing}]}
    assert {:error, :checkpoint_not_found} = Diagnostics.read(state, [])

    assert {:error, :temporarily_unavailable} =
             Diagnostics.read(%{opts: [checkpoint: {UnavailableStore, store, :missing}]}, [])

    for interaction <- [nil, "", String.duplicate("x", 257)] do
      assert {:error, :invalid_interaction_id} = Diagnostics.trace(encoded(), interaction)
    end

    assert {:error, _} = Diagnostics.checkpoint("not a checkpoint")

    assert {:error, :not_a_server_checkpoint} =
             Diagnostics.checkpoint(encoded(%{outbox: %{bad: 1}}))

    bytes =
      encoded(%{
        current: %{routing: %{checkpoint_route: %{kind: :portable, value: %{strategy: :regex}}}},
        outbox: %{"safe" => %{tag: %{secret: "PRIVATE"}}}
      })

    assert {:ok, %{routing: %{strategy: :regex}, commands: [%{tag: nil}]} = view} =
             Diagnostics.checkpoint(bytes)

    refute inspect(view) =~ "PRIVATE"
  end

  test "routing projects actual nested and Skill dispatch keys and saved strategy attributes" do
    for {key, expected} <- [
          {{[:support, :billing], "PRICING"}, [[:support, :billing], "PRICING"]},
          {{{{:skill, :research}, :outreach}, :new_link},
           [[[:skill, :research], :outreach], :new_link]}
        ] do
      bytes =
        encoded(%{
          current: %{
            id: "i1",
            routing: %{
              route_key: key,
              checkpoint_route: %{
                kind: :definition_rule,
                attributes: %{strategy: :semantic, scores: "PRIVATE"}
              }
            }
          }
        })

      assert {:ok, %{routing: %{route: ^expected, strategy: :semantic}} = result} =
               Diagnostics.checkpoint(bytes)

      refute inspect(result) =~ "PRIVATE"
    end
  end
end
