defmodule SpectreRouterNativeAdapterTest.Binary do
  @moduledoc false

  use Spectre.Router.Adapter,
    id: :binary,
    accept: 0.86,
    margin: 0.04,
    strength: :medium

  @impl Spectre.Router.Adapter
  def evaluate(%Spectre.Router.Adapter.Request{} = request) do
    if test_pid = Map.get(request.meta, :test_pid) do
      send(test_pid, {:router_adapter_request, request})
    end

    results =
      case request.text do
        "duplicate" ->
          rule = Enum.find(request.rules, &(&1.label == :BINARY_ROUTE))
          [result(rule, 0.71), result(rule, 0.93, margin: 0.07)]

        "invalid ref" ->
          [%{rule: {:agent, :INVENTED}, score: 0.99}]

        "invalid field" ->
          rule = Enum.find(request.rules, &(&1.label == :BINARY_ROUTE))
          [%{rule: rule.ref, score: 0.99, accepted?: true}]

        "raise" ->
          raise "private Adapter failure"

        "slow" ->
          Process.sleep(100)
          []

        "multiple" ->
          Enum.with_index(request.rules, fn rule, index ->
            result(rule, 0.95 - index * 0.05, margin: 0.08)
          end)

        "second" ->
          request.rules
          |> Enum.filter(&(&1.label == :SECOND_ROUTE))
          |> Enum.map(&result(&1, 0.94, margin: 0.06))

        _other ->
          request.rules
          |> Enum.filter(&(&1.label == :BINARY_ROUTE))
          |> Enum.map(fn rule ->
            result(rule, Map.get(request.meta, :score, 0.91), margin: 0.08)
          end)
      end

    {:ok, results}
  end
end

defmodule SpectreRouterNativeAdapterTest.Reserved do
  @moduledoc false

  use Spectre.Router.Adapter, id: :learn

  @impl Spectre.Router.Adapter
  def evaluate(_request), do: :skip
end

defmodule SpectreRouterNativeAdapterTest.Agent do
  @moduledoc false

  use Spectre.Agent

  router(via: [:regex, SpectreRouterNativeAdapterTest.Binary])

  flow :support do
    on :BINARY_ROUTE,
      binary: [examples: ["disk full", "no space left"]],
      via: [:binary] do
      reply(:binary_route)
    end

    on :SECOND_ROUTE, binary: ["second"], via: [:binary] do
      reply(:second_route)
    end
  end
end

defmodule SpectreRouterNativeAdapterTest.InvokeBinary do
  @moduledoc false
  @behaviour Spectre.Router.Plug

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(context, _opts), do: Spectre.Router.Adapter.run(context, :binary)
end

defmodule SpectreRouterNativeAdapterTest.CustomPipeline do
  @moduledoc false

  use Spectre.Pipeline

  pipeline do
    plug(SpectreRouterNativeAdapterTest.InvokeBinary)
    plug(Spectre.Router.Plugs.Arbitrate)
    plug(Spectre.Router.Plugs.Terminalize)
  end
end

defmodule SpectreRouterNativeAdapterTest.CustomPipelineAgent do
  @moduledoc false

  use Spectre.Agent

  router(
    via: [SpectreRouterNativeAdapterTest.Binary],
    pipeline: SpectreRouterNativeAdapterTest.CustomPipeline
  )

  flow :support do
    on :BINARY_ROUTE, binary: ["custom pipeline"], via: [:binary] do
      reply(:custom_pipeline)
    end
  end
end

defmodule SpectreRouterNativeAdapterTest.Probed do
  @moduledoc false
  @behaviour Spectre.Router.Adapter

  @descriptor %{
    contract: 1,
    id: :probed,
    accept: 0.0,
    margin: nil,
    strength: :weak
  }

  def __spectre_router_adapter__ do
    case Process.get({__MODULE__, :descriptor_mode}) do
      {:notify, pid} ->
        send(pid, {:descriptor_read, self()})
        @descriptor

      :drift ->
        %{@descriptor | accept: 0.5}

      :raise ->
        raise "private descriptor failure"

      _default ->
        @descriptor
    end
  end

  @impl Spectre.Router.Adapter
  def evaluate(_request), do: :skip
end

defmodule SpectreRouterNativeAdapterTest.NoopPipeline do
  @moduledoc false
  def call(context), do: {:ok, context}
end

defmodule SpectreRouterNativeAdapterTest.ProbedAgent do
  @moduledoc false

  use Spectre.Agent

  router(
    via: [SpectreRouterNativeAdapterTest.Probed],
    pipeline: SpectreRouterNativeAdapterTest.NoopPipeline
  )
end

defmodule SpectreRouterNativeAdapterTest.ProbedDefaultAgent do
  @moduledoc false

  use Spectre.Agent

  router(via: [SpectreRouterNativeAdapterTest.Probed])

  flow :support do
    on :PROBED, probed: ["probe"], via: [:probed] do
      reply(:probed)
    end
  end
end

defmodule SpectreRouterNativeAdapterTest.WeakBand do
  @moduledoc false

  use Spectre.Router.Adapter, id: :weak_band, strength: :weak

  @impl Spectre.Router.Adapter
  def evaluate(request) do
    label = if request.text == "global", do: :GLOBAL_ADAPTER, else: :NORMAL_ADAPTER
    rule = Enum.find(request.rules, &(&1.label == label))
    {:ok, result(rule, 0.9)}
  end
end

defmodule SpectreRouterNativeAdapterTest.StrengthAgent do
  @moduledoc false

  use Spectre.Agent

  router(via: [SpectreRouterNativeAdapterTest.WeakBand], semantic_cache?: false)

  interrupt :GLOBAL_ADAPTER,
    weak_band: ["global"],
    via: [:weak_band],
    cache: false do
    reply(:global_adapter)
  end

  flow :support do
    on :NORMAL_ADAPTER,
      weak_band: ["normal"],
      weak_band_strength: :hard,
      via: [:weak_band],
      cache: false do
      reply(:normal_adapter)
    end
  end
end

defmodule SpectreRouterNativeAdapterTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Spectre.Router.Adapter.Compiler
  alias Spectre.Router.Adapter.Conformance
  alias Spectre.Router.Adapter.Request
  alias Spectre.Router.Adapter.RuleView
  alias Spectre.Router.Adapter.Runner

  test "compiles the descriptor into the Agent and normalizes module steps to ids" do
    router = SpectreRouterNativeAdapterTest.Agent.__spectre_router__()

    assert Keyword.fetch!(router, :via) == [:regex, :binary]

    assert %{
             binary: %{
               id: :binary,
               module: SpectreRouterNativeAdapterTest.Binary,
               order: 1,
               descriptor: %{
                 contract: 1,
                 id: :binary,
                 accept: 0.86,
                 margin: 0.04,
                 strength: :medium
               }
             }
           } = Keyword.fetch!(router, Compiler.compiled_key())

    assert [%{opts: opts, via: [:binary]}, %{via: [:binary]}] =
             SpectreRouterNativeAdapterTest.Agent.__spectre_rules__()

    assert Keyword.fetch!(opts, :binary) == [examples: ["disk full", "no space left"]]
  end

  test "leaves the compiled Router untouched when an Agent has no Adapter" do
    agent = compile_agent("router via: [:regex], semantic_cache?: false")
    router = agent.__spectre_router__()

    assert router == [
             arbitrator:
               {Spectre.Router.Arbitrators.Default,
                [
                  classifier_accept: 0.93,
                  classifier_margin: 0.08,
                  embedding_accept: 0.84,
                  bag_accept: 0.72,
                  conflict: :llm,
                  no_decision: :llm
                ]},
             via: [:regex],
             semantic_cache?: false
           ]

    refute Keyword.has_key?(router, Compiler.compiled_key())
  end

  test "runs the Adapter natively and projects only routing context" do
    input =
      Spectre.Input.new(%{
        text: "route through binary",
        meta: %{test_pid: self(), channel: :web}
      })

    state = %Spectre.State{
      current_flow: :support,
      current_scope: :agent,
      data: %{
        chat_history: [
          %{user: "previous question", assistant: "previous answer"}
        ]
      }
    }

    observer_ref = make_ref()
    test_pid = self()

    telemetry_handler = fn event, measurements, metadata ->
      send(test_pid, {:router_adapter_telemetry, event, measurements, metadata})
    end

    context = %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.Agent,
      input: input,
      state: state,
      opts: [
        spectre_provider_observer: {self(), observer_ref},
        telemetry_handler: telemetry_handler,
        classification_log?: false
      ]
    }

    assert {:ok, routed} = Spectre.Router.route_context(input, context)
    assert routed.route.label == :BINARY_ROUTE
    assert routed.route.strategy == :binary

    assert [%Spectre.Router.Candidate{} = candidate] =
             Enum.filter(routed.candidates, &(&1.provider == :binary))

    assert candidate.accepted?
    assert candidate.strength == :weak
    assert candidate.metadata.router_adapter.band == :medium
    assert candidate.metadata.router_adapter.required == %{score: 0.86, margin: 0.04}

    assert_receive {:router_adapter_request, %Request{} = request}
    assert request.text == "route through binary"
    assert request.meta.channel == :web
    assert request.current_flow == :support
    assert request.current_scope == :agent
    assert request.recent_chat == "User: previous question\nAssistant: previous answer"

    assert [%RuleView{} = first, %RuleView{} = second] = request.rules
    assert first.ref == {:agent, :BINARY_ROUTE}
    assert first.data == [examples: ["disk full", "no space left"]]
    assert second.ref == {:agent, :SECOND_ROUTE}
    refute Map.has_key?(Map.from_struct(first), :handler)
    refute Map.has_key?(Map.from_struct(first), :owner)

    assert_receive {:spectre_provider_call, ^observer_ref,
                    %{provider: :router_adapter, purpose: :binary, invoked?: true}}

    assert_receive {:router_adapter_telemetry, [:spectre, :router, :adapter, :start],
                    %{system_time: system_time}, %{adapter_id: :binary}}

    assert is_integer(system_time)

    assert_receive {:router_adapter_telemetry, [:spectre, :router, :adapter, :stop],
                    %{duration_us: duration_us, result_count: 1}, stop_metadata}

    assert is_integer(duration_us) and duration_us >= 0
    assert stop_metadata == %{adapter_id: :binary, outcome: :ok, invoked?: true}

    refute Enum.any?([:text, :recent_chat, :matched, :score, :rule, :reason], fn key ->
             Map.has_key?(stop_metadata, key)
           end)
  end

  test "includes Adapter provider calls in Router evaluation receipts" do
    assert {:ok, receipt} =
             Spectre.Router.evaluate(
               SpectreRouterNativeAdapterTest.Agent,
               %{text: "evaluate binary", meta: %{channel: :test}},
               classification_log?: false
             )

    assert receipt.label == :BINARY_ROUTE

    assert Enum.any?(receipt.provider_calls, fn call ->
             call.provider == :router_adapter and call.purpose == :binary and call.invoked?
           end)
  end

  test "keeps Adapter calls visible across a multi-case Spectre.Eval corpus" do
    cases =
      for id <- ["first", "second"] do
        %{
          id: id,
          input: "eval #{id}",
          expected_route: "BINARY_ROUTE",
          expected_strategy: "binary",
          llm: :forbidden
        }
      end

    assert {:ok, %{total: 2, passed: 2, results: results}} =
             Spectre.Eval.run(SpectreRouterNativeAdapterTest.Agent, cases,
               router_opts: [classification_log?: false]
             )

    assert Enum.all?(results, fn result ->
             Enum.any?(result.receipt.provider_calls, fn call ->
               call.provider == :router_adapter and call.purpose == :binary and call.invoked?
             end)
           end)
  end

  test "lets a custom pipeline invoke only a compiled Adapter id" do
    input = Spectre.Input.new("custom pipeline")

    context = %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.CustomPipelineAgent,
      input: input,
      state: %Spectre.State{},
      opts: [classification_log?: false]
    }

    assert {:ok, routed} = Spectre.Router.route_context(input, context)
    assert routed.route.label == :BINARY_ROUTE
    assert routed.route.strategy == :binary
  end

  test "stops mixed execution on hard locks and halted plug contexts" do
    hard_stop_agent =
      compile_agent("""
      router via: [:regex, SpectreRouterNativeAdapterTest.Binary], semantic_cache?: false

      interrupt :STOP,
        regex: ~r/^stop$/,
        binary: ["stop"],
        via: [:regex, :binary],
        cache: false do
        reply :stopped
      end
      """)

    input = Spectre.Input.new(%{text: "stop", meta: %{test_pid: self()}})

    assert {:ok, hard_stopped} =
             Spectre.Router.route_context(input, %Spectre.Context{
               agent: hard_stop_agent,
               input: input,
               state: %Spectre.State{},
               opts: [classification_log?: false]
             })

    assert hard_stopped.route.label == :STOP
    assert {:router_adapter_skip, :binary, :hard_candidate} in hard_stopped.traces
    refute_receive {:router_adapter_request, _request}, 20

    halted_agent =
      compile_agent("""
      router via: [:arbitrate, SpectreRouterNativeAdapterTest.Binary], semantic_cache?: false

      flow :support do
        on :LATE, binary: ["late"], via: [:binary], cache: false do
          reply :late
        end
      end
      """)

    halted_input = Spectre.Input.new(%{text: "late", meta: %{test_pid: self()}})

    assert {:ok, halted} =
             Spectre.Router.route_context(halted_input, %Spectre.Context{
               agent: halted_agent,
               input: halted_input,
               state: %Spectre.State{},
               opts: [classification_log?: false]
             })

    assert halted.route.strategy == :clarify
    refute_receive {:router_adapter_request, _request}, 20
  end

  test "rebuilds the private plan after runtime opts and rejects new Adapter modules" do
    key = Compiler.compiled_key()
    input = Spectre.Input.new("route through binary")

    context = %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.Agent,
      input: input,
      state: %Spectre.State{},
      opts: [{key, %{entries: %{evil: %{module: String}}, diagnostics: []}}]
    }

    assert {:ok, routed} = Spectre.Router.route_context(input, context)
    assert {:ok, entry} = Spectre.Router.Adapter.Plan.fetch(routed.opts[key], :binary)
    assert entry.module == SpectreRouterNativeAdapterTest.Binary

    bad_context = %{context | opts: [via: [SpectreRouterNativeAdapterTest.Reserved]]}

    assert {:error, {:unknown_router_step, SpectreRouterNativeAdapterTest.Reserved}} =
             Spectre.Router.route_context(input, bad_context)
  end

  test "checks each active descriptor once per evaluation without checking excluded ids" do
    key = {SpectreRouterNativeAdapterTest.Probed, :descriptor_mode}
    Process.put(key, {:notify, self()})
    on_exit(fn -> Process.delete(key) end)

    input = Spectre.Input.new("probe")

    active_context = %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.ProbedDefaultAgent,
      input: input,
      state: %Spectre.State{},
      opts: [classification_log?: false]
    }

    assert {:ok, _routed} = Spectre.Router.route_context(input, active_context)
    assert_receive {:descriptor_read, descriptor_reader}
    assert descriptor_reader == self()
    refute_receive {:descriptor_read, _other}, 20

    excluded_context = %{active_context | opts: [via: [:regex], classification_log?: false]}
    assert {:ok, _routed} = Spectre.Router.route_context(input, excluded_context)
    refute_receive {:descriptor_read, _other}, 20
  end

  test "shares recent-chat override, gate and limit semantics with LLM arbitration" do
    state = %Spectre.State{
      current_flow: :support,
      data: %{
        chat_history: [
          %{user: "first", assistant: "one"},
          %{user: "second", assistant: "two"}
        ]
      }
    }

    for {opts, expected} <- [
          {[recent_chat: "provided"], "provided"},
          {[classifier_history: false], "none"},
          {[classifier_history_limit: 1], "User: second\nAssistant: two"}
        ] do
      input = Spectre.Input.new(%{text: "chat", meta: %{test_pid: self()}})

      assert {:ok, _routed} =
               Spectre.Router.route_context(input, %Spectre.Context{
                 agent: SpectreRouterNativeAdapterTest.Agent,
                 input: input,
                 state: state,
                 opts: Keyword.put(opts, :classification_log?, false)
               })

      assert_receive {:router_adapter_request, %Request{recent_chat: ^expected}}
    end
  end

  test "custom pipelines preflight all compiled descriptors and degrade drift locally" do
    key = {SpectreRouterNativeAdapterTest.Probed, :descriptor_mode}
    Process.put(key, :drift)
    on_exit(fn -> Process.delete(key) end)

    input = Spectre.Input.new("probe")

    context = %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.ProbedAgent,
      input: input,
      state: %Spectre.State{},
      opts: []
    }

    assert {:ok, routed} = Spectre.Router.route_context(input, context)

    diagnostic =
      {:router_adapter_descriptor_drift, :probed, SpectreRouterNativeAdapterTest.Probed}

    assert diagnostic in routed.errors
    assert diagnostic in routed.traces

    Process.put(key, :raise)
    assert {:ok, unreadable} = Spectre.Router.route_context(input, context)

    assert Enum.any?(unreadable.errors, fn
             {:router_adapter_descriptor_unavailable, :probed,
              SpectreRouterNativeAdapterTest.Probed, {:exception, RuntimeError}} ->
               true

             _other ->
               false
           end)

    refute inspect(unreadable.errors) =~ "private descriptor failure"
  end

  test "Doctor reports effective Adapter order, dependencies, descriptors and thresholds" do
    key = {SpectreRouterNativeAdapterTest.Probed, :descriptor_mode}
    Process.put(key, {:notify, self()})
    on_exit(fn -> Process.delete(key) end)

    assert {:ok, report} =
             Spectre.Doctor.run(
               agent: SpectreRouterNativeAdapterTest.ProbedDefaultAgent,
               router_opts: [via: [:probed]]
             )

    checks = Map.new(report.checks, &{&1.id, &1})

    assert checks["router.adapters"].status == :ok
    assert checks["router.adapters"].details.active_count == 1
    assert [%{id: :probed, order: 0}] = checks["router.adapters"].details.adapters
    assert checks["router.adapter_dependencies"].status == :ok
    assert checks["router.adapter_descriptors"].status == :ok

    assert [threshold] = checks["router.adapter_thresholds"].details.adapters
    assert threshold.id == :probed
    assert threshold.band == :weak
    assert threshold.accept == 0.0
    assert threshold.margin == nil
    assert threshold.order == 0

    assert_receive {:descriptor_read, descriptor_reader}
    assert descriptor_reader == self()
    refute_receive {:descriptor_read, _other}, 20

    assert {:ok, excluded} =
             Spectre.Doctor.run(
               agent: SpectreRouterNativeAdapterTest.ProbedDefaultAgent,
               router_opts: [via: [:regex]]
             )

    excluded_checks = Map.new(excluded.checks, &{&1.id, &1})
    assert excluded_checks["router.adapters"].details.active_count == 0
    assert excluded_checks["router.adapter_dependencies"].status == :error
    refute_receive {:descriptor_read, _other}, 20

    assert {:error, :doctor_router_opts_require_agent} =
             Spectre.Doctor.run(router_opts: [])

    assert {:error, {:invalid_doctor_option, :router_opts}} =
             Spectre.Doctor.run(
               agent: SpectreRouterNativeAdapterTest.ProbedDefaultAgent,
               router_opts: %{}
             )
  end

  test "Doctor surfaces descriptor drift without invoking the Adapter callback" do
    key = {SpectreRouterNativeAdapterTest.Probed, :descriptor_mode}
    Process.put(key, :drift)
    on_exit(fn -> Process.delete(key) end)

    assert {:ok, report} =
             Spectre.Doctor.run(agent: SpectreRouterNativeAdapterTest.ProbedDefaultAgent)

    descriptors = Enum.find(report.checks, &(&1.id == "router.adapter_descriptors"))
    assert descriptors.status == :warning
    assert descriptors.code == :router_adapter_descriptors_unavailable
    assert descriptors.details.unavailable == [:probed]
  end

  test "preserves global hard interrupts while clamping non-global rule strength" do
    assert {:ok, global} = strength_context("global")

    assert [%{label: :GLOBAL_ADAPTER, strength: :hard}] =
             Enum.filter(global.candidates, &(&1.provider == :weak_band))

    assert global.route.label == :GLOBAL_ADAPTER

    assert {:ok, normal} = strength_context("normal")

    assert [%{label: :NORMAL_ADAPTER, strength: :weak}] =
             Enum.filter(normal.candidates, &(&1.provider == :weak_band))

    assert normal.route.label == :NORMAL_ADAPTER
  end

  test "keeps below-threshold evidence without allowing it to win" do
    input = Spectre.Input.new(%{text: "uncertain", meta: %{score: 0.71}})

    context = %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.Agent,
      input: input,
      state: %Spectre.State{},
      opts: [classification_log?: false]
    }

    assert {:ok, routed} = Spectre.Router.route_context(input, context)
    assert routed.route.strategy == :clarify

    assert [%Spectre.Router.Candidate{accepted?: false, score: 0.71} = candidate] =
             Enum.filter(routed.candidates, &(&1.provider == :binary))

    assert candidate.metadata.router_adapter.threshold_reason == :score_below_threshold

    assert %{candidates: explanations} = routed.arbitration

    assert %{rejection_reason: :score_below_threshold, required: required} =
             Enum.find(explanations, &(&1.provider == :binary))

    assert required == %{score: 0.86, margin: 0.04}
  end

  test "preserves one Candidate per distinct Adapter result" do
    input = Spectre.Input.new("multiple")

    context = %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.Agent,
      input: input,
      state: %Spectre.State{current_flow: :support},
      opts: [classification_log?: false]
    }

    assert {:ok, routed} = Spectre.Router.route_context(input, context)

    assert routed.candidates
           |> Enum.filter(&(&1.provider == :binary))
           |> Enum.map(& &1.label)
           |> Enum.sort() == [:BINARY_ROUTE, :SECOND_ROUTE]
  end

  test "deduplicates by rule ref and keeps the strongest result deterministically" do
    assert {:ok, routed} = route_context("duplicate")

    assert [%{score: 0.93, margin: 0.07}] =
             Enum.filter(routed.candidates, &(&1.provider == :binary))
  end

  test "rejects invented refs and authoritative result fields without aborting routing" do
    for text <- ["invalid ref", "invalid field"] do
      assert {:ok, routed} = route_context(text)
      assert routed.route.strategy == :clarify
      assert Enum.empty?(Enum.filter(routed.candidates, &(&1.provider == :binary)))
      assert {:router_adapter_failed, :binary, :invalid_result} in routed.errors
    end
  end

  test "contains callback exceptions and dedicated timeouts" do
    assert {:ok, raised} = route_context("raise")
    assert raised.route.strategy == :clarify
    assert {:router_adapter_failed, :binary, :exception} in raised.errors
    refute inspect(raised.errors) =~ "private Adapter failure"

    assert {:ok, timed_out} = route_context("slow", router_adapter_timeout: 5)
    assert timed_out.route.strategy == :clarify
    assert {:router_adapter_failed, :binary, :timeout} in timed_out.errors
  end

  test "normalizer rejects label-only, out-of-range and oversized result sets" do
    visible_rules =
      SpectreRouterNativeAdapterTest.Agent.__spectre_rules__()
      |> Enum.map(&Spectre.Rule.new/1)

    assert {:error, {:invalid_result, 0, :rule_not_visible}} =
             Runner.normalize_results(%{rule: :BINARY_ROUTE, score: 0.9}, visible_rules)

    for score <- [-0.1, 1.1, "0.9"] do
      assert {:error, {:invalid_result, 0, :invalid_score}} =
               Runner.normalize_results(
                 %{rule: {:agent, :BINARY_ROUTE}, score: score},
                 visible_rules
               )
    end

    many_rules =
      Enum.map(1..33, fn index ->
        %Spectre.Rule{label: String.to_atom("RULE_#{index}"), scope: :agent}
      end)

    many_results = Enum.map(many_rules, &%{rule: {&1.scope, &1.label}, score: 0.9})

    assert {:error, {:too_many_results, 32}} =
             Runner.normalize_results(many_results, many_rules)
  end

  test "applies zero-score and optional-margin semantics exactly" do
    visible_rules =
      SpectreRouterNativeAdapterTest.Agent.__spectre_rules__()
      |> Enum.map(&Spectre.Rule.new/1)

    descriptor = SpectreRouterNativeAdapterTest.Binary.__spectre_router_adapter__()

    assert {false, :score_below_threshold} =
             Runner.threshold(%{score: 0.0}, %{descriptor | accept: 0.0})

    assert {true, nil} = Runner.threshold(%{score: 0.91}, descriptor)

    for margin <- [-0.1, 1.1, "0.1"] do
      assert {:error, {:invalid_result, 0, :invalid_margin}} =
               Runner.normalize_results(
                 %{rule: {:agent, :BINARY_ROUTE}, score: 0.91, margin: margin},
                 visible_rules
               )
    end
  end

  test "result and examples helpers preserve only the public evidence shape" do
    rule = %RuleView{
      ref: {:agent, :BINARY_ROUTE},
      label: :BINARY_ROUTE,
      scope: :agent,
      data: [examples: ["disk full", nil, "no space left"]]
    }

    assert Spectre.Router.Adapter.examples(rule) == ["disk full", "no space left"]

    assert Spectre.Router.Adapter.result(rule, 0.91, margin: 0.08, matched: "disk full") ==
             %{
               rule: {:agent, :BINARY_ROUTE},
               score: 0.91,
               margin: 0.08,
               matched: "disk full"
             }

    assert_raise ArgumentError, ~r/unknown router Adapter result options/, fn ->
      Spectre.Router.Adapter.result(rule, 0.91, accepted?: true)
    end

    assert_raise ArgumentError, ~r/must be a keyword list/, fn ->
      Spectre.Router.Adapter.result(rule, 0.91, [:margin, 0.08])
    end
  end

  test "offers an executable conformance report using the live normalizer" do
    request = conformance_request("conformance", 0.91)

    assert {:ok, report} =
             Conformance.run(SpectreRouterNativeAdapterTest.Binary, request)

    assert report == %{
             contract_version: 1,
             adapter_id: :binary,
             result_count: 1,
             accepted_count: 1,
             rejected_count: 0,
             thresholds: %{score: 0.86, margin: 0.04}
           }

    assert {:ok, %{accepted_count: 0, rejected_count: 1}} =
             Conformance.run(
               SpectreRouterNativeAdapterTest.Binary,
               conformance_request("conformance", 0.71)
             )
  end

  test "conformance failures identify descriptor, callback and result phases" do
    request = conformance_request("conformance", 0.91)

    assert {:error, {:router_adapter_conformance_failed, :descriptor, _reason}} =
             Conformance.run(String, request)

    assert {:error, {:router_adapter_conformance_failed, :callback, :exception}} =
             Conformance.run(
               SpectreRouterNativeAdapterTest.Binary,
               %{request | text: "raise"}
             )

    assert {:error,
            {:router_adapter_conformance_failed, :result, {:invalid_result, 0, :rule_not_visible}}} =
             Conformance.run(
               SpectreRouterNativeAdapterTest.Binary,
               %{request | text: "invalid ref"}
             )
  end

  test "requires the evaluate callback" do
    assert_raise ArgumentError, ~r/does not define evaluate\/1/, fn ->
      compile_module("""
      use Spectre.Router.Adapter, id: :missing_callback
      """)
    end
  end

  test "rejects malformed descriptors, unsupported contracts and duplicate ids" do
    for opts <- [
          ~s(id: "binary"),
          "id: String",
          "id: :bad_accept, accept: -0.1",
          "id: :bad_margin, margin: 1.1",
          "id: :bad_strength, strength: :critical"
        ] do
      assert_raise ArgumentError, ~r/invalid Spectre.Router.Adapter descriptor/, fn ->
        compile_module("""
        use Spectre.Router.Adapter, #{opts}
        def evaluate(_request), do: :skip
        """)
      end
    end

    unsupported =
      compile_module("""
      @behaviour Spectre.Router.Adapter
      def __spectre_router_adapter__ do
        %{contract: 2, id: :future, accept: 0.0, margin: nil, strength: :weak}
      end
      def evaluate(_request), do: :skip
      """)

    assert_raise ArgumentError, ~r/unsupported_contract.*2.*1/s, fn ->
      compile_agent("router via: [#{inspect(unsupported)}]")
    end

    assert_raise ArgumentError, ~r/duplicate router Adapter id :binary/, fn ->
      compile_agent("""
      router via: [
        SpectreRouterNativeAdapterTest.Binary,
        SpectreRouterNativeAdapterTest.Binary
      ]
      """)
    end
  end

  test "rejects ids consumed by the Agent rule compiler" do
    assert_raise ArgumentError, ~r/reserved_id.*learn/s, fn ->
      compile_agent("""
      router via: [SpectreRouterNativeAdapterTest.Reserved]
      """)
    end
  end

  test "reserves every built-in, control step and Agent-consumed rule key" do
    reserved =
      Enum.uniq(
        Compiler.built_in_steps() ++
          [:train, :training, :cache, :learn, :check, :checks, :via]
      )

    Enum.each(reserved, fn id ->
      adapter =
        compile_module("""
        use Spectre.Router.Adapter, id: #{inspect(id)}
        def evaluate(_request), do: :skip
        """)

      assert_raise ArgumentError, ~r/reserved_id/s, fn ->
        compile_agent("router via: [#{inspect(adapter)}]")
      end
    end)
  end

  test "rejects module atoms inside rule via" do
    assert_raise ArgumentError, ~r/invalid_router_rule_via.*String/s, fn ->
      compile_agent("""
      router via: [SpectreRouterNativeAdapterTest.Binary]

      flow :bad do
        on :BAD, binary: ["bad"], via: [String] do
          reply :bad
        end
      end
      """)
    end
  end

  test "validates Adapter rule data in structural mode" do
    assert_raise ArgumentError, ~r/invalid_router_adapter_rule_data.*binary/s, fn ->
      compile_agent("""
      router via: [SpectreRouterNativeAdapterTest.Binary]

      flow :bad do
        on :BAD, binary: &String.trim/1, via: [:binary] do
          reply :bad
        end
      end
      """)
    end
  end

  test "accepts Regex values as structural Adapter data" do
    agent =
      compile_agent("""
      router via: [SpectreRouterNativeAdapterTest.Binary]

      flow :valid do
        on :REGEX_DATA, binary: [~r/disk/i], via: [:binary] do
          reply :valid
        end
      end
      """)

    assert [%{opts: [binary: [%Regex{}]]}] = agent.__spectre_rules__()
  end

  test "keeps custom Skill dependencies logical and resolves them on the mounting Agent" do
    skill =
      compile_module("""
      use Spectre.Skill, id: :adapter_skill

      flow :support do
        on :SKILL_ROUTE, binary: ["skill"], via: [:binary] do
          reply :skill_route
        end
      end
      """)

    assert [%{via: [:binary]}] = skill.__spectre_rules__()

    mounted =
      compile_agent("""
      router via: [SpectreRouterNativeAdapterTest.Binary]
      skill #{inspect(skill)}, as: :adapter_skill
      """)

    assert [%Spectre.Skill.Mount{id: :adapter_skill}] = mounted.__spectre_skills__()
  end

  test "warns for an unavailable Skill Adapter with a fallback and rejects total invisibility" do
    fallback_skill =
      compile_module("""
      use Spectre.Skill, id: :fallback_skill

      flow :support do
        on :FALLBACK, preferred_binary: ["fallback"], via: [:preferred_binary, :llm_classifier] do
          reply :fallback
        end
      end
      """)

    warning =
      capture_io(:stderr, fn ->
        compile_agent("""
        router via: [:llm_classifier]
        skill #{inspect(fallback_skill)}, as: :fallback_skill
        """)
      end)

    assert warning =~ "preferred_binary"
    assert warning =~ "FALLBACK"

    invisible_skill =
      compile_module("""
      use Spectre.Skill, id: :invisible_skill

      flow :support do
        on :INVISIBLE, missing_binary: ["missing"], via: [:missing_binary] do
          reply :invisible
        end
      end
      """)

    assert_raise ArgumentError, ~r/unresolvable_router_rule.*missing_binary/s, fn ->
      compile_agent("skill #{inspect(invisible_skill)}, as: :invisible_skill")
    end
  end

  defp compile_agent(body) do
    compile_module("""
    use Spectre.Agent
    #{body}
    """)
  end

  defp route_context(text, opts \\ []) do
    input = Spectre.Input.new(text)

    Spectre.Router.route_context(input, %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.Agent,
      input: input,
      state: %Spectre.State{},
      opts: Keyword.put_new(opts, :classification_log?, false)
    })
  end

  defp strength_context(text) do
    input = Spectre.Input.new(text)

    Spectre.Router.route_context(input, %Spectre.Context{
      agent: SpectreRouterNativeAdapterTest.StrengthAgent,
      input: input,
      state: %Spectre.State{},
      opts: [classification_log?: false]
    })
  end

  defp conformance_request(text, score) do
    %Request{
      text: text,
      meta: %{score: score},
      current_flow: :support,
      current_scope: :agent,
      recent_chat: "none",
      rules: [
        %RuleView{
          ref: {:agent, :BINARY_ROUTE},
          label: :BINARY_ROUTE,
          scope: :agent,
          flow: :support,
          flow_path: [:support],
          data: ["conformance"],
          opts: [binary: ["conformance"]]
        }
      ]
    }
  end

  defp compile_module(body) do
    module = Module.concat(__MODULE__, "Dynamic#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      #{body}
    end
    """)

    module
  end
end
