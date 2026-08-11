defmodule SpectreRunCodecEdgeContractTest.Agent do
  @moduledoc false
  use Spectre.Agent, id: :run_codec_contract_agent
end

defmodule SpectreRunCodecEdgeContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Execution.Closure
  alias Spectre.Input
  alias Spectre.Input.Source
  alias Spectre.Run
  alias Spectre.Run.Codec
  alias Spectre.Run.Ref
  alias Spectre.Run.Request
  alias Spectre.Run.Value
  alias Spectre.State
  alias SpectreRunCodecEdgeContractTest.Agent

  test "new Runs are pinned to the sealed canonical Definition without a legacy fallback" do
    run = Run.new(Agent, %Input{}, %State{})
    canonical = Definition.canonical!(Agent)
    manifest = Definition.manifest!(Agent)

    assert run.definition_ref == Canonical.ref(canonical)
    assert run.closure_digest == Closure.digest(manifest.execution_closure)
    refute run.definition_ref == Run.legacy_definition_ref(Agent)

    assert_raise ArgumentError, ~r/cannot seal compiled Definition/, fn ->
      Run.new(__MODULE__, %Input{}, %State{})
    end
  end

  test "Run options and identifiers fail closed for non-portable values" do
    assert Run.version() == 2
    assert :ok = Run.validate_options([])
    assert :ok = Run.validate_options(run_id: nil, trace_id: nil)
    assert {:error, {:invalid_run_option, :run_id, :empty}} = Run.validate_options(run_id: "")

    assert {:error, {:invalid_run_option, :trace_id, {:nonportable_run_value, _, :pid}}} =
             Run.validate_options(trace_id: self())

    assert {:error, {:invalid_run_option, :run_metadata, :not_a_map}} =
             Run.validate_options(run_metadata: :invalid)

    assert {:error, {:invalid_run_option, :run_metadata, {:nonportable_run_value, _, :pid}}} =
             Run.validate_options(run_metadata: %{client: self()})

    assert %Run{metadata: %{}} =
             Run.new(Agent, %Input{}, %State{}, run_metadata: :invalid)

    assert %Run{id: "run:" <> _, trace_id: "trace:" <> _} =
             Run.new(Agent, %Input{}, %State{},
               run_id: {:tenant, 42},
               trace_id: {:trace, 7}
             )
  end

  test "Run references are stable, revision-fenced, and privacy-safe" do
    ref = Ref.new("run-1", 2, :policy, "boundary-1", {:effect, 7})
    same = Ref.new("run-1", 2, :policy, "boundary-1", {:effect, 7})
    next_revision = Ref.new("run-1", 3, :policy, "boundary-1", {:effect, 7})

    assert "subject:" <> _ = ref.subject_id
    assert "run:" <> _ = Ref.token(ref)
    assert Ref.token(ref) == Ref.token(same)
    refute Ref.token(ref) == Ref.token(next_revision)

    assert_raise ArgumentError, ~r/non-portable Run reference subject/, fn ->
      Ref.new("run-1", 2, :policy, "boundary-1", self())
    end
  end

  test "policy request projection exposes only portable logical data" do
    awaitable =
      Awaitable.open_policy(:confirmation, {:effect, 7},
        id: {:request, 3},
        max_attempts: 2,
        metadata: %{locale: "it"}
      )

    assert %Request{
             id: "request:" <> _,
             subject_id: "subject:" <> _,
             name: :confirmation,
             metadata: %{locale: "it"}
           } = Request.from_awaitable(awaitable)

    assert %Request{metadata: %{}} =
             awaitable
             |> Map.put(:metadata, %{client: self()})
             |> Request.from_awaitable()

    assert %Request{metadata: %{}} =
             awaitable
             |> Map.put(:metadata, :invalid)
             |> Request.from_awaitable()

    assert_raise ArgumentError, ~r/non-portable Run request/, fn ->
      awaitable
      |> Map.put(:id, self())
      |> Request.from_awaitable()
    end

    assert_raise ArgumentError, ~r/non-portable Run request/, fn ->
      awaitable
      |> Map.put(:name, self())
      |> Request.from_awaitable()
    end
  end

  test "logical input projection strips transport handles without losing safe siblings" do
    input = %Input{
      text: "hello",
      raw: self(),
      meta: %{
        list: [1, self(), 2],
        tuple: {:unsafe, self()},
        nested: %{safe: true, pid: self()},
        struct: %Source{kind: :nested, metadata: %{pid: self()}}
      },
      source: %Source{
        kind: :test,
        mount: {:channel, 1},
        conversation_id: self(),
        actor_id: "actor-1",
        reply_to: %{chat: "chat-1", pid: self()},
        metadata: %{locale: "it", client: self()}
      }
    }

    projected = Codec.logical_input(input)

    assert projected.raw == nil
    assert projected.meta.list == [1, 2]
    assert projected.meta.nested == %{safe: true}
    refute Map.has_key?(projected.meta, :tuple)
    refute Map.has_key?(projected.meta, :struct)
    assert projected.source.mount == {:channel, 1}
    assert projected.source.conversation_id == nil
    assert projected.source.actor_id == "actor-1"
    assert projected.source.reply_to == nil
    assert projected.source.metadata == %{locale: "it"}
  end

  test "checkpoint bounds and envelope versions are enforced" do
    run = initial_run()

    assert {:error, {:run_checkpoint_too_large, encoded_size, 1}} =
             Run.checkpoint(run, max_bytes: 1)

    assert encoded_size > 1
    assert {:ok, checkpoint} = Run.checkpoint(run)

    assert {:error, {:run_checkpoint_too_large, restored_size, 1}} =
             Run.restore(checkpoint, max_bytes: 1)

    assert restored_size == byte_size(checkpoint)
    assert {:error, :invalid_run_checkpoint} = Run.restore(<<0, 1, 2>>)

    unsupported =
      :erlang.term_to_binary(%{
        "format" => "spectre/run",
        "version" => 3,
        "run" => nil
      })

    assert {:error, {:unsupported_run_checkpoint_version, 3, [1, 2]}} =
             Run.restore(unsupported)

    invalid = :erlang.term_to_binary(%{"format" => "other", "version" => 1, "run" => nil})
    assert {:error, :invalid_run_checkpoint} = Run.restore(invalid)

    assert {:error, {:unsupported_run_version, 3, [2]}} =
             Run.checkpoint(%{run | run_version: 3})

    assert {:ok, _checkpoint} = Run.checkpoint(run, [:ignored_non_keyword_entry])
  end

  test "checkpoint validates every Run structural boundary" do
    run = initial_run()

    assert {:error, :invalid_run_position} =
             Run.checkpoint(%{run | status: :unknown})

    assert {:error, :invalid_run_revision} =
             Run.checkpoint(%{run | revision: -1})

    assert {:error, :invalid_run_lineage} =
             Run.checkpoint(%{run | causation_id: self()})

    assert {:error, :invalid_run_metadata} =
             Run.checkpoint(%{run | metadata: :invalid})

    invalid_run = %{run | input: :invalid}

    assert {:error, {:run_checkpoint_encode_failed, FunctionClauseError}} =
             Run.checkpoint(invalid_run)

    assert {:ok, encoded_run} = Value.encode(invalid_run)

    invalid_checkpoint =
      :erlang.term_to_binary(%{
        "format" => "spectre/run",
        "version" => 2,
        "run" => encoded_run
      })

    assert {:error, :invalid_run} = Run.restore(invalid_checkpoint)
  end

  test "Run value encoding round-trips tagged atoms, tuples, maps, lists, and structs" do
    value = %{
      atom: :ok,
      tuple: {:answer, 42},
      list: [true, nil, %Input{text: "hello"}],
      nested: %{"locale" => "it"}
    }

    assert {:ok, encoded} = Value.encode(value)
    assert :ok = Value.prepare(encoded)
    assert {:ok, ^value} = Value.decode(encoded)

    assert {:ok, %{"answer" => :ok}} =
             Value.decode(%{
               "answer" => %{"$spectre" => "atom", "value" => "ok"}
             })

    assert Value.logical_id(nil) == nil
    assert Value.logical_id("logical-id") == "logical-id"
    assert "logical:" <> _ = Value.logical_id({:logical, 1})
    assert Value.logical_id(self()) == nil
    assert {:ok, nil} = Value.opaque_id(nil)
    assert {:error, {:nonportable_run_value, [], :pid}} = Value.opaque_id(self())
  end

  test "Run value codec rejects handles and malformed tagged values" do
    port = Port.open({:spawn_executable, System.find_executable("cat")}, [:binary])
    on_exit(fn -> if Port.info(port), do: Port.close(port) end)

    rejected = [
      {self(), :pid},
      {port, :port},
      {make_ref(), :reference},
      {fn -> :ok end, :function}
    ]

    for {value, kind} <- rejected do
      assert {:error, {:nonportable_run_value, [], ^kind}} = Value.validate(value)
      assert {:error, {:unsupported_run_value, ^kind}} = Value.encode(value)
      assert {:error, {:invalid_encoded_run_value, ^kind}} = Value.decode(value)
    end

    assert {:error, {:unknown_run_atom, "spectre_atom_that_must_not_exist_013"}} =
             Value.decode(%{
               "$spectre" => "atom",
               "value" => "spectre_atom_that_must_not_exist_013"
             })

    assert {:error, {:unknown_run_value_tag, "future"}} =
             Value.decode(%{"$spectre" => "future"})

    assert {:error, :invalid_encoded_run_map_entry} =
             Value.decode(%{"$spectre" => "map", "entries" => [:invalid]})

    assert {:error, {:invalid_run_struct_fields, "Elixir.Spectre.Input"}} =
             Value.decode(%{
               "$spectre" => "struct",
               "module" => "Elixir.Spectre.Input",
               "fields" => 1
             })

    assert {:error, {:unknown_run_module, "Elixir.Spectre.DoesNotExist"}} =
             Value.prepare(%{
               "$spectre" => "struct",
               "module" => "Elixir.Spectre.DoesNotExist",
               "fields" => %{}
             })
  end

  defp initial_run do
    Run.new(Agent, %Input{text: "hello"}, %State{},
      run_id: "run-1",
      trace_id: "trace-1"
    )
  end
end
