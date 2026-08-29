defmodule SpectreRouterAdapterFailureContractTest.Provider do
  @moduledoc false

  use Spectre.Router.Adapter,
    id: :coverage_adapter,
    accept: 0.5,
    margin: 0.25,
    strength: :strong

  alias Spectre.Router.Adapter.Request

  @impl Spectre.Router.Adapter
  def evaluate(%Request{text: "skip"}), do: :skip
  def evaluate(%Request{text: "skip with reason"}), do: {:skip, :fixture_not_applicable}
  def evaluate(%Request{text: "skip with map"}), do: {:skip, %{reason: :map_skip}}
  def evaluate(%Request{text: "skip with opaque tuple"}), do: {:skip, {123, :private}}
  def evaluate(%Request{text: "skip with opaque value"}), do: {:skip, "private"}
  def evaluate(%Request{text: "declared error"}), do: {:error, {:backend_down, "private"}}
  def evaluate(%Request{text: "invalid envelope"}), do: :invalid_envelope

  def evaluate(%Request{text: "invalid result", rules: [rule | _rules]}) do
    {:ok, %{rule: rule.ref, score: 2}}
  end

  def evaluate(%Request{rules: [rule | _rules]}) do
    {:ok, result(rule, 1, margin: 1, matched: "integer evidence")}
  end
end

defmodule SpectreRouterAdapterFailureContractTest.DescriptorProbe do
  @moduledoc false

  @descriptor %{
    contract: 1,
    id: :descriptor_probe,
    accept: 0.0,
    margin: nil,
    strength: :weak
  }

  def __spectre_router_adapter__ do
    case Process.get({__MODULE__, :mode}, :valid) do
      :valid -> @descriptor
      {:return, value} -> value
      {:throw, value} -> throw(value)
      :raise -> raise "private descriptor failure"
    end
  end

  def evaluate(_request), do: :skip
end

defmodule SpectreRouterAdapterFailureContractTest.DescriptorOnly do
  @moduledoc false

  def __spectre_router_adapter__ do
    %{
      contract: 1,
      id: :descriptor_only,
      accept: 0.0,
      margin: nil,
      strength: :weak
    }
  end
end

defmodule SpectreRouterAdapterFailureContractTest.EvaluateOnly do
  @moduledoc false

  def evaluate(_request), do: :skip
end

defmodule SpectreRouterAdapterFailureContractTest.MountedSkill do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      kind: :skill,
      id: :coverage_skill,
      owner: __MODULE__,
      rules: [
        %{label: :MOUNTED_DEGRADED, via: [:regex, :missing_adapter], opts: []}
      ]
    }
  end
end

defmodule SpectreRouterAdapterFailureContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Definition
  alias Spectre.Router.Adapter
  alias Spectre.Router.Adapter.Compiler
  alias Spectre.Router.Adapter.Conformance
  alias Spectre.Router.Adapter.Diagnostics
  alias Spectre.Router.Adapter.Plan
  alias Spectre.Router.Adapter.Request
  alias Spectre.Router.Adapter.RuleView
  alias Spectre.Router.Context, as: RouterContext
  alias Spectre.Router.RecentChat
  alias Spectre.Rule
  alias Spectre.Skill.Mount

  @provider SpectreRouterAdapterFailureContractTest.Provider
  @descriptor_probe SpectreRouterAdapterFailureContractTest.DescriptorProbe

  test "compiler helpers reject malformed routers and preserve stable diagnostics" do
    assert Compiler.contract_version() == 1
    assert Compiler.control_steps() == [:arbitrate, :terminalize]

    assert Compiler.compiled_adapters([{Compiler.compiled_key(), :invalid}]) == %{}
    assert {:error, {:invalid_router, :invalid}} = Compiler.validate_router(:invalid)

    assert {:error, :invalid_router_adapter_map} =
             Compiler.validate_router([{Compiler.compiled_key(), :invalid}])

    assert {:error, :invalid_router_adapter_map} =
             Compiler.validate_router([{Compiler.compiled_key(), %{invalid: :entry}}])

    entry = compiled_entry(@provider, :coverage_adapter)

    assert {:error, {:invalid_router_via, :invalid}} =
             Compiler.validate_router([
               {Compiler.compiled_key(), %{coverage_adapter: entry}},
               {:via, :invalid}
             ])

    assert :ok =
             Compiler.validate_router([
               {Compiler.compiled_key(), %{coverage_adapter: entry}},
               {:via, [:coverage_adapter]}
             ])

    assert {:error, {:unknown_router_step, :missing}} =
             Compiler.validate_router([
               {Compiler.compiled_key(), %{coverage_adapter: entry}},
               {:via, [:coverage_adapter, :missing]}
             ])

    assert %{via: [:coverage_adapter], opts: []} =
             Compiler.preflight_rule_data!(
               %{label: :NO_DATA, via: [:coverage_adapter], opts: []},
               :agent
             )

    assert %{label: :UNCHANGED} =
             Compiler.preflight_rule_data!(%{label: :UNCHANGED}, :agent)

    assert Compiler.compile_router!(:owner, [via: [123]], []) == [via: [123]]

    assert Compiler.format_reason({:unknown_router_step, :missing}) =~ "unknown router via step"
    assert Compiler.format_reason({:reserved_router_adapter_id, :regex}) =~ "reserved"

    assert Compiler.format_reason({:invalid_router_adapter, String, :invalid}) =~
             "invalid router Adapter"

    assert Compiler.format_reason({:duplicate_router_adapter_id, :duplicate}) =~ "duplicate"
  end

  test "compiler validates descriptor values, failures, and macro options without leaking data" do
    key = {@descriptor_probe, :mode}
    on_exit(fn -> Process.delete(key) end)

    Process.put(key, {:return, %{descriptor() | contract: :future}})
    assert {:error, :invalid_descriptor} = Compiler.fetch_descriptor(@descriptor_probe)

    Process.put(key, {:return, %{descriptor() | accept: "invalid"}})
    assert {:error, {:invalid_accept, "invalid"}} = Compiler.fetch_descriptor(@descriptor_probe)

    Process.put(key, {:return, %{descriptor() | accept: 1, margin: 0}})

    assert {:ok, normalized} = Compiler.fetch_descriptor(@descriptor_probe)
    assert normalized.accept == 1.0
    assert normalized.margin == 0.0

    for {value, value_class} <- [
          {[], :list},
          {{:bad, :descriptor}, :tuple},
          {:bad_descriptor, :atom},
          {"bad descriptor", :binary},
          {2, :number},
          {self(), :other}
        ] do
      Process.put(key, {:return, value})

      assert {:error, {:invalid_descriptor, ^value_class}} =
               Compiler.fetch_descriptor(@descriptor_probe)
    end

    for {reason, reason_class} <- [
          {:down, :down},
          {{:private, :tuple}, :tuple},
          {%{private: true}, :map},
          {[:private], :list},
          {"private", :other}
        ] do
      Process.put(key, {:throw, reason})

      assert {:error, {:descriptor_failure, :throw, ^reason_class}} =
               Compiler.fetch_descriptor(@descriptor_probe)
    end

    Process.put(key, :valid)

    assert_raise ArgumentError, ~r/options must be a keyword list/, fn ->
      compile_module("""
      use Spectre.Router.Adapter, :invalid
      def evaluate(_request), do: :skip
      """)
    end

    assert_raise ArgumentError, ~r/unknown_options.*extra/s, fn ->
      compile_module("""
      use Spectre.Router.Adapter, id: :unknown_option, extra: true
      def evaluate(_request), do: :skip
      """)
    end

    integer_descriptor =
      compile_module("""
      use Spectre.Router.Adapter, id: :integer_descriptor, accept: 1, margin: 0
      def evaluate(_request), do: :skip
      """)

    assert {:ok, normalized} = Compiler.fetch_descriptor(integer_descriptor)
    assert normalized.accept == 1.0
    assert normalized.margin == 0.0

    error =
      assert_raise ArgumentError, fn ->
        Compiler.compile_router!(:owner, [via: [@provider, :unknown_step]], [])
      end

    assert error.message =~ "unknown router via step"
  end

  test "definition validation and dependency reports cover Skill and mounted scopes" do
    skill = %Definition{
      kind: :skill,
      id: :coverage_skill,
      rules: [
        %{label: :EMPTY, via: [], opts: []},
        %{label: :INVISIBLE, via: [:missing_adapter], opts: []},
        %{label: :DEGRADED, via: [:regex, :missing_adapter], opts: []}
      ]
    }

    assert %{
             errors: [
               %{
                 label: :INVISIBLE,
                 scope: {:skill, :coverage_skill},
                 status: :error,
                 unresolved: [:missing_adapter]
               }
             ],
             warnings: [
               %{
                 label: :DEGRADED,
                 scope: {:skill, :coverage_skill},
                 status: :warning,
                 unresolved: [:missing_adapter]
               }
             ]
           } = Compiler.dependency_report(skill, [])

    assert Compiler.dependency_report(skill) == Compiler.dependency_report(skill, [])

    assert :ok =
             Compiler.validate_definition(%Definition{
               kind: :skill,
               id: :empty_skill,
               rules: [%{label: :EMPTY, via: [], opts: []}]
             })

    mounted = %Definition{
      kind: :agent,
      skills: [
        %Mount{
          id: :mounted,
          module: SpectreRouterAdapterFailureContractTest.MountedSkill
        }
      ]
    }

    assert %{warnings: [%{scope: {:skill, :mounted}}]} =
             Compiler.dependency_report(mounted, [])

    invalid_via = %Definition{
      kind: :agent,
      rules: [%{label: :BAD_VIA, via: :invalid, opts: []}]
    }

    assert {:error, {:invalid_router_rule_via, :agent, :BAD_VIA, :invalid}} =
             Compiler.validate_definition(invalid_via)

    entry = compiled_entry(@provider, :coverage_adapter)

    invalid_data = %Definition{
      kind: :agent,
      router: [{Compiler.compiled_key(), %{coverage_adapter: entry}}],
      rules: [
        %{
          label: :BAD_DATA,
          owner: __MODULE__,
          via: [:coverage_adapter],
          opts: [coverage_adapter: self()]
        }
      ]
    }

    assert {:error,
            {:invalid_router_adapter_rule_data, :coverage_adapter, :agent, :BAD_DATA, _reason}} =
             Compiler.validate_definition(invalid_data)
  end

  test "conformance rejects malformed options, fixtures, callbacks, and result envelopes" do
    request = request("integer result")

    assert Conformance.contract_version() == 1

    assert failure(:options, :invalid_arguments) ==
             Conformance.run("not a module", request)

    assert failure(:options, :invalid_options) ==
             Conformance.run(@provider, request, [:invalid])

    assert failure(:options, {:unknown_options, [:unknown]}) ==
             Conformance.run(@provider, request, unknown: true)

    missing = Module.concat(__MODULE__, "Missing#{System.unique_integer([:positive])}")
    refute Code.ensure_loaded?(missing)

    assert {:error, {:router_adapter_conformance_failed, :descriptor, _reason}} =
             Conformance.run(missing, request)

    for {text, reason} <- [
          {"skip", :fixture_skipped},
          {"skip with reason", :fixture_skipped},
          {"declared error", :adapter_error},
          {"invalid envelope", :invalid_reply}
        ] do
      assert failure(:callback, reason) ==
               Conformance.run(@provider, %{request | text: text})
    end

    assert failure(:result, {:invalid_result, 0, :invalid_score}) ==
             Conformance.run(@provider, %{request | text: "invalid result"},
               router_adapter_timeout: 1_000
             )
  end

  test "conformance validates every privacy-scoped Request and RuleView field" do
    request = request("integer result")

    invalid_requests = [
      {%{request | text: nil}, :invalid_text},
      {%{request | meta: URI.parse("https://example.test")}, :invalid_meta},
      {%{request | recent_chat: nil}, :invalid_recent_chat},
      {%{request | current_flow: true}, :invalid_current_flow},
      {%{request | current_scope: true}, :invalid_current_scope},
      {%{request | rules: :invalid}, :invalid_rules},
      {%{request | rules: []}, :empty_rules}
    ]

    for {invalid, reason} <- invalid_requests do
      assert failure(:fixture, reason) == Conformance.run(@provider, invalid)
    end

    duplicate = %{request | rules: [rule_view(), rule_view()]}
    assert failure(:fixture, :duplicate_rule_ref) == Conformance.run(@provider, duplicate)

    assert failure(:fixture, :invalid_rule_view) ==
             Conformance.run(@provider, %{request | rules: [%RuleView{}]})

    assert failure(:fixture, :rule_must_be_a_rule_view) ==
             Conformance.run(@provider, %{request | rules: [%{}]})

    invalid_rules = [
      {%{rule_view() | ref: {:invalid, :ROUTE}, scope: :invalid}, :invalid_rule_scope},
      {%{rule_view() | opts: [:invalid]}, :invalid_rule_opts},
      {%{rule_view() | flow: true}, :invalid_rule_flow},
      {%{rule_view() | flow_path: [nil]}, :invalid_rule_flow_path},
      {%{rule_view() | global?: :invalid}, :invalid_rule_global},
      {%{rule_view() | data: self()}, :invalid_rule_data}
    ]

    for {invalid_rule, reason} <- invalid_rules do
      assert failure(:fixture, reason) ==
               Conformance.run(@provider, %{request | rules: [invalid_rule]})
    end

    scoped_rule = %{
      rule_view()
      | ref: {{:skill, :mounted}, :ROUTE},
        scope: {:skill, :mounted},
        flow: nil
    }

    assert {:ok, %{result_count: 1}} =
             Conformance.run(@provider, %{
               request
               | current_flow: nil,
                 current_scope: {:skill, :mounted},
                 rules: [scoped_rule]
             })
  end

  test "per-evaluation plans classify missing, malformed, and failing implementations" do
    missing = Module.concat(__MODULE__, "MissingPlan#{System.unique_integer([:positive])}")
    refute Code.ensure_loaded?(missing)

    assert_plan_unavailable(missing, :missing_plan, :module_unavailable)

    assert_plan_unavailable(
      SpectreRouterAdapterFailureContractTest.EvaluateOnly,
      :evaluate_only,
      :descriptor_callback_unavailable
    )

    assert_plan_unavailable(
      SpectreRouterAdapterFailureContractTest.DescriptorOnly,
      :descriptor_only,
      :evaluate_callback_unavailable
    )

    key = {@descriptor_probe, :mode}
    on_exit(fn -> Process.delete(key) end)

    for {reason, reason_class} <- [
          {:down, :down},
          {{:private, :tuple}, :tuple},
          {%{private: true}, :map},
          {[:private], :list},
          {"private", :other}
        ] do
      Process.put(key, {:throw, reason})

      assert_plan_unavailable(
        @descriptor_probe,
        :descriptor_probe,
        {:throw, reason_class}
      )
    end
  end

  test "Runner rejects unavailable plans and sanitizes pre-invocation and callback skips" do
    plan = available_plan()
    base = runner_context("integer result", plan)

    assert {:cont, halted} = Adapter.run(%{base | halted?: true}, :coverage_adapter)
    assert halted.halted?

    assert {:error, {:unknown_router_adapter, :unknown}} =
             Adapter.run(base, :unknown)

    assert {:error, :router_adapter_plan_unavailable} =
             Adapter.run(%{base | opts: []}, :coverage_adapter)

    assert {:cont, routed} = Adapter.run(base, :coverage_adapter)
    assert [%{score: 1.0, margin: 1.0, strength: :unsupported}] = routed.candidates

    for {text, reason} <- [
          {"skip with map", :map_skip},
          {"skip with opaque tuple", :router_adapter_failure},
          {"skip with opaque value", :router_adapter_failure}
        ] do
      assert {:cont, skipped} =
               text
               |> runner_context(plan)
               |> Adapter.run(:coverage_adapter)

      assert {:router_adapter_skip, :coverage_adapter, reason} in skipped.traces
    end
  end

  test "Adapter helpers and recent-chat fallbacks reject ambiguous public values" do
    assert Adapter.examples(nil) == []
    assert Adapter.examples("one") == ["one"]
    assert Adapter.examples(examples: ["one", nil]) == ["one"]

    assert Adapter.result({{:skill, :mounted}, :ROUTE}, 1) == %{
             rule: {{:skill, :mounted}, :ROUTE},
             score: 1
           }

    assert_raise ArgumentError, ~r/invalid router Adapter rule scope/, fn ->
      Adapter.result({{:skill, nil}, :ROUTE}, 0.5)
    end

    assert_raise ArgumentError, ~r/invalid router Adapter rule scope/, fn ->
      Adapter.result({:invalid, :ROUTE}, 0.5)
    end

    assert_raise ArgumentError, ~r/invalid router Adapter rule reference/, fn ->
      Adapter.result(:ROUTE, 0.5)
    end

    assert RecentChat.value(nil, []) == "none"

    assert RecentChat.put([], nil) == [recent_chat: "none"]

    state = %Spectre.State{
      data: %{chat_history: [%{user: "question", assistant: "answer"}]}
    }

    assert RecentChat.value(state, classifier_history_limit: 0) ==
             "User: question\nAssistant: answer"

    state = %{state | data: %{chat_history: [:malformed]}}
    assert RecentChat.value(state, []) == "User: \nAssistant: "
  end

  test "Doctor diagnostics distinguish invalid plans, degraded rules, and loader failures" do
    assert Enum.all?(Diagnostics.skipped(:agent_not_requested), fn check ->
             check.status == :skipped and check.code == :agent_not_requested
           end)

    invalid_plan = %Definition{router: [via: [:unknown_step]]}
    [inventory | _checks] = Diagnostics.checks(invalid_plan, [])
    assert inventory.status == :error
    assert inventory.code == :unknown_router_step

    degraded = %Definition{
      router: [via: [:regex]],
      rules: [%{label: :DEGRADED, via: [:regex, :missing_adapter], opts: []}]
    }

    checks = Map.new(Diagnostics.checks(degraded, []), &{&1.id, &1})
    assert checks["router.adapter_dependencies"].status == :warning
    assert checks["router.adapter_dependencies"].details.warning_count == 1

    missing = Module.concat(__MODULE__, "MissingSkill#{System.unique_integer([:positive])}")

    broken = %Definition{
      router: [via: [:regex]],
      skills: [%Mount{id: :missing, module: missing}]
    }

    [broken_inventory | _checks] = Diagnostics.checks(broken, [])
    assert broken_inventory.status == :error
    assert broken_inventory.code == :router_adapter_diagnostics_exception
  end

  defp request(text) do
    %Request{
      text: text,
      meta: %{},
      current_flow: nil,
      current_scope: nil,
      recent_chat: "none",
      rules: [rule_view()]
    }
  end

  defp rule_view do
    %RuleView{
      ref: {:agent, :ROUTE},
      label: :ROUTE,
      scope: :agent,
      flow: nil,
      flow_path: [],
      global?: false,
      data: [examples: ["route"]],
      opts: [coverage_adapter: ["route"]]
    }
  end

  defp runner_context(text, plan) do
    rule = %Rule{
      label: :ROUTE,
      scope: :agent,
      handler: {:reply, :route, []},
      via: [:coverage_adapter],
      opts: [coverage_adapter: ["route"], strength: :unsupported]
    }

    %RouterContext{
      input: Spectre.Input.new(text),
      host_context: nil,
      opts: [{Compiler.compiled_key(), plan}],
      labels: [:ROUTE],
      rules: [rule]
    }
  end

  defp available_plan do
    entry =
      @provider
      |> compiled_entry(:coverage_adapter)
      |> Map.put(:availability, :available)

    %{entries: %{coverage_adapter: entry}, diagnostics: []}
  end

  defp compiled_entry(module, id) do
    descriptor = module.__spectre_router_adapter__()
    %{id: id, module: module, descriptor: descriptor, order: 0}
  end

  defp descriptor do
    %{
      contract: 1,
      id: :descriptor_probe,
      accept: 0.0,
      margin: nil,
      strength: :weak
    }
  end

  defp assert_plan_unavailable(module, id, expected_failure) do
    entry = %{id: id, module: module, descriptor: descriptor(), order: 0}

    assert {:ok, plan} = Plan.build(%{id => entry}, via: [id])

    assert [
             {:router_adapter_descriptor_unavailable, ^id, ^module, ^expected_failure}
           ] = Plan.diagnostics(plan)
  end

  defp failure(phase, reason),
    do: {:error, {:router_adapter_conformance_failed, phase, reason}}

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
