defmodule Spectre.Stack.IntegrationTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference
  alias Spectre.Inference.Selector
  alias Spectre.Integration
  alias Spectre.Server
  alias Spectre.Server.{Command, Tool}
  alias Spectre.Stack
  alias Spectre.Stack.{Definition, Installation, Tools}

  defmodule Select do
    @behaviour Selector

    @impl true
    def select(_request, _profiles, _ctx, opts), do: {:error, {:selected, opts[:source]}}
  end

  defmodule LegacySelect do
    def inference_selector(_), do: {Select, source: :legacy}
  end

  defmodule Research do
    use Spectre.Activity

    @impl true
    def handle_start(args, ctx), do: complete(ctx, args)
  end

  defmodule Documents do
    use Spectre.Stack.Installable, id: :documents, version: "1.0.0"
    @behaviour Spectre.Server.GAM.EffectAdapter

    @impl true
    def integration(config) do
      Integration.new()
      |> Integration.service(Selector, Select, source: config[:source])
      |> Integration.tool(:read, __MODULE__, helper: :document, args: [id: :string])
      |> Integration.tool(:publish, __MODULE__,
        args: [title: :string],
        helper: :publish_document,
        governed: :publish
      )
      |> Integration.tool(:preview, __MODULE__)
      |> Integration.activity(:research, Research)
    end

    @impl Spectre.Stack.Installable
    def effects(_) do
      %{
        publish: %{
          contract: 1,
          adapter: __MODULE__,
          operation: :publish,
          side_effect: :non_idempotent,
          material: :arguments,
          partition: [:subject],
          schema_hash: nil,
          config: %{}
        }
      }
    end

    @impl Spectre.Server.GAM.EffectAdapter
    def execute_effect(:publish, %{title: title}, _context), do: {:ok, %{published: title}}

    def prepare(_operation, payload, _ctx), do: {:ok, payload}
    def invoke(operation, payload, _ctx) when operation in [:read, :preview], do: {:ok, payload}
    def project(_operation, result), do: {:ok, result}
  end

  defmodule OtherProvider do
    use Spectre.Stack.Installable, id: :other, version: "1.0.0"

    @impl true
    def integration(_),
      do: Integration.new() |> Integration.service(Selector, Select, source: :other)
  end

  defmodule Existing do
    use Spectre.Stack.Installable, id: :legacy, version: "1.0.0"

    @impl true
    def tools(_) do
      %{
        warehouse: %{
          contract: 1,
          adapter: Documents,
          default: :existing,
          operations: %{existing: %{path: :cognitive, retry: :safe, max_bytes: 1024}}
        }
      }
    end
  end

  defmodule DuplicateTool do
    use Spectre.Stack.Installable, id: :duplicate, version: "1.0.0"

    @impl true
    def tools(config), do: Existing.tools(config)

    @impl true
    def integration(_), do: Integration.new() |> Integration.tool(:existing, Documents)
  end

  defmodule AmbiguousTools do
    use Spectre.Stack.Installable, id: :ambiguous, version: "1.0.0"

    @impl true
    def tools(config) do
      descriptor = Existing.tools(config).warehouse
      %{archive: descriptor, records: descriptor}
    end
  end

  defmodule LibraryStack do
    use Spectre.Stack
    install(Documents, as: :library, source: :documents)
    install(Existing)
    install(AmbiguousTools)
    activity(:local_research, Research, requires: [{:library, :read}])
  end

  defmodule ProviderStack do
    use Spectre.Stack
    install(Documents)
    install(OtherProvider)
  end

  defmodule LibraryAgent do
    use Spectre.Agent, stack: LibraryStack
  end

  defmodule LibraryServer do
    use Spectre.Server, tools: LibraryStack

    @impl true
    def init(observer, ctx), do: {:ok, put_private(ctx, :observer, observer)}

    @impl true
    def handle_call({:research, scope}, _from, ctx),
      do:
        {:reply, :queued,
         start_activity(ctx, :local_research, %{}, scope: scope, on_result: :research)}

    def handle_call({:lookup, ref}, _from, ctx),
      do: {:reply, :queued, call_tool(ctx, ref, %{}, on_result: :lookup)}

    @impl true
    def handle_flow({:documents, :scoped}, _, ctx),
      do: call_tool(ctx, {:library, :publish}, %{title: "Scoped"}, on_result: :published)

    def handle_flow({:documents, :helper}, _, ctx),
      do: publish_document(ctx, %{title: "Helper"}, on_result: :published)

    @impl true
    def handle_result(:published, {:governed, %{outcome: %{status: :succeeded}}}, ctx),
      do: respond(ctx, "published")

    def handle_result(:research, result, ctx) do
      send(get_private(ctx, :observer), {:research, result})
      ctx
    end

    def handle_result(:lookup, result, ctx) do
      send(get_private(ctx, :observer), {:lookup, result})
      ctx
    end
  end

  defmodule PublishingAgent do
    use Spectre.Agent, server: LibraryServer, stack: LibraryStack

    flow :documents do
      on(:scoped, regex: ~r/^scoped$/)
      on(:helper, regex: ~r/^helper$/)
    end
  end

  defmodule SelectedAgent do
    use Spectre.Agent, stack: ProviderStack, services: %{Selector => :other}
  end

  test "scoped declarations share executable snapshots with their generated helper aliases" do
    definition = Definition.fetch!(LibraryStack)
    helpers = Tools.table!(definition.installations)
    scoped = Tools.scoped_table!(definition.installations)

    assert scoped[{:library, :read}] == %{key: :document, snapshot: helpers.document}
    assert scoped[{:legacy, :existing}] == %{key: :warehouse, snapshot: helpers.warehouse}

    assert %{
             key: :publish_document,
             snapshot: %{
               descriptor: %{operations: %{publish: %{path: :governed, operation: :publish}}}
             }
           } = scoped[{:library, :publish}]

    assert %{key: {:library, :preview}} = scoped[{:library, :preview}]

    assert {:ok, %{module: Research, options: []}} =
             Definition.activity(definition, {:library, :research})

    assert {:ok, %{module: Research, options: [requires: [{:library, :read}]]}} =
             Definition.activity(LibraryStack, :local_research)

    assert {:error, {:unknown_stack_activity, :unknown}} =
             Definition.activity(definition, :unknown)
  end

  test "the scoped call and generated helper both execute the registered GAM effect" do
    root = start_root()

    for route <- ["scoped", "helper"] do
      assert {:ok, turn} = Server.input(root, route)
      assert_receive {Server, ^root, {:response, ^turn, "published", _}}, 5_000
    end

    assert {:ok, view} = Server.gam_view(root)
    assert [_, _] = acts = Enum.filter(view.acts, &(&1.class == "test.publish_document"))

    for act <- acts do
      assert [%{status: :succeeded}] = Enum.filter(view.outcomes, &(&1.act_ref == act.ref))
    end
  end

  test "missing or ambiguous scoped operations return a rejection" do
    root = start_root()

    for {ref, reason} <- [
          {{:library, :missing}, :unknown_tool_operation},
          {{:ambiguous, :existing}, :ambiguous_tool_operation}
        ] do
      {_installation, operation} = ref
      assert :queued = GenServer.call(root, {:lookup, ref})
      assert_receive {:lookup, {:error, {:tool_rejected, ^ref, ^operation, ^reason}}}, 5_000
    end

    assert Process.alive?(root)
  end

  test "scoped-only aliases bind adapter code and explicit helpers retain legacy origins" do
    read = %Command{
      kind: :call_tool,
      args: [{:library, :read}, %{id: "D1"}],
      opts: [on_result: :read]
    }

    root = start_root()
    root_state = :sys.get_state(root)

    helper = %Command{
      kind: :tool,
      args: [:document, %{id: "D1"}, Tool.snapshot(LibraryServer).document],
      opts: read.opts
    }

    assert {_, legacy_origin} = Tool.normalize(root_state, helper, nil)
    assert Tool.normalize(root_state, read, nil) == Tool.normalize(root_state, helper, nil)
    refute Map.has_key?(legacy_origin, :adapter_digest)

    state = %{root_state | server: Research}
    state = %{state | tool_bindings: Tool.bindings!(state)}
    assert {%Command{args: [identity, args]} = staged, origin} = Tool.normalize(state, read, nil)
    assert %{tool: :document, adapter_digest: digest} = origin
    assert digest == Base.encode16(Documents.module_info(:md5), case: :lower)

    assert %{outbox: %{"read" => %{command: ^staged}}} =
             Tool.validate_persisted!(%{state | outbox: %{"read" => %{command: staged}}})

    changed = %{staged | args: [%{identity | adapter_digest: String.duplicate("0", 32)}, args]}

    assert_raise ArgumentError, ~r/tool_contract_mismatch/, fn ->
      Tool.validate_persisted!(%{state | outbox: %{"read" => %{command: changed}}})
    end
  end

  test "required Activity tools must exist and be permitted by the effective tool scope" do
    root = start_root()
    assert :queued = GenServer.call(root, {:research, []})

    assert_receive {:research,
                    {:error, {:activity_required_tools_outside_scope, [{:library, :read}]}}},
                   5_000

    assert :queued = GenServer.call(root, {:research, [{:library, :read}]})
    assert_receive {:research, {:ok, %{ref: ref}}}, 5_000
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, %{}}}}, 5_000

    assert_raise ArgumentError, ~r/required Activity tool/, fn ->
      Definition.new!(
        id: :invalid_activity,
        owner: __MODULE__,
        activities: %{research: %{module: Research, options: [requires: [{:missing, :read}]]}}
      )
    end
  end

  test "public tool schema has a separate digest and keeps the execution identity stable" do
    definition = Definition.fetch!(LibraryStack)
    assert {:ok, original} = Definition.installation(definition, :library)

    assert {:ok,
            %{
              arguments: %{"properties" => %{"id" => %{"type" => "string"}}, "required" => ["id"]}
            } = schema} =
             Stack.tool_metadata(LibraryStack, {:library, :read})

    updated =
      put_in(original.adapters.integration.tools.read.public.description, "Read a document")

    updated = Installation.rebuild!(updated)

    replacement =
      Enum.map(definition.installations, &if(&1.id == :library, do: updated, else: &1))

    next = Definition.new!(%{Map.from_struct(definition) | installations: replacement})

    assert {:ok, changed} = Tools.public(updated, :read)
    assert changed.digest != schema.digest
    assert changed.binding == schema.binding
    assert next.digest == definition.digest
    assert Tools.table!(next.installations) == Tools.table!(definition.installations)
  end

  test "Agent binds a sole service and can select explicitly among multiple providers" do
    assert Stack.service(LibraryAgent, Selector) == {Select, source: :documents}
    assert Stack.service(SelectedAgent, Selector) == {Select, source: :other}

    assert {:ok, plan} = Spectre.Prompt.Plan.compose("Select a model", [], [])
    ctx = %Spectre.Context{agent: LibraryAgent, opts: []}
    request = Inference.Request.new(purpose: :response_generation, plan: plan)

    assert {:error, {:selected, :documents}} = Inference.prepare(LibraryAgent, request, ctx)
  end

  test "migrating an equivalent helper retains the installation and Stack identities" do
    legacy = Installation.compile!(Existing, [], nil, __ENV__)

    integration =
      Integration.new()
      |> Integration.tool(:existing, Documents, helper: :warehouse, retry: :safe, max_bytes: 1024)

    migrated = %{legacy | adapters: Map.put(legacy.adapters, :integration, integration)}
    migrated = Installation.rebuild!(migrated)
    assert migrated.digest == legacy.digest
    assert Tools.table!([migrated]) == Tools.table!([legacy])

    attrs = %{id: :migration, owner: __MODULE__, installations: [legacy]}
    legacy_definition = Definition.new!(attrs)

    assert Definition.new!(%{attrs | installations: [migrated]}).digest ==
             legacy_definition.digest
  end

  test "duplicate legacy/new operations and ambiguous providers are rejected" do
    assert_raise ArgumentError, ~r/duplicate operation :existing/, fn ->
      Installation.compile!(DuplicateTool, [], nil, __ENV__)
    end

    assert {:error, {:stack_conformance_failed, message}} = Stack.Conformance.run([DuplicateTool])
    assert message =~ "duplicate operation :existing"

    assert_raise ArgumentError, ~r/multiple Stack providers/, fn ->
      Spectre.Stack.Binding.compile_services!([stack: ProviderStack], [])
    end

    assert_raise ArgumentError, ~r/unknown Stack provider/, fn ->
      Spectre.Stack.Binding.compile_services!(
        [stack: ProviderStack, services: %{Selector => :missing}],
        []
      )
    end
  end

  test "legacy inference selectors share the typed service selection slot" do
    alias Spectre.Extension.Mount
    alias Spectre.Stack.Binding

    existing = Mount.new(LegacySelect, as: :library)

    assert_raise ArgumentError, ~r/duplicate Stack service.*one installation/, fn ->
      Binding.compile_services!([stack: LibraryStack], [existing])
    end

    legacy = Mount.new(LegacySelect, as: :legacy)

    config =
      Binding.compile_services!([stack: LibraryStack, services: %{Selector => :legacy}], [legacy])

    assert config[:integration_services][Selector] == {Select, source: :legacy}
  end

  test "tool declarations reject invalid options and produce nested argument schemas" do
    for {name, opts, error} <- [
          {nil, [], ~r/expected an operation name/},
          {:read, [unknown: true], ~r/invalid tool options/},
          {:read, [args: [id: :string, id: :integer]], ~r/invalid public tool description/},
          {:read, [args: [id: :unknown]], ~r/unknown tool argument type/},
          {:publish, [governed: :publish, retry: :safe], ~r/GAM owns governed tool retries/}
        ] do
      assert_raise ArgumentError, error, fn ->
        Integration.tool(Integration.new(), name, Documents, opts)
      end
    end

    integration =
      Integration.new()
      |> Integration.tool(:batch, Documents, args: [ids: {:array, :string}])

    installation = Installation.compile!(Existing, [], nil, __ENV__)
    installation = Installation.rebuild!(put_in(installation.adapters[:integration], integration))

    assert {:ok, %{arguments: %{"properties" => %{"ids" => schema}}}} =
             Tools.public(installation, :batch)

    assert schema == %{"type" => "array", "items" => %{"type" => "string"}}

    assert {:error, {:unknown_public_tool, {:legacy, :missing}}} =
             Tools.public(installation, :missing)
  end

  test "compiled integrations validate service and Activity contracts" do
    integration = Integration.new()

    for {declaration, error} <- [
          {%{}, ~r/expected Spectre.Integration.new/},
          {Integration.service(integration, {:invalid, :role}, Select), ~r/invalid provider/},
          {Integration.service(integration, Selector, Map), ~r/does not implement/},
          {Integration.activity(integration, :missing_callbacks, Map),
           ~r/must use Spectre.Activity/},
          {Integration.activity(integration, :invalid_scope, Research, tools: :none),
           ~r/invalid Activity tool scope/},
          {Integration.activity(integration, :invalid_children, Research,
             allow_children: [{:missing}]
           ), ~r/invalid Activity tool scope/}
        ] do
      assert_raise ArgumentError, error, fn -> Integration.validate!(declaration) end
    end

    assert Integration.validate!(Integration.service(integration, Selector, Select)).services ==
             %{Selector => {Select, []}}
  end

  test "rebuilding a Stack rejects inconsistent tool aliases and invalid metadata" do
    assert {:ok, installation} = Definition.installation(LibraryStack, :library)

    assert_raise ArgumentError, ~r/integration helper does not match its binding/, fn ->
      Installation.rebuild!(update_in(installation.adapters.tools, &Map.delete(&1, :document)))
    end

    assert_raise ArgumentError, ~r/invalid tool declaration :read/, fn ->
      Installation.rebuild!(put_in(installation.adapters.integration.tools.read.public, nil))
    end
  end

  test "malformed host Activity scopes reject allocation" do
    root = start_root(activity_tools: [:unqualified])
    assert :queued = GenServer.call(root, {:research, :all})
    assert_receive {:research, {:error, :invalid_activity_tool_scope}}, 5_000
    assert {:ok, []} = Server.activities(root)
  end

  defp start_root(overrides \\ []) do
    options = [
      agent: PublishingAgent,
      consumer: self(),
      init_arg: self(),
      identity: %{subject: "document-reader"},
      gam: [operations: %{publish: [confirm: false, class: "test.publish_document"]}]
    ]

    start_supervised!({Server, Keyword.merge(options, overrides)})
  end
end
