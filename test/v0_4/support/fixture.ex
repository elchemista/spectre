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
    suffix = sequence |> Integer.to_string(16) |> String.pad_leading(12, "0")
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

defmodule Spectre.V04Test.Fixture do
  @moduledoc false

  alias Spectre.Domain.Sequencer
  alias Spectre.Genesis.Verifier.Allowlist
  alias Spectre.Ledger.Store.ETS
  alias Spectre.V04Test.{Clock, IdSource}

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
        else: row

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
        do: governance_mandate(refs, governance_row, now),
        else: nil

    refs =
      if governance_mandate,
        do: Map.put(refs, :governance_mandate, governance_mandate.ref),
        else: refs

    root_mandates = [mandate] ++ List.wrap(governance_mandate)
    genesis = genesis(refs, principal_records, root_mandates, surface, profile, constitution, now)
    payment_evidence = record!(Spectre.Evidence.new(paid_evidence_attrs(refs, now)))
    refs = Map.put(refs, :payment_evidence, payment_evidence.ref)

    store = record!(ETS.start_link([]))
    store_config = {ETS, server: store}

    sequencer_opts =
      [
        domain_ref: refs.domain,
        store: store_config,
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

    server = record!(Sequencer.start_link(sequencer_opts))

    %{
      server: server,
      store: store,
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
  end

  def restart_domain(fixture, overrides \\ []) do
    sequencer_opts = Keyword.merge(fixture.sequencer_opts, overrides)
    server = record!(Sequencer.start_link(sequencer_opts))
    %{fixture | server: server, sequencer_opts: sequencer_opts}
  end

  def stop_domain(fixture) do
    stop_process(fixture.server)
    stop_process(fixture.store)
    :ok
  end

  def stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  def context(fixture, overrides \\ %{}) do
    attrs = %{
      domain_ref: fixture.refs.domain,
      scope_ref: fixture.refs.scope,
      authenticated_principal_ref: fixture.refs.proposer,
      authentication_ref: fixture.refs.authentication,
      ingress_ref: fixture.refs.ingress,
      channel_ref: fixture.refs.channel,
      session_ref: fixture.refs.session,
      host_generation: generation(fixture)
    }

    record!(Spectre.SubmissionContext.new(Map.merge(attrs, Map.new(overrides))))
  end

  def paid_evidence(fixture, overrides \\ %{}) do
    attrs = paid_evidence_attrs(fixture.refs, Clock.now())

    record!(Spectre.Evidence.new(Map.merge(attrs, Map.new(overrides))))
  end

  def receipt_evidence(fixture, act_ref, overrides \\ %{}) do
    attrs = %{
      proposition: "refund_settled",
      issuer_ref: fixture.refs.payment_provider,
      source_ref: fixture.refs.payment_provider,
      provenance: :observed,
      observed_at: Clock.now(),
      bindings: %{"act_ref" => act_ref},
      labels: ["financial"],
      payload_ref: fixture.refs.receipt_payload,
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
        "order_ref" => fixture.refs.order
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
      executor_contract: prefix <> "executor-contract:refund-v1",
      scope: prefix <> "scope:refunds",
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
      principal(:service, refs.executor),
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
      if Keyword.get(opts, :delegation_allowed, false),
        do: Map.put(declarations, "mandate.delegate", delegation_row),
        else: declarations

    declarations =
      if Keyword.get(opts, :governance_allowed, false) do
        declarations
        |> Map.put("mandate.revoke", governance_row)
        |> Map.put("duty.dispose", governance_row)
      else
        declarations
      end

    record!(
      Spectre.Surface.new(%{
        revision: 1,
        declarations: declarations
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
        executor_refs: [refs.executor],
        executor_contract_refs: [refs.executor_contract],
        scope_refs: [refs.scope],
        subject_refs: [refs.customer],
        target_refs: [refs.payment_target],
        classes:
          if(delegation_allowed?,
            do: ["mandate.delegate", "refund.issue"],
            else: ["refund.issue"]
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
        revocation: %{"mode" => :cascade, "controller_refs" => [refs.grantor]},
        source_ref: refs.genesis
      })
    )
  end

  defp governance_mandate(refs, ceiling, now) do
    record!(
      Spectre.Mandate.new(%{
        revision: 1,
        grantor_ref: refs.grantor,
        holder_ref: refs.grantor,
        accountable_ref: refs.accountable,
        executor_refs: [refs.executor],
        executor_contract_refs: [refs.executor_contract],
        scope_refs: [refs.scope],
        subject_refs: [],
        target_refs: [],
        classes: ["duty.dispose", "mandate.revoke"],
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

  defp genesis(refs, principals, root_mandates, surface, profile, constitution, now) do
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
        issued_at: now,
        attestation_ref: refs.genesis_attestation
      })
    )
  end

  defp default_constitution(refs, opts) do
    authority_refs =
      if Keyword.get(opts, :governance_allowed, false), do: [refs.grantor], else: []

    %{
      "duty_rules" => %{
        "ambiguous_outcome" => %{
          "disposition_authority_refs" => authority_refs
        },
        "contradicted_outcome" => %{
          "disposition_authority_refs" => authority_refs
        }
      }
    }
  end

  defp paid_evidence_attrs(refs, now) do
    %{
      proposition: "order_paid",
      issuer_ref: refs.payment_provider,
      source_ref: refs.payment_provider,
      provenance: :observed,
      observed_at: now,
      bindings: %{"order_ref" => refs.order},
      labels: ["financial"],
      payload_ref: refs.payment_payload,
      provisional: false
    }
  end

  defp record!({:ok, record}), do: record
  defp record!({:error, reason}), do: raise("invalid v0.4 fixture: #{inspect(reason)}")
end
