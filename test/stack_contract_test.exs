defmodule SpectreStackContractTest.Provider do
  @moduledoc false

  @behaviour Spectre.Action.Provider

  @impl Spectre.Action.Provider
  def actions(_opts), do: []

  @impl Spectre.Action.Provider
  def execute(_action, _ctx, _opts), do: {:ok, :legacy}
end

defmodule SpectreStackContractTest.Planner do
  @moduledoc false
end

defmodule SpectreStackContractTest.StackExtension do
  @moduledoc false

  @behaviour Spectre.Extension

  @impl Spectre.Extension
  def id, do: :inference

  @impl Spectre.Extension
  def api_version, do: 1

  @impl Spectre.Extension
  def compile(_owner, opts), do: {:ok, Keyword.fetch!(opts, :stack_config)}

  @impl Spectre.Extension
  def agent_config(config), do: [inference_stack: config]
end

defmodule SpectreStackContractTest.LegacyExtension do
  @moduledoc false

  @behaviour Spectre.Extension

  @impl Spectre.Extension
  def id, do: :legacy

  @impl Spectre.Extension
  def action_providers(opts) do
    [{:legacy, SpectreStackContractTest.Provider, opts}]
  end

  @impl Spectre.Extension
  def action_planner(opts), do: {SpectreStackContractTest.Planner, opts}
end

defmodule SpectreStackContractTest.InferencePackage do
  @moduledoc false

  alias Spectre.Stack.DSL

  use Spectre.Stack.Installable,
    id: :inference,
    version: "0.1.2",
    contract: 1,
    spectre: ">= 0.1.2 and < 0.3.0",
    provides: [{:service, :inference}],
    operations: [{:inference, :complete}],
    resources: [:client],
    agent_extensions: [SpectreStackContractTest.StackExtension],
    dsl: __MODULE__

  @impl Spectre.Stack.Installable
  def compile(opts, block, caller) do
    declarations =
      DSL.compile!(block, caller,
        provider: 2,
        model: 2
      )

    {:ok, %{options: opts, declarations: declarations}}
  end

  @impl Spectre.Stack.Installable
  def child_specs(installation, opts) do
    state = %{configuration: installation.config, runtime: opts}
    [{:client, {Agent, fn -> state end}}]
  end
end

defmodule SpectreStackContractTest.ActionPackage do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :job_actions,
    version: "0.1.2",
    contract: 1,
    spectre: ">= 0.1.2 and < 0.3.0",
    requires: [{:service, :inference, "~> 0.1.2"}],
    provides: [:move_selection],
    actions: [{:jobs, :submit}]
end

defmodule SpectreStackContractTest.FirstSearchPackage do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :first_search,
    version: "0.1.2",
    contract: 1,
    spectre: ">= 0.1.2 and < 0.3.0",
    actions: [{:first, :search}]
end

defmodule SpectreStackContractTest.SecondSearchPackage do
  @moduledoc false

  use Spectre.Stack.Installable,
    id: :second_search,
    version: "0.1.2",
    contract: 1,
    spectre: ">= 0.1.2 and < 0.3.0",
    actions: [{:second, :search}]
end

defmodule SpectreStackContractTest.Stack do
  @moduledoc false

  use Spectre.Stack, id: :contract_stack

  # Deliberately declared before its dependency; the resolved definition is
  # topologically ordered.
  install(SpectreStackContractTest.ActionPackage)

  install SpectreStackContractTest.InferencePackage, environment: :test do
    provider(:openrouter, SpectreStackContractTest.Provider)
    model(:fast, id: "small-model")
  end

  install(SpectreStackContractTest.FirstSearchPackage)
  install(SpectreStackContractTest.SecondSearchPackage)
end

defmodule SpectreStackContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreStackContractTest.Stack
end

defmodule SpectreStackContractTest.JournalStore do
  @moduledoc false

  @behaviour Spectre.Journal.Store

  @impl true
  def append(record, opts) do
    send(Keyword.fetch!(opts, :pid), {:stack_journal_record, record})
    :ok
  end
end

defmodule SpectreStackContractTest do
  use ExUnit.Case, async: true

  @dynamic_modules %{
    "MissingDependencyPackage" => [
      SpectreStackContractTest.Dynamic.MissingDependencyPackage
    ],
    "MissingDependencyStack" => [SpectreStackContractTest.Dynamic.MissingDependencyStack],
    "IncompatiblePackage" => [SpectreStackContractTest.Dynamic.IncompatiblePackage],
    "IncompatibleStack" => [SpectreStackContractTest.Dynamic.IncompatibleStack],
    "CycleFirst" => [SpectreStackContractTest.Dynamic.CycleFirst],
    "CycleSecond" => [SpectreStackContractTest.Dynamic.CycleSecond],
    "CycleStack" => [SpectreStackContractTest.Dynamic.CycleStack],
    "DuplicateFirst" => [
      SpectreStackContractTest.Dynamic.DuplicateFirst1,
      SpectreStackContractTest.Dynamic.DuplicateFirst2,
      SpectreStackContractTest.Dynamic.DuplicateFirst3
    ],
    "DuplicateSecond" => [
      SpectreStackContractTest.Dynamic.DuplicateSecond1,
      SpectreStackContractTest.Dynamic.DuplicateSecond2,
      SpectreStackContractTest.Dynamic.DuplicateSecond3
    ],
    "DuplicateStack" => [
      SpectreStackContractTest.Dynamic.DuplicateStack1,
      SpectreStackContractTest.Dynamic.DuplicateStack2,
      SpectreStackContractTest.Dynamic.DuplicateStack3
    ],
    "DuplicatePackageStack" => [SpectreStackContractTest.Dynamic.DuplicatePackageStack],
    "CrashingManifest" => [SpectreStackContractTest.Dynamic.CrashingManifest],
    "CrashingCompiler" => [SpectreStackContractTest.Dynamic.CrashingCompiler],
    "CrashingCompilerStack" => [SpectreStackContractTest.Dynamic.CrashingCompilerStack],
    "ThrowingCompiler" => [SpectreStackContractTest.Dynamic.ThrowingCompiler],
    "ThrowingCompilerStack" => [SpectreStackContractTest.Dynamic.ThrowingCompilerStack],
    "MalformedCompiler" => [SpectreStackContractTest.Dynamic.MalformedCompiler],
    "MalformedCompilerStack" => [SpectreStackContractTest.Dynamic.MalformedCompilerStack],
    "PidConfig" => [SpectreStackContractTest.Dynamic.PidConfig],
    "PidConfigStack" => [SpectreStackContractTest.Dynamic.PidConfigStack],
    "PortConfig" => [SpectreStackContractTest.Dynamic.PortConfig],
    "PortConfigStack" => [SpectreStackContractTest.Dynamic.PortConfigStack],
    "ReferenceConfig" => [SpectreStackContractTest.Dynamic.ReferenceConfig],
    "ReferenceConfigStack" => [SpectreStackContractTest.Dynamic.ReferenceConfigStack],
    "FunctionConfig" => [SpectreStackContractTest.Dynamic.FunctionConfig],
    "FunctionConfigStack" => [SpectreStackContractTest.Dynamic.FunctionConfigStack],
    "TamperedExport" => [SpectreStackContractTest.Dynamic.TamperedExport],
    "InvalidDSLStack" => [SpectreStackContractTest.Dynamic.InvalidDSLStack],
    "UndeclaredRuntimePackage" => [
      SpectreStackContractTest.Dynamic.UndeclaredRuntimePackage
    ],
    "UndeclaredRuntimeStack" => [SpectreStackContractTest.Dynamic.UndeclaredRuntimeStack],
    "StackSkill" => [SpectreStackContractTest.Dynamic.StackSkill],
    "UnknownStackAgent" => [SpectreStackContractTest.Dynamic.UnknownStackAgent]
  }

  alias Spectre.Action.Provider.Mount, as: ProviderMount
  alias Spectre.Journal.Record
  alias Spectre.Journal.Recorder
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Ref
  alias Spectre.Stack.Runtime
  alias Spectre.Stack.Value

  alias SpectreStackContractTest.Agent, as: StackAgent
  alias SpectreStackContractTest.InferencePackage
  alias SpectreStackContractTest.LegacyExtension
  alias SpectreStackContractTest.Provider
  alias SpectreStackContractTest.Stack, as: TestStack

  test "compiles package-local DSL into an immutable, ordered definition" do
    definition = Definition.fetch!(TestStack)

    assert definition.id == :contract_stack
    assert definition.owner == TestStack
    assert definition.version == 1
    assert definition.contract == 1
    assert is_binary(definition.digest)
    assert byte_size(definition.digest) == 64

    assert Enum.map(definition.installations, & &1.package.id) == [
             :inference,
             :job_actions,
             :first_search,
             :second_search
           ]

    assert {:ok, inference} = Definition.installation(definition, :inference)

    assert inference.config == %{
             options: [environment: :test],
             declarations: [
               provider: [:openrouter, Provider],
               model: [:fast, [id: "small-model"]]
             ]
           }

    assert inference.digest ==
             Definition.installation(TestStack, :inference) |> elem(1) |> Map.fetch!(:digest)

    assert TestStack.__spectre_stack_manifest__() == Definition.manifest(definition)
  end

  test "publishes a versioned executable installable contract" do
    assert V1.version() == 1
    assert {:ok, package} = V1.verify_installable(InferencePackage)
    assert package.id == :inference
    assert package.module == InferencePackage
    assert package.version == "0.1.2"
    assert package.contract == 1
    assert package.spectre == ">= 0.1.2 and < 0.3.0"
    assert package.agent_extensions == [SpectreStackContractTest.StackExtension]
    assert is_binary(package.digest)
    assert V1.assert_installable!(InferencePackage) == package

    assert {:ok, verified} =
             V1.verify_manifest(InferencePackage, Map.from_struct(package))

    assert verified.digest == package.digest
  end

  test "resolves closed logical references with version and digest fences" do
    assert {:ok, %Ref{} = package_ref} =
             Spectre.Stack.resolve(TestStack, :package, :inference)

    assert package_ref.stack == TestStack
    assert package_ref.installation == :inference
    assert package_ref.package == :inference
    assert package_ref.version == "0.1.2"
    assert Ref.valid?(package_ref)

    assert {:ok, %Ref{kind: :service, id: :inference}} =
             Definition.resolve(TestStack, :service, :inference)

    assert {:ok, %Ref{kind: :operation, id: {:inference, :complete}}} =
             Definition.resolve(TestStack, :operation, {:inference, :complete})

    assert {:ok, %Ref{kind: :action, id: {:jobs, :submit}}} =
             Definition.resolve(TestStack, :action, {:jobs, :submit})

    assert {:error, {:unknown_stack_capability, :action, :missing}} =
             Definition.resolve(TestStack, :action, :missing)
  end

  test "allows the same action name under different canonical providers" do
    assert {:ok, %Ref{package: :first_search}} =
             Definition.resolve(TestStack, :action, {:first, :search})

    assert {:ok, %Ref{package: :second_search}} =
             Definition.resolve(TestStack, :action, {:second, :search})
  end

  test "an installed action remains invisible until a later binding authorizes it" do
    definition = Spectre.Definition.fetch!(StackAgent)

    assert definition.stack == TestStack

    assert Enum.map(definition.stack_refs, & &1.package) == [
             :inference,
             :job_actions,
             :first_search,
             :second_search
           ]

    assert {:ok, mount} = Spectre.Extension.fetch(StackAgent, :inference)
    assert mount.module == SpectreStackContractTest.StackExtension
    assert {:ok, stack_config} = Spectre.Stack.config(StackAgent, :inference)
    assert mount.compiled == stack_config
    assert definition.config[:inference_stack] == mount.compiled

    assert Spectre.ActionConfig.providers(StackAgent) == []
    assert Spectre.ActionConfig.planner(StackAgent) == nil
  end

  test "journal records carry only immutable Stack identity and digests" do
    result = %Spectre.Result{
      state: %Spectre.State{},
      events: [
        %{
          type: :effect_failed,
          kind: :pulse,
          name: :send,
          effect_id: "effect-1",
          error: :not_sent
        }
      ]
    }

    opts = [
      turn_id: "stack-journal-turn",
      trace_id: "stack-journal-trace",
      journal:
        {SpectreStackContractTest.JournalStore,
         [
           events: [:execution],
           mode: :sync,
           store_opts: [pid: self()]
         ]}
    ]

    assert {:ok, ^result} = Recorder.record_result(result, %{agent: StackAgent, opts: opts})

    assert_receive {:stack_journal_record, %Record{} = record}
    stack = record.metadata.stack
    definition = Definition.fetch!(TestStack)

    assert stack.id == :contract_stack
    assert stack.owner == TestStack
    assert stack.digest == definition.digest

    assert Enum.map(stack.installations, & &1.package) == [
             :inference,
             :job_actions,
             :first_search,
             :second_search
           ]

    assert Enum.all?(stack.installations, fn installation ->
             installation.version == "0.1.2" and
               is_binary(installation.digest) and
               map_size(installation) == 4
           end)

    refute inspect(stack) =~ "small-model"
    refute inspect(stack) =~ "environment"
  end

  test "starts isolated caller-owned runtimes and resolves only matching resource refs" do
    assert {:ok, %Ref{} = ref} = Definition.resolve(TestStack, :resource, :client)

    assert {:ok, first} =
             Spectre.Stack.start_link(TestStack,
               packages: [inference: [token: "first-runtime"]]
             )

    assert {:ok, second} =
             Runtime.start_link(TestStack,
               packages: %{inference: [token: "second-runtime"]}
             )

    assert {:ok, first_client} = Runtime.resolve(first, ref)
    assert {:ok, second_client} = Runtime.resolve(second, ref)
    refute first_client == second_client

    assert Agent.get(first_client, & &1.runtime) == [token: "first-runtime"]
    assert Agent.get(second_client, & &1.runtime) == [token: "second-runtime"]

    stale = %{ref | stack_digest: String.duplicate("0", 64)}
    assert {:error, {:unknown_stack_runtime_ref, ^stale}} = Runtime.resolve(first, stale)

    wrong_package = %{ref | package: :other_package}
    refute Ref.valid?(%{ref | package: nil})
    refute Ref.valid?(%{ref | stack_digest: ""})

    assert {:error, {:unknown_stack_runtime_ref, ^wrong_package}} =
             Runtime.resolve(first, wrong_package)

    assert {:ok, package_ref} = Definition.resolve(TestStack, :package, :inference)

    assert {:error, {:stack_runtime_requires_resource_ref, :package}} =
             Runtime.resolve(first, package_ref)

    assert :ok = Supervisor.stop(first)
    assert :ok = Supervisor.stop(second)
  end

  test "runtime child specs are fenced by resource Ref and contain no global name" do
    assert {:ok, [child_spec]} =
             Runtime.child_specs(TestStack, packages: [inference: [token: "runtime"]])

    assert {:ok, ref} = Definition.resolve(TestStack, :resource, :client)
    assert child_spec.id == Ref.key(ref)
    refute Keyword.has_key?(child_spec.start |> elem(2), :name)
  end

  test "converts Extension and Provider mounts into explicit legacy installations" do
    extension_mount = Spectre.Extension.Mount.new(LegacyExtension, namespace: :legacy)
    extension = Installation.from_extension_mount(extension_mount)

    assert extension.legacy?
    assert extension.id == :legacy
    assert extension.package.metadata == %{legacy: :extension}

    assert [%ProviderMount{id: :legacy, module: Provider}] =
             extension.adapters.action_providers

    assert {SpectreStackContractTest.Planner, [namespace: :legacy]} =
             extension.adapters.action_planner

    provider_mount = ProviderMount.new({:remote, :jobs}, Provider, source: :legacy)
    provider = Installation.from_provider_mount(provider_mount)

    assert provider.legacy?
    assert provider.package.id == {:action_provider, {:remote, :jobs}}
    assert provider.adapters.action_providers == [provider_mount]
  end

  test "rejects missing, incompatible, and cyclic package dependencies" do
    missing_package = unique_module("MissingDependencyPackage")
    missing_stack = unique_module("MissingDependencyStack")

    compile_module("""
    defmodule #{inspect(missing_package)} do
      use Spectre.Stack.Installable,
        id: :missing_dependency,
        version: "0.1.2",
        spectre: ">= 0.1.2 and < 0.3.0",
        requires: [{:package, :not_installed}]
    end
    """)

    assert_raise ArgumentError, ~r/requires missing package :not_installed/, fn ->
      compile_module("""
      defmodule #{inspect(missing_stack)} do
        use Spectre.Stack
        install #{inspect(missing_package)}
      end
      """)
    end

    incompatible_package = unique_module("IncompatiblePackage")
    incompatible_stack = unique_module("IncompatibleStack")

    compile_module("""
    defmodule #{inspect(incompatible_package)} do
      use Spectre.Stack.Installable,
        id: :future,
        version: "2.0.0",
        spectre: "~> 2.0"
    end
    """)

    assert_raise ArgumentError, ~r/requires Spectre ~> 2.0/, fn ->
      compile_module("""
      defmodule #{inspect(incompatible_stack)} do
        use Spectre.Stack
        install #{inspect(incompatible_package)}
      end
      """)
    end

    first = unique_module("CycleFirst")
    second = unique_module("CycleSecond")
    cycle_stack = unique_module("CycleStack")

    compile_module("""
    defmodule #{inspect(first)} do
      use Spectre.Stack.Installable,
        id: :cycle_first,
        version: "0.1.2",
        spectre: ">= 0.1.2 and < 0.3.0",
        provides: [{:service, :cycle_first}],
        requires: [{:service, :cycle_second}]
    end

    defmodule #{inspect(second)} do
      use Spectre.Stack.Installable,
        id: :cycle_second,
        version: "0.1.2",
        spectre: ">= 0.1.2 and < 0.3.0",
        provides: [{:service, :cycle_second}],
        requires: [{:service, :cycle_first}]
    end
    """)

    assert_raise ArgumentError, ~r/cyclic Stack package dependency/, fn ->
      compile_module("""
      defmodule #{inspect(cycle_stack)} do
        use Spectre.Stack
        install #{inspect(first)}
        install #{inspect(second)}
      end
      """)
    end
  end

  test "rejects duplicate package, service, operation, and action ownership" do
    for {field, entry, message} <- [
          {:provides, "[{:service, :shared}]", "duplicate Stack service ownership"},
          {:operations, "[{:shared, :read}]", "duplicate Stack operation ownership"},
          {:actions, "[{:shared, :write}]", "duplicate Stack action ownership"}
        ] do
      first = unique_module("DuplicateFirst")
      second = unique_module("DuplicateSecond")
      stack = unique_module("DuplicateStack")

      compile_module("""
      defmodule #{inspect(first)} do
        use Spectre.Stack.Installable,
          id: #{inspect(first)},
          version: "0.1.2",
          spectre: ">= 0.1.2 and < 0.3.0",
          #{field}: #{entry}
      end

      defmodule #{inspect(second)} do
        use Spectre.Stack.Installable,
          id: #{inspect(second)},
          version: "0.1.2",
          spectre: ">= 0.1.2 and < 0.3.0",
          #{field}: #{entry}
      end
      """)

      assert_raise ArgumentError, ~r/#{message}/, fn ->
        compile_module("""
        defmodule #{inspect(stack)} do
          use Spectre.Stack
          install #{inspect(first)}
          install #{inspect(second)}
        end
        """)
      end
    end

    duplicate_stack = unique_module("DuplicatePackageStack")

    assert_raise ArgumentError, ~r/duplicate Stack package: :inference/, fn ->
      compile_module("""
      defmodule #{inspect(duplicate_stack)} do
        use Spectre.Stack
        install SpectreStackContractTest.InferencePackage
        install SpectreStackContractTest.InferencePackage, as: :other
      end
      """)
    end
  end

  test "contains malformed, crashing, and throwing installable callbacks" do
    crashing_manifest = unique_module("CrashingManifest")

    compile_module("""
    defmodule #{inspect(crashing_manifest)} do
      @behaviour Spectre.Stack.Installable
      def manifest, do: raise("manifest")
    end
    """)

    assert {:error,
            {:stack_callback_exception, ^crashing_manifest, :manifest, RuntimeError, "manifest"}} =
             V1.verify_installable(crashing_manifest)

    for {suffix, body, expected} <- [
          {"CrashingCompiler", ~s(raise "compile"), "stack_callback_exception"},
          {"ThrowingCompiler", ~s(throw :compile), "stack_callback_failure"},
          {"MalformedCompiler", ":invalid", "must return a map or keyword list"}
        ] do
      package = unique_module(suffix)
      stack = unique_module("#{suffix}Stack")

      compile_module("""
      defmodule #{inspect(package)} do
        use Spectre.Stack.Installable,
          id: #{inspect(package)},
          version: "0.1.2",
          spectre: ">= 0.1.2 and < 0.3.0"

        def compile(_opts, _block, _caller), do: #{body}
      end
      """)

      assert_raise ArgumentError, ~r/#{expected}/, fn ->
        compile_module("""
        defmodule #{inspect(stack)} do
          use Spectre.Stack
          install #{inspect(package)}
        end
        """)
      end
    end
  end

  test "rejects runtime handles and functions in compiled definitions" do
    for {suffix, value} <- [
          {"PidConfig", "self()"},
          {"PortConfig", "Port.open({:spawn, \"true\"}, [])"},
          {"ReferenceConfig", "make_ref()"},
          {"FunctionConfig", "fn -> :unsafe end"}
        ] do
      package = unique_module(suffix)
      stack = unique_module("#{suffix}Stack")

      compile_module("""
      defmodule #{inspect(package)} do
        use Spectre.Stack.Installable,
          id: #{inspect(package)},
          version: "0.1.2",
          spectre: ">= 0.1.2 and < 0.3.0"

        def compile(_opts, _block, _caller), do: {:ok, %{unsafe: #{value}}}
      end
      """)

      assert_raise ArgumentError, ~r/cannot contain a PID, port, reference, or function/, fn ->
        compile_module("""
        defmodule #{inspect(stack)} do
          use Spectre.Stack
          install #{inspect(package)}
        end
        """)
      end
    end

    refute Value.portable?([:proper | :improper])
  end

  test "rejects altered definitions and exported manifests before runtime use" do
    definition = Definition.fetch!(TestStack)
    tampered = %{definition | digest: String.duplicate("0", 64)}

    assert {:error, {:invalid_stack_runtime, message}} = Runtime.child_specs(tampered)
    assert message =~ "stack_definition_integrity_mismatch"

    fake_stack = unique_module("TamperedExport")

    compile_module("""
    defmodule #{inspect(fake_stack)} do
      def __spectre_stack_definition__ do
        definition =
          Spectre.Stack.Definition.fetch!(SpectreStackContractTest.Stack)

        %{definition | owner: __MODULE__}
      end

      def __spectre_stack_manifest__ do
        Spectre.Stack.Definition.manifest(__spectre_stack_definition__())
      end
    end
    """)

    assert {:error,
            {:invalid_stack_definition, ^fake_stack, :stack_definition_integrity_mismatch}} =
             Definition.fetch(fake_stack)
  end

  test "rejects unknown local DSL forms and malformed runtime resources" do
    invalid_dsl_stack = unique_module("InvalidDSLStack")

    assert_raise ArgumentError, ~r/unknown Stack package declaration/, fn ->
      compile_module("""
      defmodule #{inspect(invalid_dsl_stack)} do
        use Spectre.Stack

        install SpectreStackContractTest.InferencePackage do
          secret_global :not_allowed
        end
      end
      """)
    end

    undeclared_package = unique_module("UndeclaredRuntimePackage")
    undeclared_stack = unique_module("UndeclaredRuntimeStack")

    compile_module("""
    defmodule #{inspect(undeclared_package)} do
      use Spectre.Stack.Installable,
        id: :undeclared_runtime,
        version: "0.1.2",
        spectre: ">= 0.1.2 and < 0.3.0"

      def child_specs(_installation, _opts) do
        [{:not_declared, {Agent, fn -> :ok end}}]
      end
    end

    defmodule #{inspect(undeclared_stack)} do
      use Spectre.Stack
      install #{inspect(undeclared_package)}
    end
    """)

    assert {:error, {:undeclared_stack_resource, :undeclared_runtime, :not_declared}} =
             Runtime.child_specs(undeclared_stack)
  end

  test "rejects Skill-owned Stack configuration without loading an Agent Stack" do
    skill = unique_module("StackSkill")

    assert_raise ArgumentError, ~r/stack/, fn ->
      compile_module("""
      defmodule #{inspect(skill)} do
        use Spectre.Skill, stack: SpectreStackContractTest.Stack
      end
      """)
    end

    agent = unique_module("UnknownStackAgent")

    assert_raise ArgumentError, ~r/cannot bind Spectre Stack/, fn ->
      compile_module("""
      defmodule #{inspect(agent)} do
        use Spectre.Agent, stack: Missing.Stack
      end
      """)
    end

    assert {:error, {:unknown_stack, Missing.Stack}} = Definition.fetch(Missing.Stack)
  end

  defp compile_module(source), do: Code.compile_string(source)

  defp unique_module(suffix) do
    modules = Map.fetch!(@dynamic_modules, suffix)
    counter_key = {__MODULE__, :dynamic_module_counter, suffix}
    index = Process.get(counter_key, 0)
    Process.put(counter_key, index + 1)
    Enum.fetch!(modules, index)
  end
end
