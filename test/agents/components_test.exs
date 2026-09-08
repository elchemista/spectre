defmodule Spectre.Agents.ComponentsTest do
  use ExUnit.Case, async: false

  alias Spectre.{Audit, Condition, Instance, Ledger, Scope}
  alias Spectre.Domain.Sequencer
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule OrderWork do
    use Spectre.Worker, namespace: "components", name: "orders"
    @impl true
    def handle_work(%{payload: "reject"}, _turn, state), do: {:error, :job_declined, state}
    def handle_work(_input, _turn, state), do: {:ok, state + 1}
  end

  defmodule DeliveryWatch do
    use Spectre.Vigil, namespace: "components", name: "delivery"
    @impl true
    def handle_vigil(%{payload: "reject"}, _turn, state), do: {:error, :job_declined, state}
    def handle_vigil(_input, _turn, state), do: {:ok, state + 1}
  end

  defmodule Parent do
    use Spectre.Agent, namespace: "components", name: "parent"
    worker(:orders, OrderWork)
    vigil(:delivery, DeliveryWatch)
  end

  for {kind, name, module, scope_kind} <- [
        {:worker, :orders, OrderWork, :work},
        {:vigil, :delivery, DeliveryWatch, :vigil}
      ] do
    describe "reusable #{kind}" do
      setup do
        Runtime.reset(Fixture.default_now())
        parent_definition = Parent.definition(revision: 1, declared_at: Runtime.now())
        child_definition = unquote(module).definition(revision: 1, declared_at: Runtime.now())
        namespace = "component-#{System.unique_integer([:positive])}"
        domain_ref = "v0.4:#{namespace}:domain"
        scope_ref = "scope:#{namespace}:job"
        {:ok, row} = Spectre.Row.new(write: true, govern: true)

        fixture =
          Fixture.start_domain(
            namespace: namespace,
            name: {:via, Registry, {Spectre.Domain.Registry, domain_ref}},
            mind: Spectre.Agent,
            governance_allowed: true,
            governance_classes: ["definition.revise", "scope.open"],
            governance_targets: [parent_definition.ref, child_definition.ref, scope_ref],
            governance_ceiling: row,
            governance_declarations: %{"scope.open" => row}
          )

        on_exit(fn -> Fixture.stop_domain(fixture) end)
        {:ok, domain} = Spectre.lookup_domain(domain_ref)

        {:ok, admin} =
          Spectre.resume_scope(
            domain,
            Fixture.context(fixture,
              authenticated_principal_ref: fixture.refs.grantor
            )
          )

        candidate = %{
          identity_key: "open-job",
          requested_mandate_ref: fixture.governance_mandate.ref,
          accountable_ref: fixture.refs.accountable,
          purpose_ref: fixture.refs.purpose,
          purpose_params: %{"currency" => "EUR"}
        }

        for definition <- [parent_definition, child_definition] do
          assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
                   Spectre.revise_definition(admin, definition, %{
                     candidate
                     | identity_key: definition.ref
                   })
        end

        parent =
          start_supervised!(
            {Instance, agent: Parent, scope: admin, definition: parent_definition, state: 0}
          )

        supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

        {:ok, context} =
          Spectre.authenticate(domain, scope_ref, %{
            principal_ref: fixture.refs.proposer,
            authentication_ref: "authentication:job",
            session_ref: "session:job"
          })

        {:ok, condition} =
          Condition.new(proposition: "job.finished", bindings: %{"scope_ref" => scope_ref})

        opening = %{
          kind: unquote(scope_kind),
          promise_condition: condition,
          accountable_ref: fixture.refs.accountable,
          disposition_authority_refs: [fixture.refs.executor],
          due_at: Runtime.now() + 60_000
        }

        input =
          fixture
          |> Fixture.paid_evidence(proposition: "job.progress", payload: "start")
          |> Map.from_struct()
          |> Map.delete(:ref)

        options = [
          definition: child_definition,
          state: 0,
          input: input,
          supervisor: supervisor,
          opening: [context: context, attributes: opening, candidate: candidate]
        ]

        %{
          parent: parent,
          fixture: fixture,
          scope_ref: scope_ref,
          options: options,
          kind: unquote(kind),
          name: unquote(name),
          scope_kind: unquote(scope_kind)
        }
      end

      test "opens the governed promise then starts one independently supervised state owner", c do
        assert {:ok, child} = start(c, c.options)
        refute child == c.parent
        assert Instance.state(child).value == 1
        assert Instance.state(c.parent).value == 0
        assert Scope.ref(Instance.scope(child)) == c.scope_ref
        projection = Sequencer.projection(c.fixture.server)
        assert projection.catalog.scopes[c.scope_ref].kind == c.scope_kind
        assert Instance.current_turn(child).requests == []
        # Finishing a callback, or stopping its process, cannot close a promise.
        GenServer.stop(child, :normal)
        assert Sequencer.projection(c.fixture.server) == projection
        assert_audit(c)
      end

      test "wrong kind and unwired ports fail before any scope is appended", c do
        before = Sequencer.projection(c.fixture.server)
        other = if c.scope_kind == :work, do: :vigil, else: :work

        options =
          Keyword.update!(c.options, :opening, fn opening ->
            Keyword.update!(opening, :attributes, &Map.put(&1, :kind, other))
          end)

        assert {:error, :component_scope_kind_mismatch} = start(c, options)

        assert {:error, _} =
                 start(c, Keyword.put(c.options, :adapters, %{router: %{unknown: String}}))

        assert Sequencer.projection(c.fixture.server) === before
      end

      test "a failing first handler leaves the already opened promise visible to the host", c do
        options = Keyword.update!(c.options, :input, &Map.put(&1, :payload, "reject"))

        assert {:error, {:component_initial_turn_failed, child, ref, :job_declined}} =
                 start(c, options)

        assert ref == c.scope_ref
        assert Process.alive?(child)
        assert Instance.state(child).value == 0
        assert Map.has_key?(Sequencer.projection(c.fixture.server).catalog.scopes, ref)
        assert_audit(c)
      end
    end
  end

  defp start(c, options), do: Spectre.Agent.start_component(c.parent, c.kind, c.name, options)

  defp assert_audit(c) do
    assert {:ok, export} = Ledger.export(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _} = Audit.verify(export, c.fixture.constitution, Runtime.now())
  end
end
