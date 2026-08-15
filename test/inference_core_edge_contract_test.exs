defmodule SpectreInferenceCoreEdgeContractTest.Source do
  @moduledoc false

  @behaviour Spectre.Determinism.Source

  @impl Spectre.Determinism.Source
  def system_time(_unit, opts), do: Keyword.get(opts, :system_time, 42)

  @impl Spectre.Determinism.Source
  def monotonic_time(_unit, opts), do: Keyword.get(opts, :monotonic_time, -42)

  @impl Spectre.Determinism.Source
  def random_bytes(count, opts) do
    opts
    |> Keyword.get(:random_bytes, <<0, 1, 2, 3, 4, 5, 6, 7>>)
    |> binary_part(0, count)
  end
end

defmodule SpectreInferenceCoreEdgeContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"
end

defmodule SpectreInferenceCoreEdgeContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Determinism
  alias Spectre.Effect
  alias Spectre.Inference.Budget
  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.Event
  alias Spectre.Inference.Events
  alias Spectre.Inference.Failure
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.IncrementalSanitizer
  alias Spectre.Inference.Profile
  alias Spectre.Inference.Progress
  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Inference.Selection
  alias Spectre.Inference.StreamEvent
  alias Spectre.Input
  alias Spectre.Input.Source, as: InputSource
  alias Spectre.Invocation
  alias Spectre.Prompt.Plan
  alias Spectre.Route
  alias Spectre.Run
  alias Spectre.Run.InferenceContinuation
  alias Spectre.Run.Value, as: RunValue
  alias Spectre.State
  alias Spectre.Subject

  @source SpectreInferenceCoreEdgeContractTest.Source
  @agent SpectreInferenceCoreEdgeContractTest.Agent

  describe "the deterministic boundary port" do
    test "uses normal clock and random sources outside an active capture" do
      assert is_integer(Determinism.system_time(:millisecond))
      assert is_integer(Determinism.monotonic_time(:native))
      assert byte_size(Determinism.random_bytes(3)) == 3
      assert Determinism.samples() == []
    end

    test "accepts module sources, restores nested sources, and ignores invalid limits" do
      {outer_values, outer_samples} =
        Determinism.capture(
          [determinism_source: {@source, system_time: 10}, determinism_sample_limit: 0],
          fn ->
            before = Determinism.system_time()

            {inner, inner_samples} =
              Determinism.capture([determinism_source: {@source, system_time: 20}], fn ->
                Determinism.system_time()
              end)

            after_inner = Determinism.system_time()
            {before, inner, inner_samples, after_inner}
          end
        )

      assert {10, 20, [%{kind: :system_time, value: 20}], 10} = outer_values
      assert Enum.map(outer_samples, & &1.value) == [10, 10]

      assert {-42, []} =
               Determinism.capture([determinism_source: @source], fn ->
                 Determinism.monotonic_time()
               end)
    end

    test "replay accepts persisted string keys without creating atoms" do
      replay = [
        %{
          "sequence" => 1,
          "kind" => "system_time",
          "request" => %{"unit" => :millisecond},
          "value" => 123
        },
        %{
          "sequence" => 2,
          "kind" => "random_bytes",
          "request" => %{"count" => 2},
          "value" => <<7, 8>>
        }
      ]

      assert {{123, <<7, 8>>}, samples} =
               Determinism.capture([determinism_replay: replay], fn ->
                 {Determinism.system_time(), Determinism.random_bytes(2)}
               end)

      assert Enum.map(samples, & &1.kind) == [:system_time, :random_bytes]
    end

    test "replay rejects non-map and unknown request evidence without atom creation" do
      non_map_request = %{
        sequence: 1,
        kind: :system_time,
        request: :invalid,
        value: 1
      }

      assert_raise ArgumentError, ~r/determinism replay mismatch/, fn ->
        Determinism.capture([determinism_replay: [non_map_request]], fn ->
          Determinism.system_time()
        end)
      end

      unknown_key = %{
        "sequence" => 1,
        "kind" => "system_time",
        "request" => %{"unit" => :millisecond, "future_key" => true},
        "value" => 1
      }

      assert_raise ArgumentError, ~r/determinism replay mismatch/, fn ->
        Determinism.capture([determinism_replay: [unknown_key]], fn ->
          Determinism.system_time()
        end)
      end
    end

    test "fails closed for incomplete, exhausted, malformed, or oversized evidence" do
      sample = %{sequence: 1, kind: :system_time, request: %{unit: :millisecond}, value: 1}

      assert_raise ArgumentError, ~r/unused samples/, fn ->
        Determinism.capture([determinism_replay: [sample]], fn -> :no_sample end)
      end

      assert_raise ArgumentError, ~r/replay exhausted/, fn ->
        Determinism.capture([determinism_replay: []], fn -> Determinism.system_time() end)
      end

      assert_raise ArgumentError, ~r/invalid determinism replay sample/, fn ->
        Determinism.capture([determinism_replay: [:invalid]], fn ->
          Determinism.system_time()
        end)
      end

      assert_raise ArgumentError, ~r/sample limit exceeded/, fn ->
        Determinism.capture(
          [determinism_source: @source, determinism_sample_limit: 1],
          fn ->
            Determinism.system_time()
            Determinism.random_bytes(1)
          end
        )
      end
    end

    test "rejects invalid sources and non-portable samples" do
      assert_raise ArgumentError, ~r/invalid determinism source/, fn ->
        Determinism.capture([determinism_source: {self(), []}], fn -> :unused end)
      end

      assert_raise ArgumentError, ~r/non-portable determinism sample/, fn ->
        Determinism.capture([determinism_source: {@source, system_time: self()}], fn ->
          Determinism.system_time()
        end)
      end
    end
  end

  describe "the incremental sanitizer state machine" do
    test "rejects unsafe lookahead settings and bounds line-prefix ambiguity" do
      assert_raise ArgumentError, ~r/lookahead must be at least 16 bytes/, fn ->
        IncrementalSanitizer.new(max_sanitizer_lookahead_bytes: 15)
      end

      state = IncrementalSanitizer.new(max_sanitizer_lookahead_bytes: 16)

      assert {:error, :sanitizer_lookahead_exceeded} =
               IncrementalSanitizer.push(state, String.duplicate(" ", 17))
    end

    test "finishes transparent buffers and safely discards incomplete control blocks" do
      transparent = %{
        IncrementalSanitizer.new(sanitize_reply: false)
        | buffer: "buffered"
      }

      assert {:ok, "buffered", %{buffer: ""}} = IncrementalSanitizer.finish(transparent)

      assert {:ok, "", state} =
               IncrementalSanitizer.push(IncrementalSanitizer.new(), "<!-- private")

      assert {:ok, "", %{buffer: ""}} = IncrementalSanitizer.finish(state)

      assert {:ok, "", state} =
               IncrementalSanitizer.push(IncrementalSanitizer.new(), "<think>private")

      assert {:ok, "", %{buffer: ""}} = IncrementalSanitizer.finish(state)
    end

    test "handles nested tags, fragments, literals, comments, and new lines incrementally" do
      input =
        "start<think>secret<al>nested</al><!-- hidden --><reply>also hidden</reply>" <>
          "</think>visible<unknown>tag</unknown>\nnext"

      assert {:ok, output, state} =
               IncrementalSanitizer.push(IncrementalSanitizer.new(), input)

      assert {:ok, trailing, _state} = IncrementalSanitizer.finish(state)
      assert output <> trailing == "startvisible<unknown>tag</unknown>\nnext"

      assert {:ok, "prefix", state} =
               IncrementalSanitizer.push(IncrementalSanitizer.new(), "prefix<th")

      assert {:ok, "", %{buffer: ""}} = IncrementalSanitizer.finish(state)

      assert {:ok, "visible\n", state} =
               IncrementalSanitizer.push(
                 IncrementalSanitizer.new(),
                 "visible\n  intent: discard"
               )

      assert {:ok, "next", _state} = IncrementalSanitizer.push(state, "\nnext")
    end
  end

  describe "portable inference descriptors" do
    test "projects only portable recovery data and records opt-out reasons" do
      request = request("descriptor")

      descriptor =
        Descriptor.from_request(
          %{request | metadata: %{flow_constraints: self(), required_profile_ref: :profile}},
          route: :runtime_route,
          sanitize_reply: self()
        )

      assert descriptor.route == nil
      assert descriptor.options == %{}
      assert descriptor.metadata == %{}
      refute descriptor.recoverable?
      assert descriptor.recovery_reason == :runtime_descriptor_options_not_portable

      explicit =
        Descriptor.from_request(request, recoverable?: false, recovery_reason: :host_choice)

      refute explicit.recoverable?
      assert explicit.recovery_reason == :host_choice
    end

    test "normalizes malformed optional request projections and sorts options" do
      request = %{request("normalized") | purpose: "runtime", metadata: self()}

      descriptor =
        Descriptor.from_request(request,
          route: %Route{label: :selected, strategy: :deterministic},
          streaming?: true,
          sanitize_reply: true
        )

      assert descriptor.purpose == :inference
      assert descriptor.metadata == %{}
      assert descriptor.route.label == :selected
      assert Descriptor.options(descriptor) == [sanitize_reply: true, streaming?: true]
    end

    test "validates every durable descriptor invariant" do
      descriptor = Descriptor.from_request(request("valid-descriptor"))

      invalid = [
        {%{descriptor | id: ""}, :invalid_inference_descriptor_id},
        {%{descriptor | purpose: nil}, :invalid_inference_descriptor_purpose},
        {%{descriptor | plan: nil}, :invalid_inference_descriptor_plan},
        {%{descriptor | constraints: nil}, :invalid_inference_descriptor_constraints},
        {%{descriptor | route: :invalid}, :invalid_inference_descriptor_route},
        {%{descriptor | modalities: ["text"]}, :invalid_inference_descriptor_modalities},
        {%{descriptor | options: %URI{}}, :invalid_inference_descriptor_metadata},
        {%{descriptor | metadata: []}, :invalid_inference_descriptor_metadata},
        {%{descriptor | recoverable?: :yes}, :invalid_inference_descriptor_recoverability},
        {%{descriptor | recovery_reason: :unexpected},
         :invalid_inference_descriptor_recovery_reason}
      ]

      Enum.each(invalid, fn {candidate, reason} ->
        assert {:error, ^reason} = Descriptor.validate(candidate)
      end)

      assert {:error, {:nonportable_run_value, [:inference_descriptor, :flow], :pid}} =
               Descriptor.validate(%{descriptor | flow: self()})
    end

    test "descriptor construction fails closed and preserves collection shape when redacting" do
      invalid_request = %{request("invalid-descriptor") | id: ""}

      assert_raise ArgumentError, ~r/invalid inference descriptor/, fn ->
        Descriptor.from_request(invalid_request)
      end

      route = %Route{label: :selected, scores: [self()]}
      descriptor = Descriptor.from_request(request("route-redaction"), route: route)
      assert descriptor.route.scores == []
    end
  end

  describe "portable inference value objects" do
    test "input source evidence remains typed, closed, and fail-safe" do
      source =
        InputSource.new(%{
          "kind" => "chat",
          "trust" => :system,
          "provenance" => %{connector: "test"},
          "authenticity" => %{verified: true},
          "metadata" => %{}
        })

      assert InputSource.trust_classes() == [:untrusted, :trusted, :system]
      assert :ok = InputSource.validate(source)
      assert {:error, :invalid_input_source} = InputSource.validate(:invalid)
      assert {:error, :invalid_input_source_kind} = InputSource.validate(%InputSource{})

      assert {:error, :invalid_input_source_trust} =
               InputSource.validate(%{source | trust: :administrator})

      assert_raise ArgumentError, ~r/invalid input source trust/, fn ->
        InputSource.new(kind: :chat, trust: :administrator)
      end

      input = Input.new(%{"text" => "hello", "source" => source})
      assert Input.trust(input) == :system

      assert Input.source_evidence(input) == %{
               kind: "chat",
               trust: :system,
               provenance: %{connector: "test"},
               authenticity: %{verified: true}
             }

      invalid_source = %{source | metadata: []}
      invalid_input = %Input{text: "legacy", source: invalid_source}
      assert Input.trust(invalid_input) == :untrusted

      assert Input.source_evidence(invalid_input) == %{
               kind: :legacy,
               trust: :untrusted,
               provenance: %{},
               authenticity: %{}
             }

      assert {:error, :invalid_input} = Input.validate(:invalid)
      assert :error = Input.fetch_meta(%Input{meta: %{}}, 7)
      assert {:error, :invalid_input_text} = Input.validate(%Input{text: 7})
      assert {:error, :invalid_input_metadata} = Input.validate(%Input{meta: []})
      assert {:error, :invalid_input_source} = Input.validate(%Input{source: :legacy})
    end

    test "observer subscriptions share the committed operation event lane" do
      ref = Spectre.Instance.Ref.new(@agent, Subject.new("inference-events-edge"))

      assert {:ok, _registration} = Events.subscribe(ref)
      assert :ok = Events.unsubscribe(ref)
    end

    test "budget snapshots retain unlimited fields and reject malformed accounting" do
      snapshot =
        BudgetSnapshot.new(
          inference_id: "inference",
          attempt_id: "attempt",
          remaining: %{output_tokens: nil}
        )

      assert :ok = BudgetSnapshot.validate(snapshot)

      assert_raise ArgumentError, ~r/invalid budget snapshot/, fn ->
        BudgetSnapshot.new(
          inference_id: "inference",
          attempt_id: "attempt",
          remaining: :unbounded
        )
      end

      budget = Budget.new("inference")

      assert {:error, :invalid_inference_budget_accounting} =
               Budget.validate(%{budget | reservations: %{"attempt" => :invalid}})

      assert {:error, :invalid_inference_budget_accounting} =
               Budget.validate(%{budget | settlements: %{"attempt" => :invalid}})
    end

    test "constraint merging keeps existing optional limits when the stronger layer omits them" do
      base =
        Constraints.new(
          context_tokens: 8,
          maximum_latency_ms: 100,
          maximum_cost_tier: :medium,
          maximum_output_tokens: 32,
          max_attempts: 2
        )

      assert %Constraints{
               context_tokens: 8,
               maximum_latency_ms: 100,
               maximum_cost_tier: :medium,
               maximum_output_tokens: 32,
               max_attempts: 2
             } = Constraints.merge(base, %Constraints{})
    end

    test "observer values validate constructor failures and optional fences" do
      progress = progress()

      assert {:error, :invalid_inference_progress_identity} =
               Progress.validate(%{progress | inference_id: ""})

      assert_raise ArgumentError, ~r/invalid inference progress/, fn ->
        Progress.new(progress_opts(state: :invalid))
      end

      event =
        Event.new(:terminal_committed,
          instance_key: "instance",
          inference_id: "inference",
          invocation_id: "invocation",
          canonical_revision: 1,
          timestamp: 1
        )

      assert :ok = Event.validate(event)

      assert_raise ArgumentError, ~r/invalid inference event/, fn ->
        Event.new(:progress_committed, progress,
          instance_key: "",
          canonical_revision: 1,
          timestamp: 1
        )
      end

      assert_raise ArgumentError, ~r/invalid inference event/, fn ->
        Event.new(:stream_interrupted,
          instance_key: "instance",
          inference_id: "inference",
          invocation_id: "invocation",
          canonical_revision: 1,
          timestamp: -1
        )
      end
    end

    test "responses and stream events reject untrusted runtime shapes" do
      assert {:error, :invalid_inference_response} = Response.validate(:invalid)

      assert {:error, :invalid_inference_response_selection} =
               Response.validate(%Response{text: "ok", selection: :invalid})

      assert {:error, :invalid_inference_response_usage} =
               Response.validate(%Response{text: "ok", usage: %{input_tokens: self()}})

      assert {:error, :invalid_stream_event} = StreamEvent.validate(:invalid)

      assert_raise ArgumentError, ~r/invalid stream event/, fn ->
        StreamEvent.new(:delta,
          inference_id: "inference",
          invocation_id: "invocation",
          attempt_id: "attempt",
          run_revision: 1,
          generation: "generation",
          dispatch_id: "dispatch",
          control_revision: 0,
          stream_epoch: "epoch",
          sequence: 1,
          payload: :not_text
        )
      end
    end

    test "request builders normalize explicit and source-derived modalities" do
      explicit =
        Request.for_classification(
          plan("classify"),
          %{input: Input.new("image")},
          modalities: [:text, :image, :image]
        )

      assert explicit.modalities == [:text, :image]

      source_input = %Input{
        text: "",
        source: %Spectre.Input.Source{metadata: %{modalities: nil}}
      }

      derived = Request.for_classification(plan("derive"), %{input: source_input}, [])
      assert derived.modalities == []
    end

    test "the highest cost tier remains an explicit compatibility boundary" do
      profile =
        Profile.new(
          id: :high_cost,
          rank: 1,
          model: :model,
          cost_tier: :high,
          latency_tier: :low
        )

      constrained = %{
        request("high-cost")
        | constraints: Constraints.new(maximum_cost_tier: :high)
      }

      assert Profile.compatible?(profile, constrained, [profile])
    end

    test "continuations validate optional selection, budget, and history fences" do
      descriptor = Descriptor.from_request(request("continuation-defaults"))
      continuation = InferenceContinuation.new(descriptor)

      assert continuation.frozen_selection == nil
      assert :ok = InferenceContinuation.validate(continuation)

      assert_raise ArgumentError, ~r/invalid inference continuation/, fn ->
        InferenceContinuation.new(%{descriptor | id: ""})
      end

      {_run, selected} = inference_context("continuation-fences")

      mismatched_selection = %{
        selected.frozen_selection
        | request_id: "another-inference"
      }

      assert {:error, :inference_selection_fence_mismatch} =
               InferenceContinuation.validate(%{
                 selected
                 | frozen_selection: mismatched_selection
               })

      invalid_selection = %{selected.frozen_selection | request_id: ""}

      assert {:error, :invalid_frozen_selection_request_id} =
               InferenceContinuation.validate(%{selected | frozen_selection: invalid_selection})

      assert {:error, :inference_budget_id_mismatch} =
               InferenceContinuation.validate(%{
                 selected
                 | budget: Budget.new("another-inference")
               })

      assert {:error, :invalid_inference_budget} =
               InferenceContinuation.validate(%{selected | budget: :invalid})

      assert {:error, :invalid_inference_previous_attempts} =
               InferenceContinuation.validate(%{selected | previous_attempts: :invalid})
    end

    test "the portable Run codec rejects malformed nested tags without creating atoms" do
      assert {:error, {:unknown_run_value_tag, "unknown"}} =
               RunValue.decode(%{
                 "$spectre" => "map",
                 "entries" => [[1, %{"$spectre" => "unknown"}]]
               })

      missing_module = Module.concat(__MODULE__, MissingPortableStruct) |> Atom.to_string()

      assert {:error, {:unknown_run_module, ^missing_module}} =
               RunValue.decode(%{
                 "$spectre" => "struct",
                 "module" => missing_module,
                 "fields" => %{}
               })

      assert {:ok, empty_fields} = RunValue.encode(%{})

      assert {:error,
              {:invalid_run_struct, "Elixir.SpectreInferenceCoreEdgeContractTest",
               UndefinedFunctionError}} =
               RunValue.decode(%{
                 "$spectre" => "struct",
                 "module" => "Elixir.SpectreInferenceCoreEdgeContractTest",
                 "fields" => empty_fields
               })

      assert {:error, {:invalid_encoded_run_list, {:improper_tail, 1}}} =
               RunValue.prepare([:head | :tail])

      assert {:error, {:unknown_run_value_tag, "unknown"}} =
               RunValue.decode(%{"plain" => %{"$spectre" => "unknown"}})

      assert {:error, {:invalid_encoded_run_binary, "%"}} =
               RunValue.decode(%{"$spectre" => "binary", "value" => "%"})

      assert {:error, {:invalid_encoded_run_value, :other}} = RunValue.decode(<<1::1>>)
    end

    test "frozen selection metadata and semantic failures never retain unsafe details" do
      selection =
        Selection.new(
          request_id: "selection",
          level: :default,
          model: :model,
          reason: :selected,
          selector: Spectre.Inference.Selector.Default,
          attempt: 1,
          metadata: %{}
        )

      assert_raise ArgumentError, ~r/invalid frozen selection/, fn ->
        selection
        |> Map.put(:request_id, "")
        |> FrozenSelection.from_selection()
      end

      assert %FrozenSelection{metadata: %{}} =
               selection
               |> Map.put(:metadata, %{owner: self()})
               |> FrozenSelection.from_selection()

      assert %FrozenSelection{metadata: %{}} =
               selection
               |> Map.put(:metadata, :invalid)
               |> FrozenSelection.from_selection()

      assert {:inference_budget_exceeded, %{class: :error}} =
               Failure.sanitize({:inference_budget_exceeded, ["private"]})
    end
  end

  describe "inference and effect Invocations" do
    test "constructors reject non-portable boundary state" do
      {run, continuation} = inference_context("constructor")

      assert_raise ArgumentError, ~r/non-portable Invocation/, fn ->
        Invocation.from_inference(run, continuation, attempt: 0)
      end

      effect = Effect.stage(%{id: "effect", kind: :action, name: :execute})

      assert_raise ArgumentError, ~r/non-portable Invocation/, fn ->
        Invocation.from_effect(run, %{effect | mode: self()}, "effect-invocation")
      end
    end

    test "validates inference identity, fencing, binding, metadata, and portability" do
      {run, continuation} = inference_context("validation")
      invocation = Invocation.from_inference(run, continuation, streaming?: true)

      assert :ok = Invocation.validate(invocation)
      assert {:error, :invalid_invocation} = Invocation.validate(%{})

      invalid = [
        {%{invocation | id: ""}, :invalid_invocation_identity},
        {%{invocation | run_revision: -1}, :invalid_invocation_run_revision},
        {%{invocation | kind: :other}, :invalid_invocation_kind},
        {%{invocation | status: :complete}, :invalid_invocation_status},
        {%{invocation | operation: :invalid}, :invalid_invocation_operation},
        {%{invocation | metadata: %URI{}}, :invalid_invocation_metadata},
        {%{invocation | ref: nil}, :invalid_invocation_ref},
        {%{invocation | inference_id: nil}, :invalid_inference_invocation_identity},
        {%{invocation | owner: @agent}, :invalid_inference_invocation_binding},
        {%{invocation | metadata: %{model_ref: nil, profile_hash: nil, streaming?: true}},
         :invalid_inference_invocation_metadata},
        {%{invocation | metadata: %{model_ref: "model", profile_hash: "", streaming?: true}},
         :invalid_inference_invocation_metadata},
        {%{invocation | metadata: %{model_ref: "model", profile_hash: nil, streaming?: :yes}},
         :invalid_inference_invocation_metadata},
        {%{invocation | attempt: 0}, :invalid_invocation_attempt},
        {%{invocation | control_revision: -1}, :invalid_invocation_control_revision}
      ]

      Enum.each(invalid, fn {candidate, reason} ->
        assert {:error, ^reason} = Invocation.validate(candidate)
      end)

      assert {:error, {:nonportable_run_value, [:invocation, :metadata, :runtime], :pid}} =
               Invocation.validate(%{
                 invocation
                 | metadata: Map.put(invocation.metadata, :runtime, self())
               })
    end

    test "effect Invocations reject inference-only fences" do
      run = Run.new(@agent, Input.new("effect"), State.new(nil), run_id: "effect-run")
      effect = Effect.stage(%{id: "effect", kind: :action, name: :execute})
      invocation = Invocation.from_effect(run, effect, "effect-invocation")

      assert :ok = Invocation.validate(invocation)

      assert {:error, :invalid_effect_invocation_fences} =
               Invocation.validate(%{invocation | stream_epoch: "inference-only"})
    end
  end

  defp inference_context(id) do
    request = request(id)
    descriptor = Descriptor.from_request(request)

    frozen = %FrozenSelection{
      request_id: id,
      level: :default,
      model_ref: FrozenSelection.model_ref(:model),
      reason: :explicit_model_override,
      selector_ref: Atom.to_string(Spectre.Inference.Selector.Default),
      attempt: 1
    }

    continuation = InferenceContinuation.new(descriptor, frozen_selection: frozen)
    run = Run.new(@agent, Input.new(id), State.new(nil), run_id: "run-#{id}")
    {run, continuation}
  end

  defp request(id) do
    Request.new(
      id: id,
      purpose: :response_generation,
      plan: plan(id),
      constraints: %Constraints{}
    )
  end

  defp plan(text) do
    {:ok, plan} = Plan.compose(text, [], [:agent])
    plan
  end

  defp progress do
    progress_opts() |> Progress.new()
  end

  defp progress_opts(overrides \\ []) do
    [
      inference_id: "inference",
      invocation_id: "invocation",
      attempt_id: "attempt",
      run_revision: 1,
      generation: "generation",
      dispatch_id: "dispatch",
      control_revision: 0,
      stream_epoch: "epoch",
      sequence: 1,
      state: :terminal,
      at: 1,
      canonical_revision: 1
    ]
    |> Keyword.merge(overrides)
  end
end
