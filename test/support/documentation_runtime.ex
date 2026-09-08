defmodule Spectre.Test.DocumentationRuntime do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Spectre.{Consequence.Contract, Mandate, Row}
  alias Spectre.Test.HandlerAgentCase.Executor
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule Ingress do
    @moduledoc false
    use Spectre.Ingress, ref: "spectre:test:ingress"

    @impl true
    defdelegate authenticate(domain, scope, input, generation, opts), to: Spectre.V04Test.Ingress

    @impl true
    def observe(context, input, now, _opts) do
      Spectre.Ingress.evidence(context, now,
        proposition: "user.request",
        issuer_ref: context.authenticated_principal_ref,
        payload: input
      )
    end
  end

  defmodule Mind do
    @moduledoc false
    use Spectre.Mind, ref: "mind:documentation"

    @impl true
    def deliberate(turn, _opts) do
      # The test host proposes the input payload, not an authorized action.
      # Authentication and the kernel still decide what may actually execute.
      [evidence] = turn.evidence

      attrs =
        evidence.payload
        |> Map.put(:evidence_refs, [evidence.ref])
        |> Map.update!(:disclosure, &Map.put(&1, :source_evidence_refs, [evidence.ref]))

      Spectre.Mind.candidate(turn, attrs)
    end
  end

  def fixture(definition \\ nil) do
    Runtime.reset(Fixture.default_now())
    namespace = "guide-#{System.unique_integer([:positive])}"
    {:ok, row} = Row.new(attempt: true, read: true)
    {:ok, help_row} = Row.new(attempt: true)
    {:ok, contract} = Contract.new(shape: %{"order_id" => "target_ref"})
    {:ok, help_contract} = Contract.new(shape: %{"target_ref" => "target_ref"})

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: {:via, Registry, {Spectre.Domain.Registry, "v0.4:#{namespace}:domain"}},
        mind: Spectre.Agent,
        ingress: Ingress,
        executors: [{Executor, observer: self()}],
        governance_allowed: true,
        governance_classes: ["definition.revise"],
        governance_targets: if(definition, do: [definition.ref], else: []),
        governance_declarations: %{"orders.lookup" => row, "support.help" => help_row},
        consequence_contracts: %{"orders.lookup" => contract, "support.help" => help_contract},
        additional_mandates: fn root ->
          attrs =
            root
            |> Map.from_struct()
            |> Map.delete(:ref)
            |> Map.merge(%{
              ceiling: row,
              classes: ["orders.lookup", "support.help"],
              conditions: [],
              meters: %{},
              subject_refs: [],
              target_refs: ["42", "support:help"]
            })

          {:ok, lookup} = Mandate.new(attrs)
          [lookup]
        end
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  def activate(definition) do
    fixture = fixture(definition)
    {:ok, domain} = Spectre.lookup_domain(fixture.refs.domain)
    {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))

    {:ok, admin} =
      Spectre.resume_scope(
        domain,
        Fixture.context(fixture, authenticated_principal_ref: fixture.refs.grantor)
      )

    assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
             Spectre.revise_definition(admin, definition,
               identity_key: "publish-guide",
               requested_mandate_ref: fixture.governance_mandate.ref,
               accountable_ref: fixture.refs.accountable,
               purpose_ref: fixture.refs.purpose,
               purpose_params: %{"currency" => "EUR"}
             )

    [lookup] = fixture.additional_mandates

    occurrence = %{
      requested_mandate_ref: lookup.ref,
      executor_ref: fixture.refs.executor,
      executor_contract_ref: fixture.refs.executor_contract,
      accountable_ref: fixture.refs.accountable,
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"},
      observation_window_ms: 5_000
    }

    {fixture,
     [
       scope: scope,
       definition: definition,
       class_bindings: %{"orders.lookup" => occurrence, "support.help" => occurrence}
     ]}
  end

  def host_bindings(fixture) do
    Keyword.take(fixture.sequencer_opts, [
      :domain_ref,
      :constitution,
      :genesis,
      :principals,
      :host_profile,
      :surface,
      :root_mandates,
      :genesis_verifier,
      :ingress,
      :executors,
      :broker,
      :clock
    ]) ++
      [
        genesis_ref: fixture.genesis.ref,
        issued_at: fixture.genesis.issued_at,
        attestation_ref: fixture.genesis.attestation_ref
      ]
  end
end
