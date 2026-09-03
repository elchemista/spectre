defmodule Spectre.Bench.P1.IdSource do
  @moduledoc false
  @behaviour Spectre.Id.Source

  @prefix "018f0000-0000-7000-8000-"

  @impl true
  def generate do
    suffix =
      System.unique_integer([:monotonic, :positive])
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(12, "0")

    @prefix <> suffix
  end
end

defmodule Spectre.Bench.P1.Ingress do
  @moduledoc false
  @behaviour Spectre.Ingress

  @ref "spectre:bench:p1:ingress:v1"

  @impl true
  def ref, do: @ref

  @impl true
  def authenticate(domain_ref, scope_ref, input, generation, _opts) do
    Spectre.SubmissionContext.new(%{
      domain_ref: domain_ref,
      scope_ref: scope_ref,
      authenticated_principal_ref: Map.fetch!(input, :principal_ref),
      authentication_ref: Map.fetch!(input, :authentication_ref),
      ingress_ref: @ref,
      channel_ref: "spectre:bench:p1:channel",
      session_ref: Map.fetch!(input, :session_ref),
      host_generation: generation
    })
  end

  @impl true
  def observe(context, input, observed_at, _opts) do
    bindings = %{
      "authenticated_principal_ref" => context.authenticated_principal_ref,
      "authentication_ref" => context.authentication_ref,
      "domain_ref" => context.domain_ref,
      "scope_ref" => context.scope_ref
    }

    Spectre.Evidence.new(%{
      proposition: Map.fetch!(input, :proposition),
      issuer_ref: Map.get(input, :issuer_ref, @ref),
      source_ref: @ref,
      provenance: :observed,
      observed_at: observed_at,
      bindings: bindings,
      payload: Map.fetch!(input, :payload),
      provisional: false
    })
  end
end

defmodule Spectre.Bench.P1.Executor do
  @moduledoc false
  @behaviour Spectre.Attempt.Executor

  {:ok, executor} =
    Spectre.Principal.new(%{
      kind: :service,
      display_name: "P1 benchmark executor",
      attributes: %{"contract" => "spectre:bench:p1:executor:v1"}
    })

  @executor executor
  @contract_ref "spectre:bench:p1:executor-contract:v1"

  def principal, do: @executor

  @impl true
  def executor_ref, do: @executor.ref

  @impl true
  def contract_ref, do: @contract_ref

  @impl true
  def execute(_act, _attempt, _capability, _opts) do
    {:error, :ambiguous, %{evidence: [], details_ref: "spectre:bench:p1:executor:not-invoked"}}
  end
end

defmodule Spectre.Bench.P1.Fixture do
  @moduledoc false

  alias Spectre.Bench.P1.{Executor, IdSource, Ingress}
  alias Spectre.Consequence.Contract
  alias Spectre.Domain.Sequencer
  alias Spectre.Genesis.Verifier.Allowlist
  alias Spectre.Ledger.Store.{Disk, ETS}
  alias Spectre.Scope.Opening
  alias Spectre.Secret.Broker.Passthrough

  @generation 1
  @grant_secret :binary.copy(<<0x47>>, 32)
  @checkout_secret :binary.copy(<<0x43>>, 32)

  def start(store_kind, namespace, capacity, batch_size, batch_wait_ms) do
    now = System.system_time(:millisecond)
    refs = refs(namespace)
    executor = Executor.principal()
    grantor = principal!(:human, "grantor", namespace)
    proposer = principal!(:agent, "proposer", namespace)
    accountable = principal!(:organization, "accountable", namespace)
    principals = [grantor, proposer, executor, accountable]

    row = ok!(Spectre.Row.new(%{attempt: true, spend: true}))

    contract =
      ok!(
        Contract.new(%{
          shape: %{
            "meter_requests" => "meter_requests",
            "sequence" => "non_negative_integer",
            "target_ref" => "target_ref"
          }
        })
      )

    condition =
      ok!(
        Spectre.Condition.new(%{
          proposition: "spectre:bench:p1:authorized",
          bindings: %{},
          cardinality: 1,
          accepted_provenance: [:observed],
          allow_provisional: false,
          parameters: %{"issuer_refs" => [Ingress.ref()]}
        })
      )

    surface =
      ok!(
        Spectre.Surface.new(%{
          revision: 1,
          declarations: %{"bench.effect" => row},
          consequence_contracts: %{"bench.effect" => contract}
        })
      )

    profile =
      ok!(
        Spectre.HostProfile.new(%{
          mode: :development,
          attestation_ref: refs.host_attestation,
          assumptions: ["local P1 benchmark"],
          declared_at: now
        })
      )

    mandate =
      ok!(
        Spectre.Mandate.new(%{
          revision: 1,
          grantor_ref: grantor.ref,
          holder_ref: proposer.ref,
          accountable_ref: accountable.ref,
          executor_refs: [executor.ref],
          executor_contract_refs: [Executor.contract_ref()],
          scope_refs: [refs.scope],
          subject_refs: [],
          target_refs: [refs.target],
          classes: ["bench.effect"],
          ceiling: row,
          purpose_ref: refs.purpose,
          purpose_params: %{},
          conditions: [condition],
          not_before: now - 1_000,
          expires_at: now + 3_600_000,
          meters: %{refs.meter => capacity},
          delegation: %{"allowed" => false, "max_depth" => 0},
          revocation: %{"mode" => :cascade, "controller_refs" => [grantor.ref]},
          source_ref: refs.genesis
        })
      )

    constitution = %{
      "duty_rules" =>
        Map.new(
          [
            "ambiguous_outcome",
            "contradicted_outcome",
            "disputed_evidence",
            "scope_promise_overdue",
            "erasure_reduces_verifiability"
          ],
          &{&1, %{"disposition_authority_refs" => [grantor.ref]}}
        )
    }

    genesis =
      ok!(
        Spectre.Genesis.new(%{
          ref: refs.genesis,
          domain_ref: refs.domain,
          principal_refs: Enum.map(principals, & &1.ref),
          root_mandate_refs: [mandate.ref],
          constitution_ref: Spectre.Constitution.ref!(constitution),
          surface_ref: surface.ref,
          surface_revision: surface.revision,
          host_profile_ref: profile.ref,
          issued_at: now,
          attestation_ref: refs.genesis_attestation
        })
      )

    {store, store_config, cleanup} = start_store(store_kind, namespace)

    sequencer_opts = [
      domain_ref: refs.domain,
      store: store_config,
      ingress: Ingress,
      clock: Spectre.Clock.System,
      id_source: IdSource,
      generation: @generation,
      grant_secret: @grant_secret,
      checkout_receipt_secret: @checkout_secret,
      grant_ttl_ms: 600_000,
      batch_size: batch_size,
      batch_wait_ms: batch_wait_ms,
      ambiguous_retries: 2,
      conflict_retries: 8,
      constitution: constitution,
      genesis: genesis,
      principals: principals,
      host_profile: profile,
      surface: surface,
      root_mandates: [mandate],
      genesis_verifier: {Allowlist, attestation_refs: [refs.genesis_attestation]},
      executors: [Executor],
      broker:
        {Passthrough,
         capability: :benchmark_only,
         checkout_receipt_secret: @checkout_secret,
         domain_ref: refs.domain,
         clock: Spectre.Clock.System}
    ]

    server = ok!(Sequencer.start_link(sequencer_opts))
    context = authenticate!(server, refs, proposer.ref)
    opening = session_opening!(context, now)
    ^opening = ok!(Sequencer.open_scope(server, context, opening))

    evidence =
      server
      |> Sequencer.observe(
        context,
        %{
          proposition: "spectre:bench:p1:authorized",
          issuer_ref: Ingress.ref(),
          payload: %{"benchmark" => "authorization"}
        }
      )
      |> ok!()
      |> List.first()

    %{
      server: server,
      store: store,
      store_config: store_config,
      cleanup: cleanup,
      sequencer_opts: sequencer_opts,
      context: context,
      evidence: evidence,
      mandate: mandate,
      row: row,
      refs: refs,
      executor: executor
    }
  end

  def candidate(fixture, sequence) do
    meter_requests = %{fixture.refs.meter => 1}

    %{
      identity_key: "spectre:bench:p1:candidate:#{sequence}",
      class: "bench.effect",
      consequence: %{
        "meter_requests" => meter_requests,
        "sequence" => sequence,
        "target_ref" => fixture.refs.target
      },
      row: fixture.row,
      requested_mandate_ref: fixture.mandate.ref,
      proposer_ref: fixture.context.authenticated_principal_ref,
      executor_ref: fixture.executor.ref,
      accountable_ref: fixture.mandate.accountable_ref,
      scope_ref: fixture.refs.scope,
      subject_refs: [],
      target_refs: [fixture.refs.target],
      purpose_ref: fixture.refs.purpose,
      purpose_params: %{},
      evidence_refs: [fixture.evidence.ref],
      meter_requests: meter_requests,
      executor_contract_ref: Executor.contract_ref(),
      observation_window_ms: 600_000
    }
  end

  def outcome_evidence(_fixture, act, attempt) do
    ok!(
      Spectre.Evidence.new(%{
        proposition:
          Spectre.Outcome.proposition(
            :succeeded,
            act.ref,
            attempt.ref,
            act.executor_contract_ref
          ),
        issuer_ref: act.executor_ref,
        source_ref: act.executor_ref,
        provenance: :observed,
        observed_at: System.system_time(:millisecond),
        bindings: %{"act_ref" => act.ref, "attempt_ref" => attempt.ref},
        payload: %{"benchmark" => "succeeded"},
        provisional: false
      })
    )
  end

  def outcome(act, attempt, evidence) do
    ok!(
      Spectre.Outcome.new(%{
        act_ref: act.ref,
        attempt_ref: attempt.ref,
        status: :succeeded,
        evidence_refs: [evidence.ref],
        observed_at: max(evidence.observed_at, System.system_time(:millisecond)),
        details_ref: "spectre:bench:p1:outcome:succeeded"
      })
    )
  end

  def restart(fixture) do
    stop_process(fixture.server)
    ok!(Sequencer.start_link(fixture.sequencer_opts))
  end

  def stop(fixture, server \\ nil) do
    stop_process(server || fixture.server)
    stop_process(fixture.store)
    fixture.cleanup.()
    :ok
  end

  defp authenticate!(server, refs, proposer_ref) do
    ok!(
      Sequencer.authenticate(server, refs.scope, %{
        principal_ref: proposer_ref,
        authentication_ref: refs.authentication,
        session_ref: refs.session
      })
    )
  end

  defp session_opening!(context, now) do
    ok!(
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
        opened_at: now
      })
    )
  end

  defp start_store(:ets, _namespace) do
    store = ok!(ETS.start_link([]))
    {store, {ETS, server: store}, fn -> :ok end}
  end

  defp start_store(:disk, namespace) do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-p1-bench-#{namespace}-#{System.unique_integer([:positive])}"
      )

    store = ok!(Disk.start_link(path: root))

    cleanup = fn ->
      case File.rm_rf(root) do
        {:ok, _removed} -> :ok
        {:error, reason, path} -> raise "cannot remove #{path}: #{inspect(reason)}"
      end
    end

    {store, {Disk, server: store}, cleanup}
  end

  defp principal!(kind, role, namespace) do
    ok!(
      Spectre.Principal.new(%{
        kind: kind,
        attributes: %{"benchmark_role" => role, "namespace" => namespace}
      })
    )
  end

  defp refs(namespace) do
    prefix = "spectre:bench:p1:#{namespace}:"

    %{
      domain: prefix <> "domain",
      genesis: prefix <> "genesis",
      genesis_attestation: prefix <> "genesis-attestation",
      host_attestation: prefix <> "host-attestation",
      scope: prefix <> "scope",
      target: prefix <> "target",
      purpose: prefix <> "purpose",
      meter: prefix <> "meter",
      authentication: prefix <> "authentication",
      session: prefix <> "session"
    }
  end

  defp stop_process(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    :ok
  end

  defp ok!({:ok, value}), do: value
  defp ok!({:error, reason}), do: raise("P1 benchmark fixture failed: #{inspect(reason)}")
end
