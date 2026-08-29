defmodule SpectreRunCodecEdgeContractTest.Agent do
  @moduledoc false
  use Spectre.Agent, id: :run_codec_contract_agent

  router(via: [:regex], semantic_cache?: false, classification_log?: false)

  flow :codec_edges do
    on :HELLO, regex: ~r/^hello$/ do
      run(:hello)
    end
  end

  def hello(_input, _context), do: "hello"
end

defmodule SpectreRunCodecEdgeContractTest.Model do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_plan, _opts), do: {:ok, "inference"}
end

defmodule SpectreRunCodecEdgeContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Definition
  alias Spectre.Definition.Canonical
  alias Spectre.Execution.Closure
  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Request, as: InferenceRequest
  alias Spectre.Input
  alias Spectre.Input.Source
  alias Spectre.Run
  alias Spectre.Run.Codec
  alias Spectre.Run.Ref
  alias Spectre.Run.Request
  alias Spectre.Run.Value
  alias Spectre.Instance.Runs
  alias Spectre.Prompt.Plan
  alias Spectre.Runtime
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
    assert Run.version() == 3
    assert :ok = Run.validate_options([])
    assert :ok = Run.validate_options(run_id: nil, trace_id: nil)
    assert {:error, {:invalid_run_option, :run_id, :empty}} = Run.validate_options(run_id: "")

    assert {:error, {:invalid_run_option, :trace_id, {:nonportable_run_value, _, :pid}}} =
             Run.validate_options(trace_id: self())

    assert {:error, {:invalid_run_option, :run_metadata, :not_a_map}} =
             Run.validate_options(run_metadata: :invalid)

    assert {:error, {:invalid_run_option, :run_metadata, {:nonportable_run_value, _, :pid}}} =
             Run.validate_options(run_metadata: %{client: self()})

    for key <- [:stack_runtime, :memory_engine, :instance_pid, :runtime_client] do
      assert {:error, {:invalid_run_option, :run_metadata, {:runtime_handle_key_forbidden, ^key}}} =
               Run.validate_options(run_metadata: %{key => :runtime_name})

      assert {:error, {:invalid_run_option, :run_metadata, {:runtime_handle_key_forbidden, ^key}}} =
               Run.validate_options(run_metadata: %{Atom.to_string(key) => :runtime_name})
    end

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
        "version" => 4,
        "run" => nil
      })

    assert {:error, {:unsupported_run_checkpoint_version, 4, [1, 2, 3]}} =
             Run.restore(unsupported)

    invalid = :erlang.term_to_binary(%{"format" => "other", "version" => 1, "run" => nil})
    assert {:error, :invalid_run_checkpoint} = Run.restore(invalid)

    assert {:error, {:unsupported_run_version, 4, [3]}} =
             Run.checkpoint(%{run | run_version: 4})

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
        "version" => 3,
        "run" => encoded_run
      })

    assert {:error, :invalid_run} = Run.restore(invalid_checkpoint)

    assert {:ok, encoded_value} = Value.encode(:not_a_run)

    non_run_checkpoint =
      :erlang.term_to_binary(%{
        "format" => "spectre/run",
        "version" => 3,
        "run" => encoded_value
      })

    assert {:error, :invalid_run} = Run.restore(non_run_checkpoint)
  end

  test "reply, completion, failure, and inference checkpoints reject forged boundary lineage" do
    assert {:continue, started} = Runtime.start(Agent, "hello")
    assert {:boundary, %Spectre.Run.Boundary{} = boundary, replied} = Runtime.advance(started)
    assert {:complete, _result, completed} = Runtime.advance(replied)

    assert {:ok, _checkpoint} = Run.checkpoint(replied)
    assert {:ok, _checkpoint} = Run.checkpoint(completed)

    mapped_route = %{completed.result | route: %{label: :HELLO, strategy: :regex}}
    assert {:ok, _checkpoint} = Run.checkpoint(%{completed | result: mapped_route})

    wrong_output = %{replied | waiting: %{boundary | output: "different"}}
    assert {:error, :invalid_run_reply_boundary} = Run.checkpoint(wrong_output)

    stale_result_ref = %{get_in(replied.result.metadata, [:run, :ref]) | run_id: "foreign"}

    stale_metadata = put_in(replied.result.metadata, [:run, :ref], stale_result_ref)
    stale_result = %{replied.result | metadata: stale_metadata}

    assert {:error, :invalid_run_reference} =
             Run.checkpoint(%{replied | result: stale_result})

    complete_ref = get_in(completed.result.metadata, [:run, :ref])
    wrong_complete_ref = %{complete_ref | kind: :reply}

    wrong_completion_metadata =
      put_in(completed.result.metadata, [:run, :ref], wrong_complete_ref)

    wrong_completion = %{completed.result | metadata: wrong_completion_metadata}

    assert {:error, :invalid_run_completion} =
             Run.checkpoint(%{completed | result: wrong_completion})

    failed = Runs.terminalize_failed_run(replied, :provider_failed)
    assert {:ok, _checkpoint} = Run.checkpoint(failed)

    wrong_failure_input = %{failed.result | input: Input.new("different")}

    assert {:ok, normalized_failure_checkpoint} =
             Run.checkpoint(%{failed | result: wrong_failure_input})

    assert {:ok, normalized_failure} = Run.restore(normalized_failure_checkpoint)
    assert normalized_failure.result.input == normalized_failure.input

    assert {:error, :invalid_run_failure} = Run.checkpoint(%{failed | last_error: nil})

    inference_request = inference_request()

    assert {:ok, inference_run} =
             Runtime.admit_inference(Agent, inference_request, "inference", %State{})

    assert {:dispatch, invocation, inference_awaiting, _prepared} =
             Runtime.prepare_inference(inference_run, inference_request,
               model: SpectreRunCodecEdgeContractTest.Model
             )

    assert {:ok, _checkpoint} = Run.checkpoint(inference_awaiting)

    invalid_fence = %{invocation | control_revision: -1}

    assert {:error, :invalid_invocation_control_revision} =
             Run.checkpoint(%{inference_awaiting | waiting: invalid_fence})

    valid_but_different = %{
      invocation
      | metadata: Map.put(invocation.metadata, :test_projection, true)
    }

    assert {:error, :invalid_run_inference_boundary} =
             Run.checkpoint(%{inference_awaiting | waiting: valid_but_different})
  end

  test "checkpoint restore migrates v2 continuations and detects envelope schema drift" do
    run = initial_run()
    legacy_ready = %{run | run_version: 2, start_continuation: nil}

    assert {:ok, restored_ready} =
             legacy_ready
             |> checkpoint_envelope(2)
             |> Run.restore()

    assert restored_ready.run_version == 3
    refute restored_ready.start_continuation.recoverable?

    assert restored_ready.start_continuation.reason ==
             :legacy_ready_run_without_start_continuation

    legacy_failed = %{
      run
      | run_version: 2,
        status: :failed,
        cursor: :complete,
        revision: 1,
        step_id: "legacy-failed",
        start_continuation: nil,
        last_error: :legacy_failure
    }

    assert {:ok, %{start_continuation: nil, status: :failed}} =
             legacy_failed
             |> checkpoint_envelope(2)
             |> Run.restore()

    mismatch = %{run | run_version: 1}

    assert {:error, {:run_checkpoint_schema_mismatch, 2, 1}} =
             mismatch
             |> checkpoint_envelope(2)
             |> Run.restore()
  end

  test "decoded Runs validate source, continuation, and result identity defensively" do
    run = initial_run()

    assert {:error, _reason} =
             Run.checkpoint(%{run | input: %{run.input | source: :invalid}})

    assert {:error, :invalid_run_start_continuation} =
             run
             |> Map.put(:start_continuation, :invalid)
             |> checkpoint_envelope(3)
             |> Run.restore()

    assert {:error, :invalid_run_inference_continuation} =
             run
             |> Map.put(:inference_continuation, :invalid)
             |> checkpoint_envelope(3)
             |> Run.restore()

    mismatched_start = %{
      run.start_continuation
      | input: %{run.input | text: "different logical input"}
    }

    assert {:error, :run_start_continuation_input_mismatch} =
             run
             |> Map.put(:start_continuation, mismatched_start)
             |> checkpoint_envelope(3)
             |> Run.restore()

    assert {:error, :missing_run_start_continuation} =
             run
             |> Map.put(:start_continuation, nil)
             |> checkpoint_envelope(3)
             |> Run.restore()

    assert {:continue, started} = Runtime.start(Agent, "no matching route")
    assert {:complete, _result, complete} = Runtime.advance(started)

    invalid_identity = %{complete.result | metadata: %{}}

    assert {:error, :invalid_run_result_identity} =
             Run.checkpoint(%{complete | result: invalid_identity})
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
    opts = [run_id: "run-1", trace_id: "trace-1"]
    {:ok, run} = Runtime.admit(Agent, %Input{text: "hello"}, %State{}, opts, opts)
    run
  end

  defp inference_request do
    {:ok, plan} = Plan.compose("infer", [], [:agent])

    InferenceRequest.new(
      id: "codec-inference",
      purpose: :cognitive_operation,
      plan: plan,
      constraints: %Constraints{},
      metadata: %{
        model: SpectreRunCodecEdgeContractTest.Model,
        llm_opts: [model: SpectreRunCodecEdgeContractTest.Model],
        explicit_model_override?: true
      }
    )
  end

  defp checkpoint_envelope(run, version) do
    {:ok, encoded_run} = Value.encode(run)

    :erlang.term_to_binary(
      %{"format" => "spectre/run", "version" => version, "run" => encoded_run},
      [:deterministic]
    )
  end
end
