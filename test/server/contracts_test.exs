defmodule Spectre.Server.ContractsTest do
  use ExUnit.Case, async: true
  alias Spectre.Server
  alias Spectre.Server.{Checkpoint, Contracts}

  defmodule App do
    use Spectre.Server
    def assigns_schema, do: %{count: :integer, note: {:optional, :string}}

    def continuation_contracts,
      do: %{finished: {:tuple, [{:enum, [:ok]}, :integer]}}

    def init(_, ctx), do: {:ok, assign(ctx, :count, Map.get(ctx.assigns, :count, 0))}

    def handle_flow({:test, "bad_state"}, _, ctx),
      do: ctx |> assign(:count, "secret") |> respond("must not run")

    def handle_flow({:test, "bad_tag"}, _, ctx),
      do: call_actor(ctx, ctx.assigns.actor, :work, on_result: :typo)

    def handle_flow({:test, "result"}, _, ctx),
      do: call_actor(ctx, ctx.assigns.actor, :work, on_result: :finished)

    def handle_result(:finished, {:ok, count}, ctx),
      do: ctx |> assign(:count, count) |> respond("done")
  end

  defmodule Router do
    def route(agent, input, _) do
      route = %Spectre.Route{
        flow: :test,
        label: input.text,
        owner: agent,
        handler: {:server, {[:test], input.text}, []},
        accepted?: true
      }

      {:ok, {:test, input.text}, %{route: route, reason: nil}}
    end
  end

  defmodule Agent do
    def __spectre_config__, do: []
    def __spectre_server__, do: Spectre.Server.ContractsTest.App
  end

  defmodule Actor do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call(:work, _, owner) do
      send(owner, :effect_invoked)
      {:reply, {:ok, "secret-result"}, owner}
    end
  end

  test "state schema failures quarantine the callback without saving invalid assigns" do
    {:ok, server} =
      Server.Runtime.start_link(
        agent: Agent,
        server: App,
        services: [router: Router],
        consumer: self()
      )

    on_exit(fn -> Spectre.Test.Processes.stop(server) end)
    {:ok, id} = Server.input(server, "bad_state")
    assert_receive {Server, ^server, {:callback_error, ^id, :handle_flow, reason}}
    assert reason.kind == :contract
    assert reason.contract == :assigns
    assert reason.path == [:count]
    refute inspect(reason) =~ "secret"
    assert Server.status(server).assigns.count == 0
  end

  test "unknown declared continuation is rejected before invoking the actor" do
    {:ok, actor} = Actor.start_link(self())

    {:ok, server} =
      Server.Runtime.start_link(
        agent: Agent,
        server: App,
        services: [router: Router],
        consumer: self(),
        assigns: %{actor: actor}
      )

    on_exit(fn -> Spectre.Test.Processes.stop(server) end)
    {:ok, id} = Server.input(server, "bad_tag")

    assert_receive {Server, ^server,
                    {:callback_error, ^id, :handle_flow, %{reason: :undeclared_tag, tag: :typo}}}

    refute_receive :effect_invoked
  end

  test "invalid result records structured correlation and never invokes the actor twice" do
    {:ok, actor} = Actor.start_link(self())
    Process.register(actor, __MODULE__)
    path = Path.join(System.tmp_dir!(), "result-contracts-#{System.unique_integer([:positive])}")
    {:ok, store} = Server.Store.Disk.start_link(path: path)
    on_exit(fn -> File.rm_rf(path) end)

    opts = [
      agent: Agent,
      server: App,
      services: [router: Router],
      consumer: self(),
      assigns: %{actor: __MODULE__},
      checkpoint: {store, :session}
    ]

    {:ok, server} = Server.Runtime.start_link(opts)

    on_exit(fn -> Spectre.Test.Processes.stop(server) end)
    {:ok, id} = Server.input(server, "result")
    assert_receive {Server, ^server, {:callback_error, ^id, :handle_result, reason}}, 5000
    assert_received :effect_invoked
    assert reason.contract == :continuation
    assert reason.tag == :finished
    assert reason.interaction_id == id
    assert is_binary(reason.command_id)
    refute inspect(reason) =~ "secret-result"
    refute_receive :effect_invoked
    assert Process.alive?(server)
    GenServer.stop(server)
    {:ok, restored} = Server.Runtime.start_link(opts)
    on_exit(fn -> Spectre.Test.Processes.stop(restored) end)
    assert map_size(Server.status(restored).dead_letters) == 1
    refute_receive :effect_invoked
  end

  test "restore rejects portable but application-invalid assigns before init can repair them" do
    path = Path.join(System.tmp_dir!(), "contracts-#{System.unique_integer([:positive])}")
    {:ok, store} = Server.Store.Disk.start_link(path: path)
    on_exit(fn -> File.rm_rf(path) end)
    opts = [agent: Agent, server: App, checkpoint: {store, :session}]
    {:ok, server} = Server.Runtime.start_link(opts)
    GenServer.stop(server)
    {:ok, %{revision: revision, value: bytes}} = Server.Store.Disk.fetch(store, :session)
    {:ok, projection} = Checkpoint.decode_snapshot(bytes)
    {:ok, corrupt} = Checkpoint.encode_value(%{projection | assigns: %{count: "wrong"}})
    assert {:ok, _} = Server.Store.Disk.compare_and_swap(store, :session, revision, corrupt)
    assert {:error, _} = Server.Runtime.start_link(opts)

    migrated_opts =
      Keyword.merge(opts,
        checkpoint_version: 2,
        checkpoint_migrator: {__MODULE__, :repair_assigns}
      )

    {:ok, repaired} = Server.Runtime.start_link(migrated_opts)
    assert Server.status(repaired).assigns.count == 42
    GenServer.stop(repaired)
  end

  def repair_assigns(projection, _metadata),
    do: {:ok, %{projection | assigns: %{count: 42}}}

  test "schemas permit undeclared fields and optional fields" do
    assert :ok = Contracts.validate_assigns(App, %{count: 2, application_extension: true})
    assert {:error, %{reason: :missing_field}} = Contracts.validate_assigns(App, %{})
    assert :ok = Contracts.validate_configuration!(App)
  end

  defmodule BadSchema do
    def assigns_schema, do: %{name: :unrecognised}
  end

  defmodule Structured do
    def assigns_schema,
      do: %{
        rows: {:list, {:map, %{count: :number, enabled: :boolean, label: {:optional, :atom}}}},
        metadata: :map,
        history: :list,
        extension: :any
      }

    def continuation_contracts, do: %{batch: {:tuple, [:atom, {:list, :integer}]}}
  end

  defmodule InvalidDeclaration do
    def assigns_schema, do: [:integer]
  end

  test "nested collection contracts identify the failing element without exposing its value" do
    assert :ok = Contracts.validate_configuration!(Structured)

    valid = %{
      rows: [%{count: 1.5, enabled: true, label: :ready}],
      metadata: %{},
      history: [],
      extension: {:arbitrary, :data}
    }

    assert :ok = Contracts.validate_assigns(Structured, valid)
    assert :ok = Contracts.validate_assigns(Structured, %{valid | rows: []})

    assert {:error, %{path: [:rows, 0, :count], received: :string}} =
             Contracts.validate_assigns(Structured, put_in(valid, [:rows], [%{count: "PRIVATE"}]))

    for {value, shape} <- [{%{}, :map}, {[], :list}, {2.5, :number}, {self(), :other}] do
      assert {:error, %{received: ^shape}} = Contracts.validate_assigns(App, %{count: value})
    end

    assert_raise Server.ContractError, fn ->
      Contracts.validate_result!(Structured, :batch, {:ok}, %{})
    end

    assert_raise ArgumentError, ~r/must return nil or a map/, fn ->
      Contracts.validate_configuration!(InvalidDeclaration)
    end
  end

  test "retained live workers and older implicit waits preserve continuation rules" do
    assert :ok =
             Contracts.validate_commands!(App, [
               %Server.Command{kind: :generate, args: [], opts: []}
             ])

    assert {:error, %{reason: :undeclared_tag, tag: :non_atom_tag}} =
             Contracts.validate_retained(App, %{
               workers: %{"worker" => %{tag: "PRIVATE", opts: [on_result: "PRIVATE"]}}
             })

    assert :ok =
             Contracts.validate_retained(App, %{
               outbox: %{"historical" => %{}},
               pending: %{"implicit" => %{id: "implicit", kind: :reply, on_result: "implicit"}}
             })

    assert {:error, %{reason: :undeclared_tag}} =
             Contracts.validate_retained(App, %{
               pending: %{"explicit" => %{id: "explicit", kind: :reply, on_result: :removed}}
             })
  end

  defmodule Alternatives do
    def continuation_contracts,
      do: %{
        completed:
          {:one_of,
           [
             {:tuple, [{:enum, [:ok]}, :integer]},
             {:tuple, [{:enum, [:error]}, :string]}
           ]}
      }
  end

  test "invalid declarations fail early and alternative result shapes are checked" do
    assert_raise ArgumentError, ~r/invalid assigns_schema declaration/, fn ->
      Contracts.validate_configuration!(BadSchema)
    end

    assert :ok == Contracts.validate_configuration!(Alternatives)

    for result <- [{:ok, 2}, {:error, "service unavailable"}] do
      assert :ok == Contracts.validate_result!(Alternatives, :completed, result, %{})
    end

    assert_raise Server.ContractError, fn ->
      Contracts.validate_result!(Alternatives, :completed, {:ok, "private"}, %{})
    end
  end

  test "migration cannot silently remove a retained explicit continuation" do
    path = Path.join(System.tmp_dir!(), "retained-contract-#{System.unique_integer([:positive])}")
    {:ok, store} = Server.Store.Disk.start_link(path: path)
    on_exit(fn -> File.rm_rf(path) end)
    opts = [agent: Agent, server: App, checkpoint: {store, :session}]
    {:ok, server} = Server.Runtime.start_link(opts)
    GenServer.stop(server)
    {:ok, %{revision: revision, value: bytes}} = Server.Store.Disk.fetch(store, :session)
    {:ok, projection} = Checkpoint.decode_snapshot(bytes)
    # A previous release accepted this explicit tag. Its approved migration
    # keeps reconciliation facts, but the new Server no longer declares it.
    pending = %{
      id: "wait",
      kind: :reply,
      status: :background,
      origin: nil,
      on_result: :removed_in_new_release,
      explicit_on_result: true,
      deadline: nil
    }

    {:ok, bytes} = Checkpoint.encode_value(%{projection | pending: %{"wait" => pending}})
    {:ok, _} = Server.Store.Disk.compare_and_swap(store, :session, revision, bytes)

    opts =
      Keyword.merge(opts,
        checkpoint_version: 2,
        checkpoint_migrator: {__MODULE__, :repair_assigns}
      )

    assert {:error, {%ArgumentError{message: message}, _}} = Server.Runtime.start_link(opts)
    assert message =~ "undeclared_tag"
    assert message =~ "removed_in_new_release"
  end

  test "retained tags check explicit sources while preserving implicit tool defaults" do
    command = %Server.Command{kind: :generate, args: [:work], opts: [on_result: :removed]}

    assert {:error, %{reason: :undeclared_tag}} =
             Contracts.validate_retained(
               App,
               %{outbox: %{"work" => %{command: command, explicit_on_result: true}}}
             )

    assert {:error, %{reason: :undeclared_tag}} =
             Contracts.validate_retained(
               App,
               %{inbox: %{"result" => %{worker: %{tag: :removed, explicit_on_result: true}}}}
             )

    assert :ok ==
             Contracts.validate_retained(
               App,
               %{
                 outbox: %{"work" => %{command: command, explicit_on_result: false}},
                 inbox: %{"result" => %{worker: %{tag: :removed, explicit_on_result: false}}}
               }
             )
  end
end
