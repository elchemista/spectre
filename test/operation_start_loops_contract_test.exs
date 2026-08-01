defmodule SpectreOperationStartLoopsContractTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Operation.Budget
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Runtime.StartLoops
  alias Spectre.Run.Value

  test "empty declarations are inert and malformed containers fail closed" do
    assert {:ok, []} = StartLoops.normalize(definition(), loop(), [])
    assert {:ok, []} = StartLoops.normalize(definition(), loop(), nil)

    assert {:error, {:invalid_operation_start_loops, %{intent: :child}}} =
             StartLoops.normalize(definition(), loop(), %{intent: :child})
  end

  test "valid intents keep order and derive deterministic child identities" do
    parent = loop()

    intents = [
      {:work, __MODULE__, %{page: 1},
       [intent_id: :first, expires_at: 50, metadata: %{source: :test}]},
      {:work, __MODULE__, %{page: 2},
       [intent_id: "second", id: "explicit-child", correlation_id: "explicit-correlation"]}
    ]

    assert {:ok, [first, second]} = StartLoops.normalize(definition(), parent, intents)

    assert first.intent_id == :first
    assert first.kind == :work
    assert first.controller == __MODULE__
    assert first.input == %{page: 1}
    assert first.opts[:expires_at] == 50
    assert first.opts[:metadata] == %{source: :test}
    refute Keyword.has_key?(first.opts, :intent_id)

    assert first.opts[:id] == Value.token("operation-loop", {parent.id, :first})

    assert first.opts[:correlation_id] ==
             Value.token("operation-correlation", {parent.id, :first})

    assert second.intent_id == "second"
    assert second.opts[:id] == "explicit-child"
    assert second.opts[:correlation_id] == "explicit-correlation"

    assert StartLoops.normalize(definition(), parent, intents) == {:ok, [first, second]}
  end

  test "the bounded declaration accepts 32 children and rejects the 33rd" do
    intents = Enum.map(1..32, &intent("child-#{&1}"))
    assert {:ok, normalized} = StartLoops.normalize(definition(), loop(), intents)
    assert length(normalized) == 32

    assert {:error, {:operation_start_loop_limit_exceeded, 32}} =
             StartLoops.normalize(definition(), loop(), intents ++ [intent("child-33")])
  end

  test "only explicitly authorized Directive definitions can start children" do
    unauthorized = %{definition() | can_start: []}

    assert {:error, {:operation_loop_start_not_authorized, :directive, :work}} =
             StartLoops.normalize(unauthorized, loop(), [intent(:child)])
  end

  test "malformed intents and option lists report their stable input index" do
    malformed = [
      {{:vigil, __MODULE__, %{}, [intent_id: :child]},
       {:invalid_operation_start_loop_intent, 0, {:vigil, __MODULE__, %{}, [intent_id: :child]}}},
      {{:work, nil, %{}, [intent_id: :child]},
       {:invalid_operation_start_loop_intent, 0, {:work, nil, %{}, [intent_id: :child]}}},
      {{:work, __MODULE__, %{}, [:not_keyword]}, {:invalid_operation_start_loop_options, 0}}
    ]

    Enum.each(malformed, fn {value, reason} ->
      assert {:error, ^reason} = StartLoops.normalize(definition(), loop(), [value])
    end)

    assert {:error, {:invalid_operation_start_loop_intent, 1, :broken}} =
             StartLoops.normalize(definition(), loop(), [intent(:valid), :broken])
  end

  test "missing identities, duplicate options and unsupported options fail closed" do
    Enum.each([nil, "", 42], fn intent_id ->
      assert {:error, {:operation_start_loop_intent_id_required, 0}} =
               StartLoops.normalize(definition(), loop(), [intent(intent_id)])
    end)

    assert {:error, {:duplicate_operation_start_loop_option, 0}} =
             StartLoops.normalize(definition(), loop(), [
               {:work, __MODULE__, %{}, [intent_id: :first, intent_id: :second]}
             ])

    assert {:error, {:unsupported_operation_start_loop_options, 0, [:visibility]}} =
             StartLoops.normalize(definition(), loop(), [
               {:work, __MODULE__, %{}, [intent_id: :child, visibility: :subject]}
             ])

    assert {:error, {:invalid_operation_start_loop_identity, 0, :id}} =
             StartLoops.normalize(definition(), loop(), [
               {:work, __MODULE__, %{}, [intent_id: :child, id: :not_portable_identity]}
             ])

    assert {:error, {:invalid_operation_start_loop_identity, 0, :correlation_id}} =
             StartLoops.normalize(definition(), loop(), [
               {:work, __MODULE__, %{}, [intent_id: :child, correlation_id: ""]}
             ])
  end

  test "duplicate logical and concrete child identities are rejected independently" do
    assert {:error, :duplicate_operation_start_loop_intent_id} =
             StartLoops.normalize(definition(), loop(), [intent(:same), intent(:same)])

    assert {:error, :duplicate_operation_start_loop_id} =
             StartLoops.normalize(definition(), loop(), [
               {:work, __MODULE__, %{}, [intent_id: :first, id: "same-child"]},
               {:work, __MODULE__, %{}, [intent_id: :second, id: "same-child"]}
             ])
  end

  test "nonportable nested input and options are rejected before Agent commit" do
    assert {:error, {:nonportable_operational_value, {:nonportable_run_value, input_path, :pid}}} =
             StartLoops.normalize(definition(), loop(), [
               {:work, __MODULE__, %{owner: self()}, [intent_id: :child]}
             ])

    assert :input in input_path

    assert {:error,
            {:nonportable_operational_value, {:nonportable_run_value, metadata_path, :pid}}} =
             StartLoops.normalize(definition(), loop(), [
               {:work, __MODULE__, %{}, [intent_id: :child, metadata: %{owner: self()}]}
             ])

    assert :opts in metadata_path
    assert :owner in metadata_path
  end

  property "arbitrary declaration envelopes always return a closed result and never raise" do
    check all(declarations <- declaration_envelope(), max_runs: 150) do
      result = StartLoops.normalize(definition(), loop(), declarations)

      assert match?({:ok, normalized} when is_list(normalized), result) or
               match?({:error, _reason}, result)
    end
  end

  defp intent(intent_id), do: {:work, __MODULE__, %{}, [intent_id: intent_id]}

  defp declaration_envelope do
    term = StreamData.resize(StreamData.term(), 6)

    candidate =
      StreamData.map(
        {term, term, term},
        fn {controller, input, opts} -> {:work, controller, input, opts} end
      )

    StreamData.one_of([
      term,
      StreamData.list_of(StreamData.one_of([term, candidate]), max_length: 12)
    ])
  end

  defp definition do
    %Definition{id: :parent_directive, version: 1, kind: :directive, can_start: [:work]}
  end

  defp loop do
    %Loop{
      id: "parent-loop",
      kind: :directive,
      controller: __MODULE__,
      controller_id: :parent_directive,
      controller_version: 1,
      base_input: %{},
      effective_input: %{},
      state: %{},
      subject_id: "subject",
      correlation_id: "parent-correlation",
      created_at: 1,
      updated_at: 1,
      budget: %Budget{}
    }
  end
end
