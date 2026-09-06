defmodule Spectre.V04Test.Runtime do
  @moduledoc false

  @table :spectre_v04_test_runtime
  @uuid_prefix "018f0000-0000-7000-8000-"

  def reset(now) when is_integer(now) do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _table -> :ets.delete_all_objects(@table)
    end

    true = :ets.insert(@table, now: now, id: 0)
    :ok
  end

  def set_time(now) when is_integer(now) do
    true = :ets.insert(@table, {:now, now})
    :ok
  end

  def now do
    :ets.lookup_element(@table, :now, 2)
  end

  def next_id do
    sequence = :ets.update_counter(@table, :id, 1)
    suffix = sequence |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
    @uuid_prefix <> suffix
  end
end

defmodule Spectre.V04Test.Clock do
  @moduledoc false
  @behaviour Spectre.Clock

  alias Spectre.V04Test.Runtime

  @impl true
  def now, do: Runtime.now()
end

defmodule Spectre.V04Test.IdSource do
  @moduledoc false
  @behaviour Spectre.Id.Source

  alias Spectre.V04Test.Runtime

  @impl true
  def generate, do: Runtime.next_id()
end

defmodule Spectre.V04Test.Ingress do
  @moduledoc false
  @behaviour Spectre.Ingress

  @impl true
  def ref, do: "spectre:test:ingress"

  @impl true
  def authenticate(domain, scope, input, generation, _opts) do
    Spectre.SubmissionContext.new(%{
      domain_ref: domain,
      scope_ref: scope,
      authenticated_principal_ref: input.principal_ref,
      authentication_ref: input.authentication_ref,
      ingress_ref: ref(),
      channel_ref: "spectre:test:channel",
      session_ref: input.session_ref,
      host_generation: generation
    })
  end

  @impl true
  def observe(context, attrs, now, _opts) do
    attrs
    |> Map.put(:source_ref, ref())
    |> Map.put(:observed_at, now)
    |> Map.update!(
      :bindings,
      &Map.merge(&1, Spectre.SubmissionContext.evidence_bindings(context))
    )
    |> Spectre.Evidence.new()
  end
end

defmodule Spectre.V04Test.Executor do
  @moduledoc false
  @behaviour Spectre.Attempt.Executor

  {:ok, principal} = Spectre.Principal.new(%{kind: :service, attributes: %{"test" => "refund"}})
  @principal principal

  def principal, do: @principal
  @impl true
  def executor_ref, do: @principal.ref
  @impl true
  def contract_ref, do: "spectre:test:refund-contract"
  @impl true
  def execute(_act, _attempt, _capability, _opts), do: {:error, :ambiguous, %{evidence: []}}
end

defmodule Spectre.V04Test.Fixture do
  @moduledoc false

  alias Spectre.Consequence.Contract
  alias Spectre.Domain.Sequencer
  alias Spectre.Genesis.Verifier.Allowlist
  alias Spectre.GovernedAct.Execution
  alias Spectre.Ledger.Store.{ETS, Mock}
  alias Spectre.Scope.Opening
  alias Spectre.V04Test.{Clock, Executor, IdSource, Ingress}

  @default_now 1_000_000
  @default_generation 7
  @default_meter_ceiling 10_000
  @default_observation_window 5_000
  @grant_secret :binary.copy(<<0x5A>>, 32)

  def start_domain(opts \\ []) do
    namespace = Keyword.get(opts, :namespace, "refund")
    now = Clock.now()
    refs = refs(namespace)

    principal_records = principals(refs)
    [grantor, proposer, executor, accountable] = principal_records

    refs =
      Map.merge(refs, %{
        grantor: grantor.ref,
        proposer: proposer.ref,
        executor: executor.ref,
        accountable: accountable.ref
      })

    constitution =
      Keyword.get(opts, :constitution, default_constitution(refs, opts))
      |> Map.merge(Keyword.get(opts, :constitution_overrides, %{}))

    row = record!(Spectre.Row.new(%{attempt: true, disclose: true, spend: true}))
    delegation_row = record!(Spectre.Row.new(%{delegate: true, govern: true}))
    governance_row = record!(Spectre.Row.new(%{govern: true}))
    delegation_allowed? = Keyword.get(opts, :delegation_allowed, false)
    governance_allowed? = Keyword.get(opts, :governance_allowed, false)

    mandate_ceiling =
      if delegation_allowed?,
        do:
          record!(
            Spectre.Row.new(%{
              attempt: true,
              disclose: true,
              spend: true,
              delegate: true,
              govern: true
            })
          ),
        else: if(Keyword.get(opts, :consent, false), do: %{row | present: true}, else: row)

    condition = payment_condition(refs)
    refs = Map.put(refs, :condition, condition.ref)
    surface = surface(row, delegation_row, governance_row, opts)
    refs = Map.put(refs, :surface, surface.ref)
    profile = host_profile(refs, now)
    refs = Map.put(refs, :host_profile, profile.ref)
    mandate = mandate(refs, mandate_ceiling, condition, constitution, now, opts)
    refs = Map.put(refs, :mandate, mandate.ref)

    governance_mandate =
      if governance_allowed?,
        do:
          governance_mandate(
            refs,
            Keyword.get(opts, :governance_ceiling, governance_row),
            now,
            opts
          ),
        else: nil

    refs =
      if governance_mandate,
        do: Map.put(refs, :governance_mandate, governance_mandate.ref),
        else: refs

    root_mandates = [mandate] ++ List.wrap(governance_mandate)
    emergency_ref = if Keyword.get(opts, :emergency_mandate, false), do: mandate.ref

    genesis =
      genesis(
        refs,
        principal_records,
        root_mandates,
        surface,
        profile,
        constitution,
        now,
        emergency_ref
      )

    {store, underlying_store} = ledger_store(opts)

    mock =
      if Keyword.get(opts, :mock_store, false),
        do: record!(Mock.start_link(store: underlying_store))

    store_config = if mock, do: {Mock, server: mock}, else: underlying_store

    sequencer_opts =
      [
        domain_ref: refs.domain,
        store: store_config,
        ingress: Ingress,
        executors: Keyword.get(opts, :executors, [Executor]),
        checkout_receipt_secret: @grant_secret,
        broker:
          {Spectre.Secret.Broker.Passthrough,
           capability: Keyword.get(opts, :capability, :test_only),
           domain_ref: refs.domain,
           clock: Clock,
           checkout_receipt_secret: @grant_secret},
        clock: Clock,
        id_source: IdSource,
        generation: Keyword.get(opts, :generation, @default_generation),
        grant_secret: Keyword.get(opts, :grant_secret, @grant_secret),
        grant_ttl_ms: Keyword.get(opts, :grant_ttl_ms, 60_000),
        batch_size: Keyword.get(opts, :batch_size, 64),
        batch_wait_ms: Keyword.get(opts, :batch_wait_ms, 0),
        ambiguous_retries: Keyword.get(opts, :ambiguous_retries, 2),
        conflict_retries: Keyword.get(opts, :conflict_retries, 8),
        constitution: constitution,
        genesis: genesis,
        principals: principal_records,
        host_profile: profile,
        surface: surface,
        root_mandates: root_mandates,
        genesis_verifier: {Allowlist, attestation_refs: [refs.genesis_attestation]}
      ]

    sequencer_opts =
      Keyword.merge(
        sequencer_opts,
        Keyword.take(opts, [
          :name,
          :mind,
          :context,
          :payload_store,
          :late_observer,
          :ingress,
          :ingress_max_concurrency,
          :ingress_timeout,
          :max_pending_submissions
        ])
      )

    server = record!(Sequencer.start_link(sequencer_opts))

    fixture = %{
      server: server,
      store: store,
      mock: mock,
      store_config: store_config,
      sequencer_opts: sequencer_opts,
      refs: refs,
      row: row,
      delegation_row: delegation_row,
      governance_row: governance_row,
      condition: condition,
      mandate: mandate,
      governance_mandate: governance_mandate,
      genesis: genesis,
      constitution: constitution,
      observation_window_ms:
        Keyword.get(opts, :observation_window_ms, @default_observation_window)
    }

    open_session(fixture, context(fixture))

    if governance_allowed?,
      do: open_session(fixture, context(fixture, authenticated_principal_ref: refs.grantor))

    payment = paid_evidence(fixture)
    %{fixture | refs: Map.put(fixture.refs, :payment_evidence, payment.ref)}
  end

  def restart_domain(fixture, overrides \\ []) do
    sequencer_opts = Keyword.merge(fixture.sequencer_opts, overrides)
    server = record!(Sequencer.start_link(sequencer_opts))
    %{fixture | server: server, sequencer_opts: sequencer_opts}
  end

  defp ledger_store(opts) do
    case Keyword.fetch(opts, :store) do
      {:ok, {_adapter, store_opts} = configured} ->
        {Keyword.fetch!(store_opts, :server), configured}

      :error ->
        server = record!(ETS.start_link([]))
        {server, {ETS, server: server}}
    end
  end

  def stop_domain(fixture) do
    stop_process(fixture.server)
    if fixture.mock, do: stop_process(fixture.mock)
    stop_process(fixture.store)
    :ok
  end

  def stop_process(pid) when is_pid(pid) do
    # Teardown may race with a linked process finishing after its owner exits.
    GenServer.stop(pid)
  catch
    :exit, {:noproc, {GenServer, :stop, [^pid | _args]}} -> :ok
  end

  def context(fixture, overrides \\ %{}) do
    overrides = Map.new(overrides)
    principal = Map.get(overrides, :authenticated_principal_ref, fixture.refs.proposer)

    scope =
      if principal == fixture.refs.grantor,
        do: fixture.refs.governance_scope,
        else: fixture.refs.scope

    context =
      record!(
        Sequencer.authenticate(fixture.server, scope, %{
          principal_ref: principal,
          authentication_ref: fixture.refs.authentication,
          session_ref: fixture.refs.session
        })
      )

    struct!(context, Map.drop(overrides, [:authenticated_principal_ref]))
  end

  def paid_evidence(fixture, overrides \\ %{}) do
    attrs = paid_evidence_attrs(fixture.refs, Clock.now())

    record!(
      Ingress.observe(context(fixture), Map.merge(attrs, Map.new(overrides)), Clock.now(), [])
    )
  end

  def observe_payment(fixture, evidence, opts \\ []) do
    attrs = evidence |> Map.from_struct() |> Map.drop([:ref])

    with {:ok, [recorded]} <- Sequencer.observe(fixture.server, context(fixture), attrs, opts),
         do: {:ok, recorded}
  end

  def record_receipt(fixture, evidence, opts \\ []) do
    with {:ok, [recorded]} <-
           Sequencer.record_executor_evidence(
             fixture.server,
             evidence.bindings["act_ref"],
             evidence.bindings["attempt_ref"],
             evidence,
             opts
           ),
         do: {:ok, recorded}
  end

  def receipt_evidence(fixture, act_ref, overrides \\ %{}) do
    projection = Sequencer.projection(fixture.server)
    act = Map.fetch!(projection.acts, act_ref)
    attempt = Enum.find(Map.values(projection.attempts), &(&1.act_ref == act_ref))

    attrs = %{
      proposition:
        Spectre.Outcome.proposition(:succeeded, act_ref, attempt.ref, act.executor_contract_ref),
      issuer_ref: act.executor_ref,
      source_ref: act.executor_ref,
      provenance: :observed,
      observed_at: Clock.now(),
      bindings: %{"act_ref" => act_ref, "attempt_ref" => attempt.ref},
      labels: [],
      payload: %{"receipt" => fixture.refs.receipt_payload},
      provisional: false
    }

    record!(Spectre.Evidence.new(Map.merge(attrs, Map.new(overrides))))
  end

  def refund_candidate(fixture, amount, opts \\ []) do
    identity_key = Keyword.get(opts, :identity_key, fixture.refs.candidate_identity)
    evidence_refs = Keyword.get(opts, :evidence_refs, [fixture.refs.payment_evidence])

    %{
      identity_key: identity_key,
      class: "refund.issue",
      consequence: %{
        "amount_cents" => amount,
        "currency" => "EUR",
        "customer_ref" => fixture.refs.customer,
        "order_ref" => fixture.refs.order,
        "destination_ref" => fixture.refs.payment_target,
        "meter_requests" => %{fixture.refs.meter => amount}
      },
      row: fixture.row,
      requested_mandate_ref: fixture.mandate.ref,
      proposer_ref: fixture.refs.proposer,
      executor_ref: fixture.refs.executor,
      accountable_ref: fixture.refs.accountable,
      scope_ref: fixture.refs.scope,
      subject_refs: [fixture.refs.customer],
      target_refs: [fixture.refs.payment_target],
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{"currency" => "EUR"},
      evidence_refs: evidence_refs,
      disclosure: %{
        destination_refs: [fixture.refs.payment_target],
        source_evidence_refs: evidence_refs,
        labels: []
      },
      meter_requests: %{fixture.refs.meter => amount},
      executor_contract_ref: fixture.refs.executor_contract,
      observation_window_ms:
        Keyword.get(opts, :observation_window_ms, fixture.observation_window_ms)
    }
  end

  def outcome(fixture, act, attempt, status, evidence_refs \\ []) do
    record!(
      Spectre.Outcome.new(%{
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        status: status,
        evidence_refs: evidence_refs,
        observed_at: Clock.now(),
        details_ref: fixture.refs.outcome_details <> ":" <> Atom.to_string(status)
      })
    )
  end

  def snapshot(fixture) do
    record!(Spectre.Ledger.load(fixture.store_config, fixture.refs.domain))
  end

  def event_types(snapshot) do
    Enum.map(snapshot.entries, &Map.fetch!(&1.payload, "type"))
  end

  def generation(fixture), do: Keyword.fetch!(fixture.sequencer_opts, :generation)

  def default_now, do: @default_now

  defp refs(namespace) do
    prefix = "v0.4:" <> namespace <> ":"

    %{
      domain: prefix <> "domain",
      genesis: prefix <> "genesis",
      genesis_attestation: prefix <> "genesis-attestation",
      constitution: prefix <> "constitution",
      host_attestation: prefix <> "host-attestation",
      grantor: prefix <> "principal:grantor",
      proposer: prefix <> "principal:agent",
      executor: prefix <> "principal:payment-executor",
      accountable: prefix <> "principal:merchant",
      payment_provider: prefix <> "payment-provider",
      executor_contract: Executor.contract_ref(),
      scope: prefix <> "scope:refunds",
      governance_scope: prefix <> "scope:governance",
      customer: prefix <> "customer:42",
      order: prefix <> "order:paid-42",
      payment_target: prefix <> "payment-account:42",
      purpose: prefix <> "purpose:refund-paid-order",
      meter: prefix <> "meter:refund-cents",
      authentication: prefix <> "authentication",
      ingress: prefix <> "ingress",
      channel: prefix <> "channel",
      session: prefix <> "session",
      candidate_identity: prefix <> "candidate:refund-42",
      payment_payload: prefix <> "payload:order-paid",
      receipt_payload: prefix <> "payload:refund-receipt",
      outcome_details: prefix <> "outcome-details"
    }
  end

  defp principals(refs) do
    [
      principal(:human, refs.grantor),
      principal(:agent, refs.proposer),
      Executor.principal(),
      principal(:organization, refs.accountable)
    ]
  end

  defp principal(kind, external_ref) do
    record!(
      Spectre.Principal.new(%{
        kind: kind,
        attributes: %{"external_ref" => external_ref}
      })
    )
  end

  defp payment_condition(refs) do
    record!(
      Spectre.Condition.new(%{
        proposition: "order_paid",
        bindings: %{"order_ref" => refs.order},
        cardinality: 1,
        accepted_provenance: [:observed],
        allow_provisional: false,
        parameters: %{"issuer_refs" => [refs.payment_provider]}
      })
    )
  end

  defp surface(row, delegation_row, governance_row, opts) do
    declarations = %{"refund.issue" => row}

    declarations =
      if Keyword.get(opts, :consent, false),
        do: Map.put(declarations, "presentation.show", Spectre.Presentation.show_row()),
        else: declarations

    declarations =
      if Keyword.get(opts, :delegation_allowed, false),
        do: Map.put(declarations, "mandate.delegate", delegation_row),
        else: declarations

    declarations =
      if Keyword.get(opts, :governance_allowed, false) do
        declarations
        |> Map.put("mandate.revoke", governance_row)
        |> Map.put("duty.dispose", governance_row)
        |> Map.merge(Map.new(Keyword.get(opts, :governance_classes, []), &{&1, governance_row}))
        |> Map.merge(Keyword.get(opts, :governance_declarations, %{}))
      else
        declarations
      end

    record!(
      Spectre.Surface.new(%{
        revision: 1,
        declarations: declarations,
        fallbacks: Keyword.get(opts, :fallbacks, %{}),
        presentation_required_classes:
          if(Keyword.get(opts, :consent, false), do: ["refund.issue"], else: []),
        consequence_contracts: %{
          "refund.issue" =>
            record!(
              Contract.new(%{
                shape: %{
                  "amount_cents" => "positive_integer",
                  "currency" => %{"$const" => "EUR"},
                  "customer_ref" => "subject_ref",
                  "order_ref" => "ref",
                  "destination_ref" => "destination_ref",
                  "meter_requests" => "meter_requests"
                }
              })
            )
        }
      })
    )
  end

  defp host_profile(refs, now) do
    record!(
      Spectre.HostProfile.new(%{
        mode: :development,
        attestation_ref: refs.host_attestation,
        assumptions: ["test-only in-memory ledger"],
        declared_at: now
      })
    )
  end

  defp mandate(refs, ceiling, condition, _constitution, now, opts) do
    delegation_allowed? = Keyword.get(opts, :delegation_allowed, false)

    record!(
      Spectre.Mandate.new(%{
        revision: 1,
        grantor_ref: refs.grantor,
        holder_ref: refs.proposer,
        accountable_ref: refs.accountable,
        executor_refs:
          if(delegation_allowed?,
            do: [refs.executor, Execution.kernel_executor_ref()],
            else: [refs.executor]
          ),
        executor_contract_refs:
          if(delegation_allowed?,
            do: [refs.executor_contract, Execution.kernel_contract_ref()],
            else: [refs.executor_contract]
          ),
        scope_refs: Keyword.get(opts, :scope_refs, [refs.scope]),
        subject_refs: [refs.customer],
        target_refs:
          if(Keyword.get(opts, :consent, false),
            do: [refs.payment_target, refs.proposer],
            else: [refs.payment_target]
          ),
        classes:
          if(delegation_allowed?,
            do: ["mandate.delegate", "refund.issue"],
            else:
              if(Keyword.get(opts, :consent, false),
                do: ["refund.issue", "presentation.show"],
                else: ["refund.issue"]
              )
          ),
        ceiling: ceiling,
        purpose_ref: refs.purpose,
        purpose_params: %{"currency" => "EUR"},
        conditions: [condition],
        not_before: now - 1_000,
        expires_at: now + 600_000,
        meters: %{refs.meter => Keyword.get(opts, :meter_ceiling, @default_meter_ceiling)},
        delegation:
          if(delegation_allowed?,
            do: %{"allowed" => true, "max_depth" => 1},
            else: %{"allowed" => false, "max_depth" => 0}
          ),
        revocation: %{
          "mode" => Keyword.get(opts, :revocation_mode, :cascade),
          "controller_refs" => [refs.grantor]
        },
        source_ref: refs.genesis
      })
    )
  end

  defp governance_mandate(refs, ceiling, now, opts) do
    record!(
      Spectre.Mandate.new(%{
        revision: 1,
        grantor_ref: refs.grantor,
        holder_ref: refs.grantor,
        accountable_ref: refs.accountable,
        executor_refs:
          Keyword.get(opts, :governance_executor_refs, [Execution.kernel_executor_ref()]),
        executor_contract_refs:
          Keyword.get(opts, :governance_executor_contract_refs, [Execution.kernel_contract_ref()]),
        scope_refs: [refs.governance_scope],
        subject_refs: [],
        target_refs: [refs.mandate | Keyword.get(opts, :governance_targets, [])],
        classes: ["duty.dispose", "mandate.revoke" | Keyword.get(opts, :governance_classes, [])],
        ceiling: ceiling,
        purpose_ref: refs.purpose,
        purpose_params: %{"currency" => "EUR"},
        conditions: [],
        not_before: now - 1_000,
        expires_at: now + 600_000,
        meters: %{},
        delegation: %{"allowed" => false, "max_depth" => 0},
        revocation: %{"mode" => :cascade, "controller_refs" => [refs.grantor]},
        source_ref: refs.genesis
      })
    )
  end

  defp genesis(
         refs,
         principals,
         root_mandates,
         surface,
         profile,
         constitution,
         now,
         emergency_ref
       ) do
    record!(
      Spectre.Genesis.new(%{
        ref: refs.genesis,
        domain_ref: refs.domain,
        principal_refs: Enum.map(principals, & &1.ref),
        root_mandate_refs: Enum.map(root_mandates, & &1.ref),
        constitution_ref: Spectre.Constitution.ref!(constitution),
        surface_ref: surface.ref,
        surface_revision: surface.revision,
        host_profile_ref: profile.ref,
        emergency_mandate_ref: emergency_ref,
        issued_at: now,
        attestation_ref: refs.genesis_attestation
      })
    )
  end

  defp default_constitution(refs, opts) do
    %{
      "duty_rules" =>
        Map.new(
          ~w(ambiguous_outcome contradicted_outcome disputed_evidence scope_promise_overdue erasure_reduces_verifiability),
          &{&1, %{"disposition_authority_refs" => [refs.grantor]}}
        )
        |> Map.merge(Keyword.get(opts, :duty_rules, %{}))
    }
  end

  defp paid_evidence_attrs(refs, now) do
    %{
      proposition: "order_paid",
      issuer_ref: refs.payment_provider,
      source_ref: Ingress.ref(),
      provenance: :observed,
      observed_at: now,
      bindings: %{"order_ref" => refs.order},
      labels: [],
      payload: %{"payment" => refs.payment_payload},
      provisional: false
    }
  end

  defp open_session(fixture, context) do
    opening =
      record!(
        Opening.new(%{
          ref: context.scope_ref,
          domain_ref: context.domain_ref,
          kind: :session,
          opened_by_ref: context.authenticated_principal_ref,
          submission_context_ref: context.ref,
          authentication_ref: context.authentication_ref,
          ingress_ref: context.ingress_ref,
          channel_ref: context.channel_ref,
          session_ref: context.session_ref,
          host_generation: context.host_generation,
          disposition_authority_refs: [],
          opened_at: Clock.now()
        })
      )

    record!(Sequencer.open_scope(fixture.server, context, opening))
  end

  defp record!({:ok, record}), do: record
  defp record!({:error, reason}), do: raise("invalid v0.4 fixture: #{inspect(reason)}")
end
