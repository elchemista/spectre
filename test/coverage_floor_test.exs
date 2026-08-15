defmodule SpectreCoverageFloorTest.BasicAgent do
  @moduledoc false
  use Spectre.Agent

  flow :coverage_floor do
    on :PING, regex: ~r/^ping$/ do
      run(:pong)
    end
  end

  def pong(_input, _ctx), do: "pong"
end

defmodule SpectreCoverageFloorTest.BasicSkill do
  @moduledoc false
  use Spectre.Skill
end

defmodule SpectreCoverageFloorTest.UnknownStackAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      id: :unknown_stack_agent,
      owner: __MODULE__,
      stack: SpectreCoverageFloorTest.UnknownStack
    }
  end
end

defmodule SpectreCoverageFloorTest.BadExtension do
  @moduledoc false
  def api_version, do: :invalid
end

defmodule SpectreCoverageFloorTest.ClassifierAdapter do
  @moduledoc false

  def download(_model, opts) do
    case Keyword.get(opts, :adapter_mode, :ok) do
      :missing -> {:error, {:missing_dependency, :ex_fastembed}}
      :error -> {:error, :download_failed}
      _other -> {:ok, 2}
    end
  end

  def load(_model, opts) do
    case Keyword.get(opts, :adapter_mode, :ok) do
      :missing -> {:error, {:missing_dependency, :ex_fastembed}}
      :error -> {:error, :load_failed}
      _other -> {:ok, 2}
    end
  end

  def embed(text, opts) do
    if Keyword.get(opts, :adapter_mode) == :embed_error and String.contains?(text, "fail") do
      {:error, :embed_failed}
    else
      {:ok, if(String.contains?(text, "alpha"), do: [1.0, 0.0], else: [0.0, 1.0])}
    end
  end
end

defmodule SpectreCoverageFloorTest.DispatcherHandler do
  @moduledoc false
  @behaviour Spectre.Turn.Dispatcher

  @impl true
  def deliver_reply(text, _result, _opts), do: {:ok, text}
end

defmodule SpectreCoverageFloorTest.FakeDynamicSupervisor do
  @moduledoc false
  use GenServer

  def start_link(replies), do: GenServer.start_link(__MODULE__, replies)

  @impl true
  def init(replies), do: {:ok, replies}

  @impl true
  def handle_call({:start_child, _child_spec}, _from, [reply | rest]) do
    {:reply, materialize(reply), rest}
  end

  defp materialize({:self, info}), do: {:ok, self(), info}
  defp materialize({:already_started, pid}), do: {:error, {:already_started, pid}}

  defp materialize({:register_then_error, registry, key, reason}) do
    {:ok, _owner} = Registry.register(registry, key, :race_winner)
    {:error, reason}
  end

  defp materialize(reply), do: reply
end

defmodule SpectreCoverageFloorTest.GuardCallbacks do
  @moduledoc false

  def allow_one(_action), do: :ok
  def reject_one(_action), do: {:error, :rejected}
end

defmodule SpectreCoverageFloorTest.GuardAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      id: :coverage_guard_agent,
      owner: __MODULE__,
      before_actions: [
        %{action: :mfa_one, run: {SpectreCoverageFloorTest.GuardCallbacks, :allow_one}},
        %{action: :mfa_error, run: {SpectreCoverageFloorTest.GuardCallbacks, :reject_one}},
        %{action: :missing, run: {SpectreCoverageFloorTest.GuardCallbacks, :missing}},
        %{action: :fun_two, run: fn _action, _ctx -> :allow end},
        %{action: :fun_one, run: fn _action -> {:suppress, "one"} end},
        %{action: :invalid, run: 123}
      ]
    }
  end
end

defmodule SpectreCoverageFloorTest.NoCompilePackage do
  @moduledoc false

  def manifest do
    [id: :no_compile, version: "1.0.0", contract: 1]
  end
end

defmodule SpectreCoverageFloorTest.InvalidManifestPackage do
  @moduledoc false
  def manifest, do: :invalid
end

defmodule SpectreCoverageFloorTest.ContractTwoPackage do
  @moduledoc false
  def manifest, do: [id: :contract_two, version: "1.0.0", contract: 2]
end

defmodule SpectreCoverageFloorTest.InvalidCompilerPackage do
  @moduledoc false
  def manifest, do: [id: :invalid_compiler, version: "1.0.0", contract: 1]
  def compile(_opts, _block, _caller), do: 42
end

defmodule SpectreCoverageFloorTest.ChildSpecsPackage do
  @moduledoc false

  def manifest do
    [id: :children, version: "1.0.0", contract: 1, resources: [:client]]
  end

  def child_specs(_installation, opts) do
    case Keyword.get(opts, :mode, :plain) do
      :plain ->
        [{:client, {Agent, fn -> :ready end}}]

      :ok ->
        {:ok, [{:client, {Agent, fn -> :ready end}}]}

      :error ->
        {:error, :child_specs_failed}

      :raise ->
        raise ArgumentError, "bad children"

      :invalid ->
        :invalid

      :invalid_entry ->
        [:invalid]

      :invalid_child ->
        [{:client, :invalid_child_spec}]

      :duplicate ->
        [
          {:client, {Agent, fn -> :first end}},
          {:client, {Agent, fn -> :second end}}
        ]
    end
  end
end

defmodule SpectreCoverageFloorTest.StackFixture do
  @moduledoc false

  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Package

  def package(id, attrs \\ %{}) do
    defaults = %{
      id: id,
      version: "1.0.0",
      contract: 1,
      spectre: ">= 0.0.0"
    }

    Package.new!(SpectreCoverageFloorTest.NoCompilePackage, Map.merge(defaults, Map.new(attrs)))
  end

  def installation(id, package, attrs \\ %{}) do
    Installation.build!(
      id,
      package,
      Map.get(attrs, :config, %{}),
      Map.get(attrs, :adapters, %{}),
      Map.get(attrs, :legacy?, false)
    )
  end

  def bound_definition(owner \\ SpectreCoverageFloorTest.BoundStack) do
    package = package(:bound_package, %{resources: [:client]})
    installation = installation(:local_bound, package)

    Definition.new!(
      id: :bound_stack,
      owner: owner,
      installations: [installation]
    )
  end

  def runtime_definition do
    package =
      Package.new!(SpectreCoverageFloorTest.ChildSpecsPackage, %{
        id: :children,
        version: "1.0.0",
        contract: 1,
        resources: [:client]
      })

    installation = installation(:children, package)

    Definition.new!(
      id: :runtime_stack,
      owner: SpectreCoverageFloorTest.RuntimeStack,
      installations: [installation]
    )
  end
end

defmodule SpectreCoverageFloorTest.BoundStack do
  @moduledoc false

  def __spectre_stack_definition__ do
    SpectreCoverageFloorTest.StackFixture.bound_definition(__MODULE__)
  end

  def __spectre_stack_manifest__ do
    __MODULE__
    |> SpectreCoverageFloorTest.StackFixture.bound_definition()
    |> Spectre.Stack.Definition.manifest()
  end
end

defmodule SpectreCoverageFloorTest.BoundAgent do
  @moduledoc false

  def __spectre_definition__ do
    definition = SpectreCoverageFloorTest.BoundStack.__spectre_stack_definition__()
    {:ok, ref} = Spectre.Stack.Definition.resolve(definition, :package, :bound_package)

    %Spectre.Definition{
      id: :bound_agent,
      owner: __MODULE__,
      stack: SpectreCoverageFloorTest.BoundStack,
      stack_refs: [ref]
    }
  end
end

defmodule SpectreCoverageFloorTest.UnboundAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{
      id: :unbound_agent,
      owner: __MODULE__,
      stack: SpectreCoverageFloorTest.BoundStack,
      stack_refs: []
    }
  end
end

defmodule SpectreCoverageFloorTest.StaleBoundAgent do
  @moduledoc false

  def __spectre_definition__ do
    definition = SpectreCoverageFloorTest.BoundStack.__spectre_stack_definition__()
    {:ok, ref} = Spectre.Stack.Definition.resolve(definition, :package, :bound_package)

    %Spectre.Definition{
      id: :stale_bound_agent,
      owner: __MODULE__,
      stack: SpectreCoverageFloorTest.BoundStack,
      stack_refs: [%{ref | stack_digest: String.duplicate("0", 64)}]
    }
  end
end

defmodule SpectreCoverageFloorTest.NoStackAgent do
  @moduledoc false

  def __spectre_definition__ do
    %Spectre.Definition{id: :no_stack_agent, owner: __MODULE__}
  end
end

defmodule SpectreCoverageFloorTest.ManifestMismatchStack do
  @moduledoc false

  def __spectre_stack_definition__ do
    SpectreCoverageFloorTest.StackFixture.bound_definition(__MODULE__)
  end

  def __spectre_stack_manifest__, do: %{}
end

defmodule SpectreCoverageFloorTest.OwnerMismatchStack do
  @moduledoc false

  def __spectre_stack_definition__ do
    SpectreCoverageFloorTest.StackFixture.bound_definition(SpectreCoverageFloorTest.BoundStack)
  end

  def __spectre_stack_manifest__, do: %{}
end

defmodule SpectreCoverageFloorTest.InvalidReplyStack do
  @moduledoc false
  def __spectre_stack_definition__, do: :invalid
  def __spectre_stack_manifest__, do: %{}
end

defmodule SpectreCoverageFloorTest.RaisingStack do
  @moduledoc false
  def __spectre_stack_definition__, do: raise("stack exploded")
end

defmodule SpectreCoverageFloorTest.ThrowingStack do
  @moduledoc false
  def __spectre_stack_definition__, do: throw(:stack_exploded)
end

defmodule SpectreCoverageFloorTest.RuntimeStack do
  @moduledoc false
end

defmodule SpectreCoverageFloorTest.RuntimeOperations do
  @moduledoc false

  def execute(input, _context), do: {:ok, input}
  def reconcile(receipt, _context), do: {:ok, receipt}
end

defmodule SpectreCoverageFloorTest.RecoveryWork do
  @moduledoc false

  use Spectre.Work,
    id: :coverage_recovery,
    version: 1,
    input: :map,
    state: :map

  operation(:none, {SpectreCoverageFloorTest.RuntimeOperations, :execute},
    input: :map,
    output: :map,
    side_effect: :none,
    retry: [max_attempts: 3, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:crash, :error]]
  )

  operation(:idempotent, {SpectreCoverageFloorTest.RuntimeOperations, :execute},
    input: :map,
    output: :map,
    side_effect: :idempotent,
    retry: [max_attempts: 3, base_delay_ms: 0, max_delay_ms: 0, retry_on: [:crash, :error]]
  )

  operation(:reconcilable, {SpectreCoverageFloorTest.RuntimeOperations, :execute},
    input: :map,
    output: :map,
    side_effect: :reconcilable,
    reconcile: {SpectreCoverageFloorTest.RuntimeOperations, :reconcile}
  )

  operation(:unsafe, {SpectreCoverageFloorTest.RuntimeOperations, :execute},
    input: :map,
    output: :map,
    side_effect: :non_idempotent
  )

  @impl true
  def init(input, _context), do: {:ok, input}

  @impl true
  def next(%{operation: operation}, _context), do: run(operation, %{})

  @impl true
  def apply_result(state, _request, _result, _context), do: {:ok, state}

  @impl true
  def complete(_state, _context), do: :continue
end

defmodule SpectreCoverageFloorTest.CompletionController do
  @moduledoc false

  alias Spectre.Operation.Definition

  def __spectre_loop_definition__ do
    Definition.new(
      id: :coverage_completion,
      version: 1,
      kind: :work,
      input: :map,
      state: :map,
      blockers: [:known],
      waits: [:event],
      triggers: [:event]
    )
  end

  def complete(%{decision: decision}, _context), do: decision
  def handle_trigger(state, _trigger, _context), do: {:ok, state}
end

defmodule SpectreCoverageFloorTest do
  use ExUnit.Case, async: false

  alias Spectre.ActionGuards
  alias Spectre.Effect
  alias Spectre.Extension.Mount
  alias Spectre.Instance.Ref, as: InstanceRef
  alias Spectre.Stack.Binding
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition, as: StackDefinition
  alias Spectre.Stack.DSL
  alias Spectre.Stack.Installable
  alias Spectre.Stack.Installation
  alias Spectre.Stack.Package
  alias Spectre.Stack.Ref
  alias Spectre.Stack.Runtime
  alias SpectreCoverageFloorTest.StackFixture

  setup do
    previous_classifier = Application.get_env(:spectre, :classifier)

    on_exit(fn ->
      if is_nil(previous_classifier) do
        Application.delete_env(:spectre, :classifier)
      else
        Application.put_env(:spectre, :classifier, previous_classifier)
      end

      Spectre.Router.SemanticCache.Learned.Online.clear_rows(SpectreCoverageFloorTest.BasicAgent)
    end)

    :ok
  end

  test "Instance Registry covers not-found, default arities, and every start reply" do
    agent = SpectreCoverageFloorTest.BasicAgent
    missing_subject = "coverage-floor-#{System.unique_integer([:positive])}"

    assert {:error, :instance_not_found} =
             Spectre.Instance.Registry.lookup(agent, missing_subject)

    ref = InstanceRef.new(agent, missing_subject)

    assert {:via, Registry, {Spectre.Instance.Registry, ref_key, ^ref}} =
             Spectre.Instance.Registry.via(ref)

    assert ref_key == ref.key
    assert {:error, :instance_not_found} = Spectre.Instance.Registry.lookup_ref(ref)

    supervisor =
      start_supervised!({Spectre.Supervisor, name: SpectreCoverageFloorTest.RealSupervisor})

    assert {:ok, instance} =
             Spectre.Instance.Registry.ensure_started(supervisor, agent, missing_subject)

    assert {:ok, ^instance} =
             Spectre.Instance.Registry.ensure_started(supervisor, agent, missing_subject)

    registry =
      start_supervised!({Registry, keys: :unique, name: SpectreCoverageFloorTest.Registry})

    race_ref = InstanceRef.new(agent, "race-4")

    replies = [
      {:self, :extra},
      {:already_started, self()},
      :ignore,
      {:register_then_error, SpectreCoverageFloorTest.Registry, race_ref.key, :lost_race},
      {:error, :cannot_start}
    ]

    fake = start_supervised!({SpectreCoverageFloorTest.FakeDynamicSupervisor, replies})

    assert {:ok, ^fake, :extra} =
             Spectre.Instance.Registry.ensure_started(fake, agent, "race-1",
               registry: SpectreCoverageFloorTest.Registry
             )

    assert {:ok, owner} =
             Spectre.Instance.Registry.ensure_started(fake, agent, "race-2",
               registry: SpectreCoverageFloorTest.Registry
             )

    assert owner == self()

    assert :ignore =
             Spectre.Instance.Registry.ensure_started(fake, agent, "race-3",
               registry: SpectreCoverageFloorTest.Registry
             )

    assert {:ok, ^fake} =
             Spectre.Instance.Registry.ensure_started(fake, agent, "race-4",
               registry: SpectreCoverageFloorTest.Registry
             )

    assert {:error, :cannot_start} =
             Spectre.Instance.Registry.ensure_started(fake, agent, "race-5",
               registry: SpectreCoverageFloorTest.Registry
             )

    assert is_pid(registry)
  end

  test "Supervisor default API starts sessions and subject-scoped Instances" do
    assert {:ok, supervisor} = Spectre.Supervisor.start_link()

    on_exit(fn ->
      stop_if_alive(supervisor, &Supervisor.stop/1)
    end)

    assert {:ok, session} = Spectre.Supervisor.summon(SpectreCoverageFloorTest.BasicAgent)
    assert :ok = Spectre.Supervisor.dismiss(session)

    subject = "supervisor-default-#{System.unique_integer([:positive])}"

    assert {:ok, instance} =
             Spectre.Supervisor.summon(
               Spectre.Supervisor,
               SpectreCoverageFloorTest.BasicAgent,
               subject: subject
             )

    assert {:ok, ^instance} =
             Spectre.Supervisor.instance(SpectreCoverageFloorTest.BasicAgent, subject)

    assert :ok = Spectre.Supervisor.dismiss(instance)
  end

  test "Action guards cover callback arities, invalid callbacks, and neutral effects" do
    assert :allow = ActionGuards.check(%Effect{kind: :retrieve}, %{}, [])
    assert :allow = ActionGuards.check(%Effect{kind: :action, name: :none}, %{}, [])

    ctx = %{agent: SpectreCoverageFloorTest.GuardAgent}

    assert :allow = ActionGuards.check(%Effect{kind: :action, name: :mfa_one}, ctx, [])

    assert {:error, :rejected} =
             ActionGuards.check(%Effect{kind: :action, name: :mfa_error}, ctx, [])

    assert {:error, {:invalid_before_action_guard, _}} =
             ActionGuards.check(%Effect{kind: :action, name: :missing}, ctx, [])

    assert :allow = ActionGuards.check(%Effect{kind: :action, name: :fun_two}, ctx, [])

    assert {:suppress, "one"} =
             ActionGuards.check(%Effect{kind: :action, name: :fun_one}, ctx, [])

    assert {:error, {:invalid_before_action_guard, 123}} =
             ActionGuards.check(%Effect{kind: :action, name: :invalid}, ctx, [])
  end

  test "Stack package manifests reject every malformed public shape" do
    module = SpectreCoverageFloorTest.NoCompilePackage
    valid = %{id: :valid, version: "1.0.0", contract: 1}

    invalid = [
      :invalid,
      [:not_a_keyword],
      Map.put(valid, :id, nil),
      Map.put(valid, :version, "not-semver"),
      Map.put(valid, :contract, 0),
      Map.put(valid, :spectre, "not a requirement"),
      Map.put(valid, :provides, :not_a_list),
      Map.put(valid, :provides, [:same, :same]),
      Map.put(valid, :dsl, "not-a-module"),
      Map.put(valid, :metadata, []),
      Map.put(valid, :agent_extensions, :not_a_list),
      Map.put(valid, :agent_extensions, [nil]),
      Map.put(valid, :agent_extensions, [module, module])
    ]

    Enum.each(invalid, fn manifest ->
      assert_raise ArgumentError, fn -> Package.new!(module, manifest) end
    end)
  end

  test "Installable covers contract, compiler, and child-spec failure contracts" do
    no_compile = SpectreCoverageFloorTest.NoCompilePackage
    children = SpectreCoverageFloorTest.ChildSpecsPackage

    assert {:ok, %Package{id: :no_compile}} = Installable.verify(no_compile)
    assert {:error, {:unsupported_stack_contract, 2, [1]}} = Installable.verify(no_compile, 2)
    assert {:error, {:invalid_installable, 42}} = Installable.verify(42)

    assert {:error, {:invalid_manifest, _}} =
             Installable.verify(SpectreCoverageFloorTest.InvalidManifestPackage)

    assert {:error, {:unsupported_stack_contract, 2, [1]}} =
             Installable.verify(SpectreCoverageFloorTest.ContractTwoPackage)

    assert_raise ArgumentError, fn ->
      Installable.verify!(SpectreCoverageFloorTest.InvalidManifestPackage)
    end

    assert [] == Installable.compile!(no_compile, [], nil, __ENV__)

    assert_raise ArgumentError, fn ->
      Installable.compile!(no_compile, [], quote(do: option(:x)), __ENV__)
    end

    assert_raise ArgumentError, fn ->
      Installable.compile!(no_compile, [{:ok, 1}, :bad_tail], nil, __ENV__)
    end

    assert_raise ArgumentError, fn ->
      Installable.compile!(SpectreCoverageFloorTest.InvalidCompilerPackage, [], nil, __ENV__)
    end

    package = Installable.verify!(children)
    installation = Installation.build!(:children, package, %{}, %{}, false)

    assert {:ok, [{:client, _spec}]} = Installable.child_specs(installation, mode: :ok)
    assert {:error, :child_specs_failed} = Installable.child_specs(installation, mode: :error)

    assert {:error, {:stack_callback_exception, _, :child_specs, ArgumentError, _}} =
             Installable.child_specs(installation, mode: :raise)

    assert {:error, {:invalid_stack_child_specs, :invalid}} =
             Installable.child_specs(installation, mode: :invalid)

    assert {:error, {:invalid_stack_child_specs, [:invalid]}} =
             Installable.child_specs(installation, mode: :invalid_entry)
  end

  test "Stack DSL supports range/list arities and rejects invalid declarations" do
    assert [option: [:one]] =
             DSL.compile!(quote(do: option(:one)), __ENV__, option: 1..2)

    assert [option: [:one, :two]] =
             DSL.compile!(quote(do: option(:one, :two)), __ENV__, option: [1, 2])

    assert_raise ArgumentError, ~r/invalid option\/0/, fn ->
      DSL.compile!(quote(do: option()), __ENV__, option: 1..2)
    end

    assert_raise ArgumentError, ~r/invalid Stack package declaration/, fn ->
      DSL.compile!(quote(do: 42), __ENV__, option: 1)
    end
  end

  test "Stack Definition validates headers, exports, dependencies, and conflicts" do
    valid = StackDefinition.new!(id: :empty, owner: __MODULE__, installations: [])
    assert valid == StackDefinition.validate!(valid)

    for attrs <- [
          %{id: nil, owner: __MODULE__, installations: []},
          %{id: :bad, owner: nil, installations: []},
          %{id: :bad, owner: __MODULE__, version: 0, installations: []},
          %{id: :bad, owner: __MODULE__, contract: 2, installations: []},
          %{id: :bad, owner: __MODULE__, installations: :invalid}
        ] do
      assert_raise ArgumentError, fn -> StackDefinition.new!(attrs) end
    end

    duplicate = StackFixture.installation(:duplicate, StackFixture.package(:duplicate))

    assert_raise ArgumentError, ~r/duplicate Stack installation/, fn ->
      StackDefinition.new!(
        id: :duplicates,
        owner: __MODULE__,
        installations: [duplicate, duplicate]
      )
    end

    dependency =
      StackFixture.installation(
        :dependency,
        StackFixture.package(:dependency, provides: [{:contract, :contract_a}, {:service, :svc}])
      )

    consumer =
      StackFixture.installation(
        :consumer,
        StackFixture.package(:consumer,
          requires: [
            {:package, :dependency},
            {:package, :dependency, ">= 1.0.0"},
            {:contract, :contract_a},
            {:contract, :contract_a, ">= 1.0.0"},
            {:service, :svc},
            {:service, :svc, ">= 1.0.0"},
            :contract_a
          ]
        )
      )

    assert %StackDefinition{} =
             StackDefinition.new!(
               id: :requirements,
               owner: __MODULE__,
               installations: [consumer, dependency]
             )

    missing =
      StackFixture.installation(
        :missing,
        StackFixture.package(:missing, requires: [{:service, :absent}])
      )

    assert_raise ArgumentError, ~r/requires missing service/, fn ->
      StackDefinition.new!(id: :missing, owner: __MODULE__, installations: [missing])
    end

    wrong_version =
      StackFixture.installation(
        :wrong_version,
        StackFixture.package(:wrong_version, requires: [{:package, :dependency, "~> 2.0"}])
      )

    assert_raise ArgumentError, ~r/installed 1.0.0/, fn ->
      StackDefinition.new!(
        id: :wrong_version,
        owner: __MODULE__,
        installations: [dependency, wrong_version]
      )
    end

    harmless_conflicts =
      StackFixture.installation(
        :harmless,
        StackFixture.package(:harmless,
          conflicts: [
            {:package, :harmless},
            {:contract, :absent_contract},
            {:service, :absent_service},
            :absent_package
          ]
        )
      )

    assert %StackDefinition{} =
             StackDefinition.new!(
               id: :harmless_conflicts,
               owner: __MODULE__,
               installations: [harmless_conflicts]
             )

    conflicting =
      StackFixture.installation(
        :conflicting,
        StackFixture.package(:conflicting, conflicts: [{:package, :dependency}])
      )

    assert_raise ArgumentError, ~r/conflicts with package/, fn ->
      StackDefinition.new!(
        id: :conflict,
        owner: __MODULE__,
        installations: [dependency, conflicting]
      )
    end

    assert {:error, {:unknown_stack, 42}} = StackDefinition.fetch(42)

    assert {:error, {:stack_manifest_integrity_mismatch, _}} =
             StackDefinition.fetch(SpectreCoverageFloorTest.ManifestMismatchStack)

    assert {:error, {:stack_owner_mismatch, _, _}} =
             StackDefinition.fetch(SpectreCoverageFloorTest.OwnerMismatchStack)

    assert {:error, {:invalid_stack_definition, _, :invalid}} =
             StackDefinition.fetch(SpectreCoverageFloorTest.InvalidReplyStack)

    assert {:error, {:stack_definition_exception, _, RuntimeError}} =
             StackDefinition.fetch(SpectreCoverageFloorTest.RaisingStack)

    assert {:error, {:stack_definition_failure, _, :throw, :stack_exploded}} =
             StackDefinition.fetch(SpectreCoverageFloorTest.ThrowingStack)

    assert_raise ArgumentError, fn ->
      StackDefinition.fetch!(SpectreCoverageFloorTest.RaisingStack)
    end

    assert {:error, {:unknown_stack_installation, :missing}} =
             StackDefinition.installation(valid, :missing)

    assert %{id: :bound_stack} = StackDefinition.manifest(SpectreCoverageFloorTest.BoundStack)
  end

  test "Stack binding distinguishes package IDs, stale refs, and absent stacks" do
    assert {:ok, [_ref]} = Binding.refs(SpectreCoverageFloorTest.BoundAgent)
    assert {:error, {:unknown_spectre_definition, _}} = Binding.refs(__MODULE__.MissingAgent)

    assert {:error, :agent_has_no_stack} =
             Binding.installation(SpectreCoverageFloorTest.NoStackAgent, :x)

    assert {:ok, %Installation{id: :local_bound}} =
             Binding.installation(SpectreCoverageFloorTest.BoundAgent, :bound_package)

    assert {:error, {:package_not_installed, :missing}} =
             Binding.installation(SpectreCoverageFloorTest.BoundAgent, :missing)

    assert {:error, {:package_not_bound, :local_bound}} =
             Binding.installation(SpectreCoverageFloorTest.UnboundAgent, :bound_package)

    assert {:error, {:stale_stack_binding, :local_bound}} =
             Binding.installation(SpectreCoverageFloorTest.StaleBoundAgent, :bound_package)

    assert Binding.stack_mount?(%Mount{opts: [stack_ref: :ref, stack_config: %{}]})

    assert_raise ArgumentError, fn -> Binding.setup_agent!(__MODULE__, 42) end
  end

  test "Stack runtime normalizes options and child-spec failures" do
    definition = StackFixture.runtime_definition()

    assert {:ok, runtime} = Runtime.start_link(definition)
    assert :ok = Supervisor.stop(runtime)

    assert {:error, {:invalid_stack_package_runtime_options, :invalid}} =
             Runtime.child_specs(definition, packages: :invalid)

    assert {:error, {:invalid_stack_package_runtime_options, [:invalid]}} =
             Runtime.child_specs(definition, packages: [:invalid])

    assert {:error, {:invalid_stack_runtime_options, :children, :invalid}} =
             Runtime.child_specs(definition, packages: %{children: :invalid})

    assert {:error, {:invalid_stack_runtime_options, :children, [:invalid]}} =
             Runtime.child_specs(definition, packages: %{children: [:invalid]})

    assert {:error, {:invalid_stack_child_spec, :client, ArgumentError}} =
             Runtime.child_specs(definition, packages: %{children: [mode: :invalid_child]})

    assert {:error, {:duplicate_stack_runtime_resource, _ref_key}} =
             Runtime.child_specs(definition, packages: %{children: [mode: :duplicate]})
  end

  test "Stack facade, Ref, Installation, and V1 expose their error contracts" do
    definition = StackFixture.bound_definition()
    installation = hd(definition.installations)

    assert %StackDefinition{} = Spectre.Stack.definition(SpectreCoverageFloorTest.BoundStack)

    assert {:ok, %Installation{}} =
             Spectre.Stack.installation(SpectreCoverageFloorTest.BoundAgent, :bound_package)

    unfinished = %StackDefinition{id: :unfinished, owner: __MODULE__, installations: []}
    assert_raise ArgumentError, fn -> Ref.new(unfinished, installation, :package, :x) end
    refute Ref.valid?(:invalid)

    assert_raise ArgumentError, fn -> Installation.rebuild!(:invalid) end

    assert {:error, {:unsupported_stack_contract, 2, [1]}} =
             V1.verify_manifest(SpectreCoverageFloorTest.ContractTwoPackage, %{
               id: :contract_two,
               version: "1.0.0",
               contract: 2
             })

    assert {:error, {:invalid_manifest, _}} =
             V1.verify_manifest(SpectreCoverageFloorTest.InvalidManifestPackage, :invalid)
  end

  test "AgentRef validates Agent kind, logical id, version, definition, and Stack digest" do
    alias Spectre.AgentRef

    ref = AgentRef.new(SpectreCoverageFloorTest.BasicAgent)
    assert ^ref = AgentRef.new(ref)

    assert_raise ArgumentError, fn -> AgentRef.new(SpectreCoverageFloorTest.BasicSkill) end

    assert_raise ArgumentError, fn ->
      AgentRef.new(SpectreCoverageFloorTest.BasicAgent, id: self())
    end

    for invalid <- [
          %{ref | id: ""},
          %{ref | definition: nil},
          %{ref | version: 0},
          %{ref | stack_digest: ""}
        ] do
      assert_raise ArgumentError, fn -> AgentRef.validate!(invalid) end
    end

    assert %AgentRef{stack_digest: digest} = AgentRef.new(SpectreCoverageFloorTest.BoundAgent)
    assert is_binary(digest)

    assert %AgentRef{stack_digest: nil} =
             AgentRef.new(SpectreCoverageFloorTest.UnknownStackAgent)
  end

  test "ExternalIdentity validates missing principals and every typed boundary" do
    alias Spectre.ExternalIdentity
    alias Spectre.Input.Source

    identity =
      ExternalIdentity.new(
        provider: :beam,
        channel: :chat,
        actor_id: "actor-1",
        authenticated_at: 1
      )

    assert ^identity = ExternalIdentity.new(identity)

    assert_raise ArgumentError, fn ->
      ExternalIdentity.new(provider: :beam, channel: :chat, authenticated_at: 1)
    end

    source = %Source{kind: :chat, mount: :main, actor_id: "actor-1"}
    assert_raise KeyError, fn -> ExternalIdentity.from_source(source) end

    invalid = [
      %{identity | provider: ""},
      %{identity | channel: nil},
      %{identity | authenticated_at: -1},
      %{identity | proof_ref: 123},
      %{identity | metadata: []}
    ]

    Enum.each(invalid, fn value ->
      assert_raise ArgumentError, fn -> ExternalIdentity.validate!(value) end
    end)
  end

  test "small operation values reject constructor, validation, and portability failures" do
    alias Spectre.Operation.Outcome
    alias Spectre.Operation.Request
    alias Spectre.Operation.Wait

    assert_raise ArgumentError, fn -> Wait.new(:timer, due_at: -1) end

    wait = Wait.new(:timer)

    assert {:error, {:invalid_operation_wait_kind, :invalid}} =
             Wait.validate(%{wait | kind: :invalid})

    assert_raise ArgumentError, fn -> Request.new(nil) end
    request = Request.new(:operation)
    assert_raise ArgumentError, fn -> Request.validate!(%{request | id: ""}) end

    outcome = Outcome.new(:completed)
    assert_raise ArgumentError, fn -> Outcome.validate!(%{outcome | at: -1}) end

    assert {:error, {:nonportable_operation_outcome, _}} =
             Outcome.validate(%{outcome | result: self()})
  end

  test "small public helpers cover fallback clauses and default arities" do
    alias Spectre.Input.Pipeline
    alias Spectre.Input.Pipeline.Spec
    alias Spectre.Input.Plugs.NormalizeText
    alias Spectre.Operation.Validator
    alias Spectre.Prompt.Fragment
    alias Spectre.Prompt.Operation

    assert :error == Spectre.Instance.Telemetry.reason_class(%{})
    assert :plain == Spectre.Instance.Telemetry.reason_class(:plain)
    assert nil == Spectre.Context.lifecycle_run_id(:invalid)

    assert_raise ArgumentError, fn -> Mount.new(__MODULE__.MissingExtension, []) end
    assert_raise ArgumentError, fn -> Mount.new(SpectreCoverageFloorTest.BadExtension, []) end
    assert_raise ArgumentError, fn -> Mount.new(SpectreCoverageFloorTest.BadExtension, [:bad]) end

    subject = Spectre.Subject.new("subject")
    assert_raise ArgumentError, fn -> Spectre.Subject.validate!(%{subject | metadata: []}) end

    instance_ref =
      InstanceRef.new(SpectreCoverageFloorTest.BasicAgent, "subject", agent_id: :logical_agent)

    assert String.starts_with?(instance_ref.agent_ref.id, "agent:")

    operation = Operation.new(:context, into: :context)
    assert %Fragment{metadata: %{}} = Fragment.new(operation, "content")

    assert {:error, {:unsupported_effect_kind, :retrieve}} =
             Spectre.ActionDispatcher.dispatch(%Effect{kind: :retrieve}, %{})

    assert {:error, {:invalid_operation_value, :value, :map, :binary}} =
             Validator.validate(:map, "binary", :value)

    assert {:error, {:invalid_operation_value, :value, :binary, :map}} =
             Validator.validate(:binary, %{}, :value)

    input = Spectre.Input.new("  VALUE  ")

    assert {:ok, %Spectre.Input{text: "VALUE"}} =
             Pipeline.run(input, %{opts: []}, [
               %Spec{module: NormalizeText, state: [trim: true]}
             ])
  end

  test "inference constraint merging covers nil, ranked, custom, and nested options" do
    alias Spectre.Inference.Constraints

    assert %Constraints{} = Constraints.from_options(inference: :invalid)

    assert %Constraints{minimum_level: :fast} =
             Constraints.merge(%{minimum_level: :fast}, %{minimum_level: nil})

    assert %Constraints{minimum_level: :deep} =
             Constraints.merge(%{minimum_level: :fast}, %{minimum_level: :deep})

    assert %Constraints{minimum_level: :custom} =
             Constraints.merge(%{minimum_level: :fast}, %{minimum_level: :custom})

    assert %Constraints{risk: :high} = Constraints.merge(%{risk: nil}, %{risk: :high})
    assert %Constraints{risk: :high} = Constraints.merge(%{risk: :high}, %{risk: nil})

    assert %Constraints{maximum_cost_tier: :low} =
             Constraints.merge(%{maximum_cost_tier: :high}, %{maximum_cost_tier: :low})

    assert %Constraints{maximum_latency_ms: 100, context_tokens: 200} =
             Constraints.merge(
               %{maximum_latency_ms: 200, context_tokens: 100},
               %{maximum_latency_ms: 100, context_tokens: 200}
             )
  end

  test "router adapters cover one-arity, invalid, halted, and uncached embedding paths" do
    alias Spectre.Router.Context
    alias Spectre.Router.LocalClassifier
    alias Spectre.Router.Plugs.EmbeddingSimilarity
    alias Spectre.Router.Plugs.LocalClassifier, as: LocalClassifierPlug

    assert {:ok, %{accepted?: true, label: :PING}} =
             LocalClassifier.classify("value",
               classify: fn _text -> {:ok, %{accepted?: true, label: :PING}} end
             )

    assert {:error, {:invalid_classifier_adapter, 123}} =
             LocalClassifier.classify("value", classifier_local: 123)

    assert {:cont, %Context{halted?: true}} =
             LocalClassifierPlug.call(%Context{halted?: true}, [])

    rule = %Spectre.Rule{
      label: :EMBEDDED,
      embedding: ["example"],
      handler: {:reply, "ok", []}
    }

    context = %Context{
      input: Spectre.Input.new("query"),
      rules: [rule],
      opts: [
        embedding_example_cache?: false,
        embedding: fn _text, _opts -> {:ok, [1.0, 0.0]} end
      ]
    }

    assert {:cont, %Context{candidates: [_candidate]}} = EmbeddingSimilarity.call(context, [])
  end

  test "online semantic rows support default and unlimited capacity" do
    alias Spectre.Router.SemanticCache.Learned.Online

    row = %{
      agent: SpectreCoverageFloorTest.BasicAgent,
      id: "default-row",
      label: :PING,
      normalized_text: "ping",
      verified?: true,
      editable?: true,
      inserted_at: nil,
      updated_at: nil
    }

    assert :ok = Online.put_row(row)

    assert :ok =
             Online.put_row(%{row | id: "unlimited-row"},
               semantic_cache_online_capacity: :unlimited
             )

    assert %{id: "default-row"} = Online.fetch(SpectreCoverageFloorTest.BasicAgent, "default-row")
  end

  test "Journal Record serializes calendar/struct values and rejects malformed restored types" do
    alias Spectre.Journal.Record

    naive = ~N[2026-08-08 12:00:00]
    date = ~D[2026-08-08]
    time = ~T[12:00:00]

    record =
      Record.new(
        phase: :policy,
        metadata: %{
          {:tuple, :key} => :value,
          naive: naive,
          date: date,
          time: time,
          uri: URI.parse("https://example.com")
        }
      )

    encoded = Record.to_json_map(record)
    assert encoded["metadata"]["naive"] == NaiveDateTime.to_iso8601(naive)
    assert encoded["metadata"]["date"] == Date.to_iso8601(date)
    assert encoded["metadata"]["time"] == Time.to_iso8601(time)
    assert is_map(encoded["metadata"]["uri"])
    assert encoded["metadata"]["{:tuple, :key}"] == "value"

    assert {:error, {:unknown_journal_phase, _}} =
             Record.restore(%{phase: "coverage_phase_that_does_not_exist"})

    assert {:error, {:invalid_journal_phase, 123}} = Record.restore(%{phase: 123})

    assert {:ok, %Record{agent: SpectreCoverageFloorTest.BasicAgent}} =
             Record.restore(%{phase: :policy, agent: SpectreCoverageFloorTest.BasicAgent})

    assert {:error, {:unknown_journal_agent, _}} =
             Record.restore(%{phase: :policy, agent: "Elixir.Coverage.Unknown.Agent"})

    assert {:error, {:invalid_journal_agent, 123}} =
             Record.restore(%{phase: :policy, agent: 123})

    now = DateTime.utc_now()
    assert {:ok, %Record{occurred_at: ^now}} = Record.restore(%{phase: :policy, occurred_at: now})

    assert {:error, {:invalid_journal_occurred_at, _}} =
             Record.restore(%{phase: :policy, occurred_at: "not-a-date"})

    assert {:error, {:invalid_journal_occurred_at, 123}} =
             Record.restore(%{phase: :policy, occurred_at: 123})

    assert {:error, {:invalid_journal_binary, "not-base64"}} =
             Record.restore(%{
               phase: :policy,
               metadata: %{"nested" => %{"$spectre" => "binary", "value" => "not-base64"}}
             })
  end

  @tag :tmp_dir
  test "classifier Trainer covers invalid datasets, embedding failure, intent labels, and modes",
       %{
         tmp_dir: tmp
       } do
    alias Spectre.Classifier.Trainer

    adapter = SpectreCoverageFloorTest.ClassifierAdapter
    invalid_dataset = Path.join(tmp, "object.json")
    filtered_dataset = Path.join(tmp, "filtered.json")
    failed_embedding = Path.join(tmp, "failed.json")
    intent_dataset = Path.join(tmp, "intent.json")

    File.write!(invalid_dataset, Jason.encode!(%{text: "not a list"}))
    File.write!(filtered_dataset, Jason.encode!([123, %{"text" => "missing label"}]))
    File.write!(failed_embedding, Jason.encode!([%{"text" => "fail", "label" => "FAIL"}]))
    File.write!(intent_dataset, Jason.encode!([%{"text" => "alpha", "intent" => "ALPHA"}]))

    assert {:error, :invalid_dataset} =
             Trainer.train(invalid_dataset, Path.join(tmp, "invalid-out"),
               embedding_adapter: adapter
             )

    assert {:error, :enoent} =
             Trainer.train(Path.join(tmp, "missing.json"), Path.join(tmp, "missing-out"),
               embedding_adapter: adapter
             )

    assert {:error, :empty_dataset} =
             Trainer.train(filtered_dataset, Path.join(tmp, "filtered-out"),
               embedding_adapter: adapter
             )

    assert {:error, :embed_failed} =
             Trainer.train(failed_embedding, Path.join(tmp, "failed-out"),
               embedding_adapter: adapter,
               adapter_mode: :embed_error
             )

    Application.put_env(:spectre, :classifier, embedding_adapter: adapter)

    assert {:ok, %{labels: ["ALPHA"]}} =
             Trainer.train(intent_dataset, Path.join(tmp, "centroid-out"))

    assert {:ok, %{labels: ["ALPHA"]}} =
             Trainer.train(intent_dataset, Path.join(tmp, "examples-out"),
               embedding_adapter: adapter,
               local_classifier_mode: "examples",
               local_store_centroids?: true
             )
  end

  @tag :tmp_dir
  test "classifier and eval Mix tasks surface each stable failure", %{tmp_dir: tmp} do
    alias Mix.Tasks.Spectre.Classifier.DownloadModel, as: DownloadTask
    alias Mix.Tasks.Spectre.Classifier.Train, as: TrainTask
    alias Mix.Tasks.Spectre.Eval, as: EvalTask

    adapter = SpectreCoverageFloorTest.ClassifierAdapter
    dataset = Path.join(tmp, "dataset.json")
    File.write!(dataset, Jason.encode!([%{"text" => "alpha", "label" => "ALPHA"}]))

    Application.put_env(:spectre, :classifier,
      embedding_adapter: adapter,
      adapter_mode: :missing
    )

    reenable("spectre.classifier.download_model")
    assert_raise Mix.Error, ~r/optional :ex_fastembed dependency/, fn -> DownloadTask.run([]) end

    Application.put_env(:spectre, :classifier,
      embedding_adapter: adapter,
      adapter_mode: :error
    )

    reenable("spectre.classifier.download_model")
    assert_raise Mix.Error, ~r/model download failed/, fn -> DownloadTask.run([]) end

    Application.put_env(:spectre, :classifier,
      embedding_adapter: adapter,
      adapter_mode: :missing
    )

    reenable("spectre.classifier.train")

    assert_raise Mix.Error, ~r/optional :ex_fastembed dependency/, fn ->
      TrainTask.run([dataset, Path.join(tmp, "missing-train")])
    end

    Application.put_env(:spectre, :classifier,
      embedding_adapter: adapter,
      adapter_mode: :error
    )

    reenable("spectre.classifier.train")

    assert_raise Mix.Error, ~r/classifier training failed/, fn ->
      TrainTask.run([dataset, Path.join(tmp, "failed-train")])
    end

    reenable("spectre.eval")
    assert_raise Mix.Error, ~r/expected: mix spectre.eval/, fn -> EvalTask.run([]) end

    reenable("spectre.eval")

    assert_raise Mix.Error, ~r/is not a loaded Spectre agent/, fn ->
      EvalTask.run(["SpectreCoverageFloorTest.MissingAgent", dataset])
    end

    reenable("spectre.eval")

    assert_raise Mix.Error, ~r/routing evaluation failed/, fn ->
      EvalTask.run([
        "--agent",
        "SpectreCoverageFloorTest.BasicAgent",
        Path.join(tmp, "missing-eval.jsonl")
      ])
    end
  end

  test "Eval empty reports, invalid sources, Turn defaults, and Dispatcher fallbacks are explicit" do
    alias Spectre.Eval
    alias Spectre.Eval.Report
    alias Spectre.Result
    alias Spectre.Turn
    alias Spectre.Turn.Dispatcher

    assert {:error, {:invalid_eval_source, 123}} = Eval.load(123)

    report = Report.new([])
    assert report.pass_rate == 0.0
    assert report.duration_us == %{total: 0, average: 0, p50: 0, p95: 0, max: 0}

    no_response = %Turn{decision: {:no_response, %Result{}}, opts: []}

    assert {:ok, :no_response} =
             Dispatcher.dispatch(no_response, SpectreCoverageFloorTest.DispatcherHandler)

    reply_without_text = %Turn{decision: {:reply, %Result{reply_text: nil}}, opts: []}

    assert {:ok, :no_response} =
             Dispatcher.dispatch(
               reply_without_text,
               SpectreCoverageFloorTest.DispatcherHandler,
               []
             )

    assert {:ok, %Turn{}} = Turn.run(SpectreCoverageFloorTest.BasicAgent, "ping")
  end

  test "operation budget, control, delivery policy, and receipt defaults stay validated" do
    alias Spectre.Operation.Budget
    alias Spectre.Operation.Control
    alias Spectre.Operation.Delivery
    alias Spectre.Operation.Delivery.Policy
    alias Spectre.Operation.Delivery.Receipt
    alias Spectre.Operation.Event
    alias Spectre.Operation.Loop

    budget = Budget.new(nil, 1_000)
    assert ^budget = Budget.new(budget)
    assert nil == Budget.exhausted(budget)

    assert %Control{state: :terminal, pending: nil} =
             "coverage-control"
             |> Control.new()
             |> Control.terminalize()

    assert %Policy{} = Policy.new(nil)

    destination = :email

    loop = %Loop{
      id: "coverage-delivery-loop",
      kind: :work,
      controller: SpectreCoverageFloorTest.BasicAgent,
      controller_id: :coverage,
      controller_version: 1,
      base_input: %{},
      effective_input: %{},
      state: %{},
      subject_id: "coverage-subject",
      origin: :test,
      provenance: %{},
      correlation_id: "coverage-correlation",
      created_at: 0,
      updated_at: 0,
      budget: Budget.new(nil, 0),
      destinations: [destination]
    }

    event = Event.new(loop, :completed, agent_id: "coverage-agent", timestamp: 0)
    policy = Policy.new(consent_required: false)

    assert {:ok, %Receipt{status: :authorized} = receipt} =
             Delivery.authorize(event, loop, destination, policy, [])

    assert {:ok, %Receipt{status: :authorized} = authorized} = Delivery.authorized(receipt)

    assert {:ok, %Receipt{status: :delivered}} =
             Delivery.delivered(authorized, %{transport: "coverage"})

    invalid = %{receipt | status: :unknown}

    assert {:error, {:invalid_delivery_receipt_status, :unknown}} = Receipt.validate(invalid)

    assert_raise ArgumentError, ~r/invalid delivery receipt/, fn ->
      Receipt.validate!(invalid)
    end

    assert {:error, {:invalid_delivery_outcome, :unknown}} =
             Receipt.transition(receipt, :unknown, nil, 0)

    # Malformed optional host data must be ignored instead of poisoning authorization.
    assert {:ok, %Receipt{metadata: %{}}} =
             Delivery.authorize(event, loop, destination, policy, [:not_a_receipt],
               consent: %{invalid: self()},
               metadata: :invalid
             )

    assert {:ok, %Receipt{status: :deferred}} =
             Delivery.authorize(
               event,
               loop,
               destination,
               Policy.new(
                 consent_required: false,
                 quiet_hours: %{start: 0, end: 60}
               ),
               [],
               now: 0
             )
  end

  test "State claims one legacy lifecycle atomically for its owning Run" do
    alias Spectre.Awaitable
    alias Spectre.State

    effect = Effect.stage(%{id: "coverage-effect", name: :coverage})
    awaitable = Awaitable.open_policy(:coverage_policy, effect, id: "coverage-awaitable")

    claimed =
      %State{
        pending_effects: [effect],
        planned_effects: [effect],
        awaitables: [awaitable]
      }
      |> State.claim_run_lifecycle("coverage-run")

    assert [%Effect{run_id: "coverage-run"}] = claimed.pending_effects
    assert [%Effect{run_id: "coverage-run"}] = claimed.planned_effects
    assert [%Awaitable{run_id: "coverage-run"}] = claimed.awaitables
    assert claimed == State.claim_run_lifecycle(claimed, "coverage-run")
  end

  test "Run Codec projects host metadata and rejects decoded non-Runs" do
    alias Spectre.Input
    alias Spectre.Result
    alias Spectre.Run
    alias Spectre.Run.Value
    alias Spectre.Runtime
    alias Spectre.State

    logical = Spectre.Run.Codec.logical_input(%Input{text: "ping", meta: :invalid})
    assert logical.meta == %{}

    assert {:ok, initial} =
             Runtime.admit(
               SpectreCoverageFloorTest.BasicAgent,
               Input.new("ping"),
               %State{}
             )

    assert {:ok, _checkpoint} = Run.checkpoint(initial, max_bytes: :invalid)

    {:continue, run} =
      Runtime.start(SpectreCoverageFloorTest.BasicAgent, Input.new("ping"), [])

    {:boundary, _boundary, reply_run} = Runtime.advance(run, [])
    assert %Result{} = reply_run.result

    for route <- [nil, :invalid] do
      projected = %{reply_run | result: %{reply_run.result | route: route}}
      assert {:ok, _checkpoint} = Run.checkpoint(projected)
    end

    assert {:ok, encoded_value} = Value.encode(:not_a_run)

    malformed =
      :erlang.term_to_binary(
        %{"format" => "spectre/run", "version" => 1, "run" => encoded_value},
        [:deterministic]
      )

    assert {:error, :invalid_run} = Run.restore(malformed)
  end

  test "Turn normalizes raw inputs when adapting an existing Result" do
    result = %Spectre.Result{reply_text: "coverage reply"}

    assert %Spectre.Turn{input: %Spectre.Input{text: "raw input"}} =
             Spectre.Turn.from_result(
               SpectreCoverageFloorTest.BasicAgent,
               "raw input",
               [],
               result
             )
  end

  test "Spectre facade covers direct Instance, supervised, and named Session shapes" do
    agent = SpectreCoverageFloorTest.BasicAgent
    subject = "facade-direct-#{System.unique_integer([:positive])}"

    assert {:ok, direct} = Spectre.summon(agent: agent, subject: subject)
    assert {:ok, ^direct} = Spectre.summon(agent: agent, subject: subject)

    on_exit(fn ->
      stop_if_alive(direct, &GenServer.stop/1)
    end)

    supervisor =
      start_supervised!({Spectre.Supervisor, name: SpectreCoverageFloorTest.FacadeSupervisor})

    supervised_subject = "facade-supervised-#{System.unique_integer([:positive])}"

    assert {:ok, supervised} = Spectre.instance(supervisor, agent, supervised_subject)

    ensured_subject = "facade-ensured-#{System.unique_integer([:positive])}"
    assert {:ok, ensured} = Spectre.ensure_instance(supervisor, agent, ensured_subject)
    assert {:ok, ^ensured} = Spectre.ensure_instance(supervisor, agent, ensured_subject)

    assert {:ok, subscriber} = Spectre.subscribe_operation_events(ensured)
    assert is_pid(subscriber)
    assert :ok = Spectre.unsubscribe_operation_events(ensured)

    session_name = SpectreCoverageFloorTest.NamedSession
    assert {:ok, session} = Spectre.summon(agent: agent, name: session_name)

    on_exit(fn ->
      stop_if_alive(session, &GenServer.stop/1)
    end)

    assert {:ok, %Spectre.Turn{agent: ^session_name}} = Spectre.turn(session_name, "ping")

    assert {:error, :no_pending_effect} =
             Spectre.execute(session_name, %Spectre.Result{})

    assert :ok = Spectre.dismiss(supervisor, supervised)
  end

  test "operation Contract rejects undeclared security, waits, updates, and blocker shapes" do
    alias Spectre.Operation.Definition
    alias Spectre.Operation.Runtime.Contract
    alias Spectre.Operation.Wait

    loop = operation_loop_fixture()

    secured =
      Definition.new(
        id: :coverage_completion,
        version: 1,
        kind: :work,
        input: :map,
        state: :map,
        blockers: [:known],
        waits: [:event],
        triggers: [:event],
        update_fields: [:allowed],
        security: %{
          allowed_origins: [:allowed],
          allowed_destinations: [:email],
          allowed_visibility: [:origin]
        }
      )

    unauthorized = %{loop | origin: :allowed, authorized_origins: [:unexpected]}

    assert {:error, {:operational_origin_not_authorized, :allowed}} =
             Contract.validate_loop_security(secured, unauthorized)

    assert :ok = Contract.authorize_revision(loop, loop.revision)

    vigil = Definition.new(id: :coverage_vigil, version: 1, kind: :vigil, waits: [])

    assert {:error, {:undeclared_vigil_trigger, :event}} =
             Contract.validate_wait(vigil, Wait.new(:event))

    declared_vigil = %{vigil | waits: [:timer]}

    assert {:error, {:undeclared_vigil_trigger, :event}} =
             Contract.validate_wait(declared_vigil, Wait.new(:event))

    assert {:error, :operation_trigger_wait_missing} =
             Contract.validate_trigger_correlation(secured, nil, nil, nil)

    assert :ok = Contract.validate_updated_fields(%{same: true}, %{same: true}, secured)

    assert {:error, {:invalid_cognitive_constraints, :invalid}} =
             Contract.validate_cognitive_update(:invalid)

    assert {:error, {:invalid_vigil_significance, :invalid}} =
             Contract.validate_significance(:vigil, :invalid)

    for blocker <- [
          %{id: :known},
          %{"id" => :known},
          %{type: :known},
          %{"type" => :known},
          {:known, %{}},
          :known
        ] do
      assert :ok = Contract.validate_blocker(secured, blocker)
    end

    assert {:error, {:undeclared_operational_blocker, "known"}} =
             Contract.validate_blocker(secured, "known")

    assert {:error, {:undeclared_operational_blocker, :invalid}} =
             Contract.validate_blocker(secured, self())
  end

  test "operation Results covers exhausted, blocked, error, and invalid completion decisions" do
    alias Spectre.Operation.Budget
    alias Spectre.Operation.Control
    alias Spectre.Operation.Runtime.Results

    env = operation_env()
    control = Control.new("coverage-operation-loop")

    exhausted =
      operation_loop_fixture(
        state: %{decision: :continue},
        budget: Budget.new([steps: 0], 0)
      )

    assert {:ok, %{status: :terminal}, %{state: :terminal}, events} =
             Results.evaluate(exhausted, control, env)

    assert Enum.any?(events, &(&1.type == :budget_exhausted))

    blocked = operation_loop_fixture(state: %{decision: {:blocked, %{id: :known}}})

    assert {:ok, %{status: :waiting, blocker: %{id: :known}}, ^control, [%{type: :blocked}]} =
             Results.evaluate(blocked, control, env)

    undeclared = operation_loop_fixture(state: %{decision: {:blocked, :undeclared}})

    assert {:ok, %{status: :terminal}, %{state: :terminal}, [%{type: :failed} | _]} =
             Results.evaluate(undeclared, control, env)

    controller_error = operation_loop_fixture(state: %{decision: {:error, :failed}})

    assert {:ok, %{status: :terminal}, %{state: :terminal}, [%{type: :failed} | _]} =
             Results.evaluate(controller_error, control, env)

    invalid = operation_loop_fixture(state: %{decision: :invalid})

    assert {:ok, %{status: :terminal}, %{state: :terminal}, [%{type: :failed} | _]} =
             Results.evaluate(invalid, control, env)
  end

  test "operation recovery handles every side-effect class and retry budget exhaustion" do
    alias Spectre.Operation.Budget
    alias Spectre.Operation.Result
    alias Spectre.Operation.Runtime

    env = operation_env()

    for operation <- [:reconcilable, :unsafe] do
      {:ok, loop, control, _events} =
        Runtime.start(
          :work,
          SpectreCoverageFloorTest.RecoveryWork,
          %{operation: operation},
          [],
          env
        )

      {:run, active, _attempt, _spec, _request, false, _events} =
        Runtime.prepare(loop, control, env)

      recovered_env = %{env | epoch: "coverage-recovered", snapshot_id: "coverage-recovered"}
      assert {:ok, recovered, _control, events} = Runtime.recover(active, control, recovered_env)

      expected_status = if operation == :reconcilable, do: :reconciling, else: :waiting
      assert recovered.status == expected_status
      assert events != []
    end

    for operation <- [:none, :idempotent] do
      {:ok, loop, control, _events} =
        Runtime.start(
          :work,
          SpectreCoverageFloorTest.RecoveryWork,
          %{operation: operation},
          [],
          env
        )

      {:run, active, attempt, _spec, _request, false, _events} =
        Runtime.prepare(loop, control, env)

      # Ambiguous results for retry-safe operations degrade to their normal failure policy.
      ambiguous = Result.new(attempt, :ambiguous, :connection_lost)

      assert {:ok, %{status: status}, _control, _events} =
               Runtime.apply_result(active, control, ambiguous, env)

      assert status in [:waiting, :terminal]

      exhausted = %{active | budget: Budget.new([retries: 0], 0)}
      recovered_env = %{env | epoch: "coverage-recovered", snapshot_id: "coverage-recovered"}

      assert {:ok, %{status: :terminal}, %{state: :terminal}, events} =
               Runtime.recover(exhausted, control, recovered_env)

      assert Enum.any?(events, &(&1.type == :budget_exhausted))
    end
  end

  test "Subject Registry rejects malformed public boundaries and completes default link arities" do
    alias Spectre.ExternalIdentity
    alias Spectre.LinkIntent
    alias Spectre.Subject
    alias Spectre.Subject.Registry, as: SubjectRegistry
    alias Spectre.SubjectLink

    suffix = System.unique_integer([:positive])
    subject = Subject.new("coverage-subject-registry-#{suffix}")

    source =
      ExternalIdentity.new(
        provider: :beam,
        channel: :coverage,
        principal_id: "coverage-source-#{suffix}",
        authenticated_at: 0
      )

    destination =
      ExternalIdentity.new(
        provider: :beam,
        channel: :coverage,
        principal_id: "coverage-destination-#{suffix}",
        authenticated_at: 0
      )

    assert {:error, {:invalid_agent_ref, 123}} =
             SubjectRegistry.bind(123, subject, source, proof: "proof")

    assert {:error, :missing_subject} =
             SubjectRegistry.bind(SpectreCoverageFloorTest.BasicAgent, nil, source,
               proof: "proof"
             )

    assert {:error, {:invalid_external_identity, :invalid}} =
             SubjectRegistry.bind(
               SpectreCoverageFloorTest.BasicAgent,
               subject,
               :invalid,
               proof: "proof"
             )

    assert {:error, :invalid_subject_link_proof} =
             SubjectRegistry.bind(
               SpectreCoverageFloorTest.BasicAgent,
               subject,
               source,
               proof: self()
             )

    assert {:error, :invalid_subject_link_metadata} =
             SubjectRegistry.bind(
               SpectreCoverageFloorTest.BasicAgent,
               subject,
               source,
               proof: "proof",
               metadata: self()
             )

    assert {:ok, %SubjectLink{}} =
             SubjectRegistry.bind(
               SpectreCoverageFloorTest.BasicAgent,
               subject,
               source,
               proof: "proof"
             )

    assert {:error, {:invalid_link_intent_option, :ttl, 0}} =
             SubjectRegistry.open_link(
               SpectreCoverageFloorTest.BasicAgent,
               subject,
               source,
               destination,
               ttl: 0
             )

    assert {:error, {:invalid_link_intent_option, :attempts, 0}} =
             SubjectRegistry.open_link(
               SpectreCoverageFloorTest.BasicAgent,
               subject,
               source,
               destination,
               attempts: 0
             )

    assert {:error, {:invalid_link_intent_option, :source_confirmation?, :invalid}} =
             SubjectRegistry.open_link(
               SpectreCoverageFloorTest.BasicAgent,
               subject,
               source,
               destination,
               source_confirmation?: :invalid
             )

    assert {:ok, %LinkIntent{} = intent, challenge} =
             SubjectRegistry.open_link(
               SpectreCoverageFloorTest.BasicAgent,
               subject,
               source,
               destination,
               source_confirmation?: true
             )

    assert {:ok, %LinkIntent{status: :awaiting_source}} =
             SubjectRegistry.confirm_link(intent.id, destination, challenge)

    assert {:ok, %LinkIntent{status: :awaiting_source}} = SubjectRegistry.intent(intent.id)
    assert {:ok, %SubjectLink{}} = SubjectRegistry.confirm_source(intent.id, source)
    assert {:error, :unknown_link_intent} = SubjectRegistry.intent(123)
    assert {:error, :unknown_subject_link} = SubjectRegistry.revoke("missing-#{suffix}")
  end

  defp reenable(task), do: Mix.Task.reenable(task)

  defp operation_env do
    %{
      agent: SpectreCoverageFloorTest.BasicAgent,
      subject_id: "coverage-operation-subject",
      epoch: "coverage-epoch",
      snapshot_id: "coverage-snapshot",
      canonical_revision: 1,
      committed: %{},
      now: 1_000
    }
  end

  defp operation_loop_fixture(attrs \\ []) do
    alias Spectre.Operation.Budget
    alias Spectre.Operation.Loop

    defaults = %{
      id: "coverage-operation-loop",
      kind: :work,
      controller: SpectreCoverageFloorTest.CompletionController,
      controller_id: :coverage_completion,
      controller_version: 1,
      base_input: %{},
      effective_input: %{},
      state: %{decision: :continue},
      subject_id: "coverage-operation-subject",
      origin: :allowed,
      provenance: %{},
      correlation_id: "coverage-operation-correlation",
      created_at: 0,
      updated_at: 0,
      budget: Budget.new(nil, 0),
      status: :evaluating,
      authorized_origins: [],
      destinations: [],
      visibility: :origin
    }

    struct!(Loop, Map.merge(defaults, Map.new(attrs)))
  end

  defp stop_if_alive(pid, stop) do
    if Process.alive?(pid) do
      stop.(pid)
    end
  catch
    :exit, _reason -> :ok
  end
end
