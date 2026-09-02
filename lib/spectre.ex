defmodule Spectre do
  @moduledoc """
  Public 0.4 boundary for governed Acts.

  The public surface is intentionally small. Host code wires one explicit
  ledger Store into a supervised Domain, an authenticated ingress adapter
  supplies a `Spectre.SubmissionContext`, and callers durably open a Scope
  before proposing a Candidate. `propose/3` keeps Admission and execution in
  one call so the internal Grant can never escape to application code.

  Administrative helpers only construct Candidates and submit them through the
  same kernel. This module exposes no direct ledger append, raw Grant, arbitrary
  observed-Evidence insertion or post-Genesis root-authority mutation.

  ## Minimal flow

      {:ok, domain} =
        Spectre.start_domain("domain:payments", store,
          ingress: MyApp.Ingress,
          genesis: genesis,
          principals: principals,
          host_profile: host_profile,
          surface: surface,
          root_mandates: root_mandates,
          genesis_verifier: MyApp.GenesisVerifier,
          executors: [MyApp.PaymentExecutor],
          broker: MyApp.CredentialBroker
        )

      {:ok, context} = Spectre.authenticate(domain, scope_ref, request)
      {:ok, scope} = Spectre.open_scope(domain, context, opened_at: now)
      {:ok, result} = Spectre.propose(scope, candidate)

  A Scope and Domain handle are routing values, not authority. Copying either
  does not copy a Mandate, reservation or capability.
  """

  alias Spectre.Attempt.Runner
  alias Spectre.Candidate
  alias Spectre.Domain
  alias Spectre.Domain.Projection
  alias Spectre.Domain.Sequencer
  alias Spectre.Domain.Supervisor, as: DomainSupervisor
  alias Spectre.Evidence
  alias Spectre.Fallback
  alias Spectre.Governance
  alias Spectre.Ledger.Store
  alias Spectre.Mind
  alias Spectre.Mind.Turn
  alias Spectre.Mandate
  alias Spectre.Outcome
  alias Spectre.Portable
  alias Spectre.Presentation
  alias Spectre.Proposal.Result, as: ProposalResult
  alias Spectre.Scope
  alias Spectre.Scope.Opening
  alias Spectre.Scope.View, as: ScopeView
  alias Spectre.SubmissionContext
  alias Spectre.Surface

  @version "0.4.0"
  @registry Spectre.Domain.Registry
  @reserved_domain_options [:domain_ref, :store, :name, :registry]
  @domain_options [
    :ingress,
    :clock,
    :id_source,
    :late_observer,
    :mind,
    :generation,
    :grant_secret,
    :checkout_receipt_secret,
    :grant_ttl_ms,
    :batch_size,
    :batch_wait_ms,
    :conflict_retries,
    :ambiguous_retries,
    :ledger_opts,
    :payload_store,
    :executors,
    :broker,
    :constitution,
    :genesis,
    :principals,
    :host_profile,
    :surface,
    :root_mandates,
    :genesis_verifier,
    :legacy_import
  ]
  @authentication_options [:ingress_opts, :sequencer_opts]
  @observation_options [:ingress_opts, :sequencer_opts]
  @derivation_options [:sequencer_opts]
  @presentation_options [:sequencer_opts]
  @outcome_options [:sequencer_opts]
  @late_observation_options [:observer_opts, :sequencer_opts]
  @turn_options [:ingress_opts, :mind_opts, :sequencer_opts, :context_evidence_refs]
  @execution_options [:sequencer_opts]
  @scope_opening_fields [
    :parent_ref,
    :kind,
    :promise_condition,
    :accountable_ref,
    :disposition_authority_refs,
    :opened_at,
    :due_at
  ]
  @presentation_show_fields [
    :identity_key,
    :requested_mandate_ref,
    :executor_ref,
    :executor_contract_ref,
    :accountable_ref,
    :subject_refs,
    :evidence_refs,
    :observation_window_ms
  ]

  @type domain_ref :: String.t()
  @type domain_input :: Domain.t() | domain_ref()
  @type domain_head :: %{
          required(:domain_ref) => domain_ref(),
          required(:revision) => non_neg_integer(),
          required(:head_digest) => String.t()
        }

  @doc "Returns the governed runtime API version."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Starts one locally supervised Domain using an explicit ledger Store.

  This is host wiring, not a governance mutation. The Store is never inferred
  or created implicitly. Bootstrap records, clock, identifier source,
  constitution and Grant secret are forwarded as Domain options and validated
  by the Sequencer. `:ingress` is mandatory and fixes the only adapter reference
  accepted in authenticated contexts for that running Domain. `:domain_ref`,
  `:store`, `:name` and `:registry` are reserved so callers cannot silently
  replace the identity or uniqueness boundary.

  All Domains run below the application Domain supervisor coupled to the
  unique Domain registry.
  """
  @spec start_domain(domain_ref(), Store.config(), keyword()) ::
          {:ok, Domain.t()} | {:error, term()}
  def start_domain(domain_ref, store, opts \\ [])

  def start_domain(domain_ref, store, opts)
      when is_binary(domain_ref) and domain_ref != "" and is_list(opts) do
    with :ok <- validate_keyword(opts, :domain_options),
         :ok <- validate_known_options(opts, @domain_options, :domain),
         :ok <- reject_reserved_domain_options(opts),
         {:ok, normalized_store} <- Store.normalize(store),
         domain_opts <- domain_options(domain_ref, normalized_store, opts) do
      start_domain_child(domain_ref, domain_opts)
    end
  end

  def start_domain(_domain_ref, _store, _opts), do: {:error, :invalid_domain_start}

  @doc "Returns the locally supervised Domain handle for `domain_ref`."
  @spec lookup_domain(domain_ref()) :: {:ok, Domain.t()} | {:error, term()}
  def lookup_domain(domain_ref) when is_binary(domain_ref) and domain_ref != "" do
    case registered_domain(domain_ref) do
      {:ok, pid} -> {:ok, Domain.handle(pid, domain_ref)}
      {:error, _reason} = error -> error
    end
  end

  def lookup_domain(_domain_ref), do: {:error, :invalid_domain_ref}

  @doc "Authenticates through the Domain's fixed ingress and returns a generation-bound context."
  @spec authenticate(domain_input(), String.t(), term(), keyword()) ::
          {:ok, SubmissionContext.t()} | {:error, term()}
  def authenticate(domain_input, scope_ref, input, opts \\ [])

  def authenticate(domain_input, scope_ref, input, opts) when is_list(opts) do
    with :ok <- validate_keyword(opts, :authentication_options),
         :ok <- validate_known_options(opts, @authentication_options, :authentication),
         :ok <- reject_ingress_override(opts),
         {:ok, domain} <- resolve_domain(domain_input),
         {:ok, ingress_opts} <- nested_keyword(opts, :ingress_opts),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts),
         {:ok, context} <-
           sequencer_result(
             fn ->
               Sequencer.authenticate(
                 domain.server,
                 scope_ref,
                 input,
                 Keyword.put(sequencer_opts, :ingress_opts, ingress_opts)
               )
             end,
             :ingress_authentication_failed
           ) do
      {:ok, context}
    end
  end

  def authenticate(_domain_input, _scope_ref, _input, _opts),
    do: {:error, :invalid_authentication}

  @doc """
  Durably opens a Scope from an authenticated SubmissionContext.

  The context must already have been produced by a trusted ingress adapter. It
  is revalidated, bound to the exact Domain and scope reference, fenced by the
  currently running host generation and recorded before the handle is returned.
  `opening_attrs` contains only Scope semantics; identity and authentication
  fields are forced from the context. `:opened_at` is required so exact retries
  remain byte-identical. Opening a Scope creates no authority or Meter balance.
  """
  @spec open_scope(domain_input(), SubmissionContext.t(), map() | keyword() | Opening.t()) ::
          {:ok, Scope.t()} | {:error, term()}
  def open_scope(domain_input, context, opening_attrs \\ [])

  def open_scope(domain_input, %SubmissionContext{} = context, opening_attrs) do
    with {:ok, domain} <- resolve_domain(domain_input),
         {:ok, context} <- SubmissionContext.new(context),
         :ok <- context_domain_binding(context, domain),
         :ok <- current_generation(context, domain),
         {:ok, opening} <- scope_opening(context, opening_attrs),
         {:ok, %Opening{} = durable} <-
           sequencer_result(
             fn -> Sequencer.open_scope(domain.server, context, opening) end,
             :scope_opening_failed
           ),
         true <- Opening.canonical(durable) == Opening.canonical(opening),
         {:ok, scope} <- Scope.new(domain, context.scope_ref, context) do
      {:ok, scope}
    else
      false -> {:error, :scope_opening_recovery_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def open_scope(_domain_input, _context, _opening_attrs),
    do: {:error, :authenticated_context_required}

  @doc """
  Opens a finite Work or Vigil Scope through normal governed admission.

  `parent_scope` supplies the authenticated proposing context. `child_context`
  must be a current context produced by the same Domain ingress for the new
  Scope reference. Its seal is verified separately by the Sequencer and every
  durable identity field is forced into the Candidate consequence. The Scope
  handle is returned only after the Decision, Act and Opening are durably
  recovered from one atomic batch.
  """
  @spec open_scope(
          Scope.t(),
          SubmissionContext.t(),
          map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, Scope.t()} | {:error, term()}
  def open_scope(parent_scope, child_context, opening_attrs, candidate_attrs, opts \\ [])

  def open_scope(
        %Scope{} = parent_scope,
        %SubmissionContext{} = child_context,
        opening_attrs,
        candidate_attrs,
        opts
      )
      when is_list(opts) do
    with :ok <- validate_keyword(opts, :governed_scope_opening_options),
         [] <- Keyword.keys(opts) -- [:sequencer_opts],
         {:ok, parent_scope} <- refresh_scope(parent_scope),
         {:ok, child_context} <- SubmissionContext.new(child_context),
         :ok <- context_domain_binding(child_context, parent_scope.domain),
         :ok <- current_generation(child_context, parent_scope.domain),
         {:ok, candidate} <-
           Governance.open_scope(
             parent_scope,
             child_context,
             opening_attrs,
             candidate_attrs
           ),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts),
         {:ok, admission} <-
           sequencer_result(
             fn ->
               Sequencer.submit_scope_opening(
                 parent_scope.domain.server,
                 parent_scope.context,
                 child_context,
                 candidate,
                 sequencer_opts
               )
             end,
             :governed_scope_opening_failed
           ),
         {:ok, %Opening{} = _opening} <- admitted_governed_scope(admission),
         {:ok, scope} <- Scope.new(parent_scope.domain, child_context.scope_ref, child_context) do
      {:ok, scope}
    else
      [_unknown | _rest] = unknown ->
        {:error, {:unknown_governed_scope_opening_options, unknown}}

      {:error, _reason} = error ->
        error
    end
  end

  def open_scope(_parent_scope, _child_context, _opening_attrs, _candidate_attrs, _opts),
    do: {:error, :invalid_governed_scope_opening}

  @doc "Rebinds a current authenticated context to an existing Scope after restart."
  @spec resume_scope(domain_input(), SubmissionContext.t()) ::
          {:ok, Scope.t()} | {:error, term()}
  def resume_scope(domain_input, %SubmissionContext{} = context) do
    with {:ok, domain} <- resolve_domain(domain_input),
         {:ok, context} <- SubmissionContext.new(context),
         :ok <- context_domain_binding(context, domain),
         :ok <- current_generation(context, domain),
         {:ok, %Opening{}} <-
           sequencer_result(
             fn -> Sequencer.resume_scope(domain.server, context) end,
             :scope_resume_failed
           ) do
      Scope.new(domain, context.scope_ref, context)
    end
  end

  def resume_scope(_domain_input, _context), do: {:error, :authenticated_context_required}

  @doc """
  Records input through the Domain's declared ingress without invoking a mind.

  `:ingress_opts` are passed to that adapter. Supplying an `:ingress` override
  is rejected: call options cannot replace the Domain trust boundary.
  """
  @spec observe(Scope.t(), term(), keyword()) ::
          {:ok, [Evidence.t()]} | {:error, term()}
  def observe(scope, input, opts \\ [])

  def observe(%Scope{} = scope, input, opts) when is_list(opts) do
    with :ok <- validate_keyword(opts, :observation_options),
         :ok <- validate_known_options(opts, @observation_options, :observation),
         :ok <- reject_ingress_override(opts),
         {:ok, scope} <- refresh_scope(scope),
         {:ok, ingress_opts} <- nested_keyword(opts, :ingress_opts),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts),
         {:ok, evidence} <-
           sequencer_result(
             fn ->
               Sequencer.observe(
                 scope.domain.server,
                 scope.context,
                 input,
                 Keyword.put(sequencer_opts, :ingress_opts, ingress_opts)
               )
             end,
             :ingress_observation_failed
           ) do
      {:ok, evidence}
    end
  end

  def observe(_scope, _input, _opts), do: {:error, :invalid_observation}

  @doc "Records derived/generated Evidence bound to one exact deliberation Turn."
  @spec record_derivation(
          Scope.t(),
          Turn.t(),
          Evidence.t() | map() | keyword(),
          keyword()
        ) ::
          {:ok, Evidence.t()} | {:error, term()}
  def record_derivation(scope, turn, evidence, opts \\ [])

  def record_derivation(%Scope{} = scope, %Turn{} = turn, evidence, opts) when is_list(opts) do
    with :ok <- validate_keyword(opts, :derivation_options),
         :ok <- validate_known_options(opts, @derivation_options, :derivation),
         {:ok, scope} <- refresh_scope(scope),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts),
         {:ok, %Evidence{} = durable} <-
           sequencer_result(
             fn ->
               Sequencer.record_derivation(
                 scope.domain.server,
                 scope.context,
                 turn,
                 evidence,
                 sequencer_opts
               )
             end,
             :evidence_derivation_commit_failed
           ) do
      {:ok, durable}
    end
  end

  def record_derivation(_scope, _turn, _evidence, _opts),
    do: {:error, :invalid_evidence_derivation}

  @doc "Stores immutable consent material; this operation does not itself display it."
  @spec prepare_presentation(Scope.t(), Presentation.t() | map() | keyword(), keyword()) ::
          {:ok, Presentation.t()} | {:error, term()}
  def prepare_presentation(scope, presentation, opts \\ [])

  def prepare_presentation(%Scope{} = scope, presentation, opts) when is_list(opts) do
    with :ok <- validate_keyword(opts, :presentation_options),
         :ok <- validate_known_options(opts, @presentation_options, :presentation),
         {:ok, scope} <- refresh_scope(scope),
         {:ok, presentation} <- Presentation.new(presentation),
         :ok <- presentation_scope(presentation, scope.ref),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts),
         {:ok, %Presentation{} = durable} <-
           sequencer_result(
             fn ->
               Sequencer.record_presentation(
                 scope.domain.server,
                 scope.context,
                 presentation,
                 sequencer_opts
               )
             end,
             :presentation_commit_failed
           ),
         true <- Presentation.canonical(durable) == Presentation.canonical(presentation) do
      {:ok, durable}
    else
      false -> {:error, :presentation_recovery_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def prepare_presentation(_scope, _presentation, _opts),
    do: {:error, :invalid_presentation}

  @doc "Shows prepared consent material through a normal executor-mediated Act."
  @spec show_presentation(
          Scope.t(),
          String.t(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def show_presentation(scope, presentation_ref, candidate_attrs, opts \\ [])

  def show_presentation(
        %Scope{} = scope,
        presentation_ref,
        candidate_attrs,
        opts
      )
      when is_binary(presentation_ref) and presentation_ref != "" and is_list(opts) do
    with {:ok, scope} <- refresh_scope(scope),
         {:ok, projection} <- fetch_projection(scope.domain),
         {:ok, %Presentation{} = presentation} <-
           fetch_presentation(projection, presentation_ref),
         :ok <- presentation_scope(presentation, scope.ref),
         {:ok, candidate} <-
           presentation_show_candidate(scope, presentation, candidate_attrs) do
      propose(scope, candidate, opts)
    else
      {:error, _reason} = error -> error
    end
  end

  def show_presentation(_scope, _presentation_ref, _candidate_attrs, _opts),
    do: {:error, :invalid_presentation_show}

  @doc "Records a late or independently obtained world Outcome for an Act in this Scope."
  @spec record_outcome(Scope.t(), Outcome.t() | map() | keyword(), keyword()) ::
          {:ok, Outcome.t()} | {:error, term()}
  def record_outcome(scope, outcome, opts \\ [])

  def record_outcome(%Scope{} = scope, outcome, opts) when is_list(opts) do
    with :ok <- validate_keyword(opts, :outcome_options),
         :ok <- validate_known_options(opts, @outcome_options, :outcome),
         {:ok, scope} <- refresh_scope(scope),
         {:ok, outcome} <- Outcome.new(outcome),
         :ok <- late_outcome_has_evidence(outcome),
         {:ok, projection} <- fetch_projection(scope.domain),
         :ok <- outcome_belongs_to_scope(projection, outcome, scope.ref),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts),
         {:ok, %Outcome{} = durable} <-
           sequencer_result(
             fn -> Sequencer.record_outcome(scope.domain.server, outcome, sequencer_opts) end,
             :outcome_commit_failed
           ),
         true <- Outcome.canonical(durable) == Outcome.canonical(outcome) do
      {:ok, durable}
    else
      false -> {:error, :outcome_recovery_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def record_outcome(_scope, _outcome, _opts), do: {:error, :invalid_outcome}

  @doc """
  Obtains and records a late world observation through the Domain's fixed observer.

  The observer may verify a receipt or query the external system, but it receives
  no execution capability. A request cannot replace the configured adapter.
  """
  @spec record_late_observation(Scope.t(), String.t(), term(), keyword()) ::
          {:ok, %{evidence: [Evidence.t()], outcome: Outcome.t()}} | {:error, term()}
  def record_late_observation(scope, attempt_ref, input, opts \\ [])

  def record_late_observation(%Scope{} = scope, attempt_ref, input, opts)
      when is_binary(attempt_ref) and attempt_ref != "" and is_list(opts) do
    with :ok <- validate_keyword(opts, :late_observation_options),
         :ok <- validate_known_options(opts, @late_observation_options, :late_observation),
         {:ok, scope} <- refresh_scope(scope),
         {:ok, observer_opts} <- nested_keyword(opts, :observer_opts),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts),
         {:ok, projection} <- fetch_projection(scope.domain),
         {:ok, act, attempt} <- late_observation_cause(projection, scope.ref, attempt_ref),
         {:ok, observer} <-
           sequencer_result(
             fn -> Sequencer.late_observer(scope.domain.server) end,
             :late_observer_unavailable
           ),
         {:ok, reported_status, corrected_ref, metadata} <-
           invoke_late_observer(observer, act, attempt, input, observer_opts),
         {:ok, observed_at} <-
           sequencer_result(
             fn -> Sequencer.trusted_time(scope.domain.server, sequencer_opts) end,
             :late_observation_time_unavailable
           ),
         {:ok, observation} <-
           Runner.normalize_late_observation(
             reported_status,
             metadata,
             act,
             attempt,
             observed_at
           ),
         :ok <-
           validate_late_correction(projection, observation, act, attempt, corrected_ref),
         {:ok, recorded_evidence} <-
           record_late_evidence(
             scope.domain.server,
             act,
             attempt,
             observation.evidence,
             sequencer_opts
           ),
         {:ok, outcome} <- late_outcome(observation, act, attempt, corrected_ref),
         {:ok, durable} <-
           sequencer_result(
             fn -> Sequencer.record_outcome(scope.domain.server, outcome, sequencer_opts) end,
             :late_outcome_commit_failed
           ),
         true <- Outcome.canonical(durable) == Outcome.canonical(outcome) do
      {:ok, %{evidence: recorded_evidence, outcome: durable}}
    else
      false -> {:error, :late_outcome_recovery_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def record_late_observation(_scope, _attempt_ref, _input, _opts),
    do: {:error, :invalid_late_observation}

  @doc """
  Turns authenticated input into durable Evidence and capability-free proposals.

  The mind fixed in Domain configuration receives each Turn. The Domain's
  declared ingress first observes the raw
  input under the Scope's trusted `SubmissionContext`; Spectre verifies the
  resulting Evidence binding and commits it before invoking the mind. An
  `:ingress` option is rejected, while `:ingress_opts` are passed to the fixed
  adapter. The mind receives no executor or authority view and returns only
    Candidates. Callers may submit those Candidates separately with `propose/3`.

  Optional `:context_evidence_refs` select additional already-durable Evidence
  for deliberation. Labels on the Turn are the conservative union of all
  selected Evidence.
  """
  @spec turn(Scope.t(), term(), keyword()) ::
          {:ok, %{turn: Turn.t(), evidence: [Evidence.t()], candidates: [Candidate.t()]}}
          | {:error, term()}
  def turn(scope, input, opts \\ [])

  def turn(%Scope{} = scope, input, opts) when is_list(opts) do
    with :ok <- validate_keyword(opts, :turn_options),
         :ok <- validate_known_options(opts, @turn_options, :turn),
         :ok <- reject_ingress_override(opts),
         {:ok, scope} <- refresh_scope(scope),
         {:ok, mind} <-
           sequencer_result(
             fn -> Sequencer.mind(scope.domain.server) end,
             :mind_unavailable
           ),
         {:ok, ingress_opts} <- nested_keyword(opts, :ingress_opts),
         {:ok, mind_opts} <- nested_keyword(opts, :mind_opts),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts),
         {:ok, context_refs} <- context_evidence_refs(opts),
         {:ok, %Turn{} = turn} <-
           sequencer_result(
             fn ->
               Sequencer.begin_turn(
                 scope.domain.server,
                 scope.context,
                 input,
                 context_refs,
                 Keyword.put(sequencer_opts, :ingress_opts, ingress_opts)
               )
             end,
             :turn_open_failed
           ),
         {:ok, candidates} <- Mind.deliberate(mind, turn, mind_opts) do
      {:ok, %{turn: turn, evidence: turn.evidence, candidates: candidates}}
    end
  end

  def turn(_scope, _input, _opts), do: {:error, :invalid_turn}

  @doc """
  Proposes a Candidate and completes its permitted execution path.

  The Scope is revalidated against the live Domain and current host generation
  on every call. Admission is durably sequenced before `Spectre.Attempt.Runner`
  receives the internal response. Executor-mediated Acts are routed only to the
  executor and broker fixed in Domain configuration; proposal options cannot
  replace either implementation or their private options.

  The returned `Spectre.Proposal.Result` contains the primary durable result
  and, for an explicitly refused Candidate, either declared silence or the
  result of one fresh governed fallback Candidate. It never contains the
  internal Grant or checked-out capability, and fallbacks never recurse.
  """
  @spec propose(Scope.t(), Candidate.t() | map() | keyword(), keyword()) ::
          {:ok, ProposalResult.t()} | {:error, term()}
  def propose(scope, candidate, opts \\ [])

  def propose(%Scope{} = scope, candidate, opts) when is_list(opts) do
    with :ok <- validate_public_execution_options(opts),
         {:ok, scope} <- refresh_scope(scope),
         {:ok, candidate} <- Candidate.new(candidate),
         {:ok, primary} <- submit_and_run(scope, candidate, opts),
         {:ok, fallback} <- declared_fallback(scope, primary, opts) do
      {:ok, %ProposalResult{primary: primary, fallback: fallback}}
    end
  end

  def propose(_scope, _candidate, _opts), do: {:error, :invalid_proposal}

  @doc "Returns the read-only application projection for an authenticated Scope."
  @spec view(Scope.t()) :: {:ok, ScopeView.t()} | {:error, term()}
  def view(%Scope{} = scope) do
    with {:ok, scope} <- refresh_scope(scope),
         {:ok, projection} <- fetch_projection(scope.domain) do
      ScopeView.from_projection(projection, scope.ref)
    end
  end

  def view(_scope), do: {:error, :invalid_scope}

  @doc "Issues a subtractive child Mandate through a normal governance Act."
  @spec issue_mandate(
          Scope.t(),
          Spectre.Mandate.t() | map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def issue_mandate(scope, mandate, candidate_attrs, opts \\ []),
    do: delegate_mandate(scope, mandate, candidate_attrs, opts)

  @doc "Delegates a subtractive child Mandate through a normal governance Act."
  @spec delegate_mandate(
          Scope.t(),
          Spectre.Mandate.t() | map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def delegate_mandate(scope, mandate, candidate_attrs, opts \\ [])

  def delegate_mandate(%Scope{} = scope, mandate, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, candidate} <- Governance.delegate_mandate(scope, mandate, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def delegate_mandate(_scope, _mandate, _candidate_attrs, _opts),
    do: {:error, :invalid_mandate_delegation}

  @doc "Returns declared free child Meter balances through a governance Act."
  @spec devolve_mandate(Scope.t(), String.t(), map(), map() | keyword(), keyword()) ::
          {:ok, ProposalResult.t()} | {:error, term()}
  def devolve_mandate(scope, child_mandate_ref, amounts, candidate_attrs, opts \\ [])

  def devolve_mandate(%Scope{} = scope, child_ref, amounts, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, candidate} <-
           Governance.devolve_mandate(scope, child_ref, amounts, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def devolve_mandate(_scope, _child_ref, _amounts, _candidate_attrs, _opts),
    do: {:error, :invalid_mandate_devolution}

  @doc "Replaces a Mandate with an immutable, strictly narrower successor through a governance Act."
  @spec restrict_mandate(
          Scope.t(),
          String.t(),
          Spectre.Mandate.t() | map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def restrict_mandate(scope, predecessor_ref, successor, candidate_attrs, opts \\ [])

  def restrict_mandate(%Scope{} = scope, predecessor_ref, successor, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, candidate} <-
           Governance.restrict_mandate(scope, predecessor_ref, successor, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def restrict_mandate(_scope, _predecessor_ref, _successor, _candidate_attrs, _opts),
    do: {:error, :invalid_mandate_restriction}

  @doc "Immediately records a forward-only Mandate revocation through a governance Act."
  @spec revoke_mandate(
          Scope.t(),
          String.t(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def revoke_mandate(scope, mandate_ref, candidate_attrs, opts \\ [])

  def revoke_mandate(%Scope{} = scope, mandate_ref, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, scope} <- refresh_scope(scope),
         {:ok, projection} <- fetch_projection(scope.domain),
         {:ok, target} <- fetch_mandate(projection, mandate_ref),
         {:ok, candidate} <- Governance.revoke_mandate(scope, target, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def revoke_mandate(_scope, _mandate_ref, _candidate_attrs, _opts),
    do: {:error, :invalid_mandate_revocation}

  @doc "Disposes a Duty only through the independently authorized governance path."
  @spec dispose_duty(
          Scope.t(),
          Spectre.Duty.Disposition.t() | map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def dispose_duty(scope, disposition, candidate_attrs, opts \\ [])

  def dispose_duty(%Scope{} = scope, disposition, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, candidate} <- Governance.dispose_duty(scope, disposition, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def dispose_duty(_scope, _disposition, _candidate_attrs, _opts),
    do: {:error, :invalid_duty_disposition}

  @doc "Revises the governed Surface through a normal governance Act."
  @spec revise_surface(
          Scope.t(),
          String.t(),
          Surface.t() | map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def revise_surface(scope, previous_ref, surface, candidate_attrs, opts \\ [])

  def revise_surface(%Scope{} = scope, previous_ref, surface, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, candidate} <-
           Governance.revise_surface(scope, previous_ref, surface, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def revise_surface(_scope, _previous_ref, _surface, _candidate_attrs, _opts),
    do: {:error, :invalid_surface_revision}

  @doc "Revises the attested host profile through a normal governance Act."
  @spec revise_host_profile(
          Scope.t(),
          String.t(),
          Spectre.HostProfile.t() | map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def revise_host_profile(scope, previous_ref, profile, candidate_attrs, opts \\ [])

  def revise_host_profile(%Scope{} = scope, previous_ref, profile, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, candidate} <-
           Governance.revise_host_profile(scope, previous_ref, profile, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def revise_host_profile(_scope, _previous_ref, _profile, _candidate_attrs, _opts),
    do: {:error, :invalid_host_profile_revision}

  @doc "Revises a declarative Definition through a normal governance Act."
  @spec revise_definition(
          Scope.t(),
          Spectre.Definition.t() | map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def revise_definition(scope, definition, candidate_attrs, opts \\ [])

  def revise_definition(%Scope{} = scope, definition, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, candidate} <- Governance.revise_definition(scope, definition, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def revise_definition(_scope, _definition, _candidate_attrs, _opts),
    do: {:error, :invalid_definition_revision}

  @doc "Removes explicitly authorized labels by producing new immutable Evidence."
  @spec declassify_evidence(
          Scope.t(),
          Evidence.t() | map() | keyword(),
          [term()],
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def declassify_evidence(scope, evidence, removed_labels, candidate_attrs, opts \\ [])

  def declassify_evidence(
        %Scope{} = scope,
        evidence,
        removed_labels,
        candidate_attrs,
        opts
      )
      when is_list(removed_labels) and is_list(opts) do
    with {:ok, candidate} <-
           Governance.declassify_evidence(scope, evidence, removed_labels, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def declassify_evidence(_scope, _evidence, _removed_labels, _candidate_attrs, _opts),
    do: {:error, :invalid_evidence_declassification}

  @doc "Requests executor-mediated erasure through a normal governance Act."
  @spec request_erasure(
          Scope.t(),
          map() | keyword(),
          map() | keyword(),
          keyword()
        ) :: {:ok, ProposalResult.t()} | {:error, term()}
  def request_erasure(scope, request_attrs, candidate_attrs, opts \\ [])

  def request_erasure(%Scope{} = scope, request_attrs, candidate_attrs, opts)
      when is_list(opts) do
    with {:ok, scope} <- refresh_scope(scope),
         {:ok, projection} <- fetch_projection(scope.domain),
         {:ok, candidate} <-
           Governance.request_erasure(scope, projection, request_attrs, candidate_attrs),
         do: propose(scope, candidate, opts)
  end

  def request_erasure(_scope, _request, _candidate_attrs, _opts),
    do: {:error, :invalid_erasure_request}

  @doc "Returns the verified ledger head represented by the live Domain projection."
  @spec head(domain_input()) :: {:ok, domain_head()} | {:error, term()}
  def head(domain_input) do
    with {:ok, projection} <- fetch_projection(domain_input) do
      {:ok,
       %{
         domain_ref: projection.domain_ref,
         revision: projection.revision,
         head_digest: projection.head_digest
       }}
    end
  end

  @doc "Returns immutable Acts visible through an authenticated Scope."
  @spec acts(Scope.t(), keyword()) :: {:ok, [Spectre.Act.t()]} | {:error, term()}
  def acts(scope, opts \\ [])

  def acts(%Scope{} = scope, opts) when is_list(opts) do
    with :ok <- empty_query_options(opts, :acts),
         {:ok, %ScopeView{} = view} <- view(scope) do
      {:ok, view.acts}
    end
  end

  def acts(_scope, _opts), do: {:error, :authenticated_scope_required}

  @doc "Returns immutable Duties visible through an authenticated Scope."
  @spec duties(Scope.t(), keyword()) :: {:ok, [Spectre.Duty.t()]} | {:error, term()}
  def duties(scope, opts \\ [])

  def duties(%Scope{} = scope, opts) when is_list(opts) do
    with {:ok, status} <- duty_status(opts),
         {:ok, %ScopeView{} = view} <- view(scope) do
      {:ok, filter_duty_status(view.duties, status)}
    end
  end

  def duties(_scope, _opts), do: {:error, :authenticated_scope_required}

  @doc "Returns governed Evidence declassifications visible through an authenticated Scope."
  @spec declassifications(Scope.t()) ::
          {:ok, [Spectre.Declassification.t()]} | {:error, term()}
  def declassifications(%Scope{} = scope) do
    with {:ok, %ScopeView{} = view} <- view(scope), do: {:ok, view.declassifications}
  end

  def declassifications(_scope), do: {:error, :authenticated_scope_required}

  @doc "Returns causal erasure requests visible through an authenticated Scope."
  @spec erasures(Scope.t()) ::
          {:ok, [Spectre.Erasure.t()]} | {:error, term()}
  def erasures(%Scope{} = scope) do
    with {:ok, %ScopeView{} = view} <- view(scope), do: {:ok, view.erasures}
  end

  def erasures(_scope), do: {:error, :authenticated_scope_required}

  defp scope_opening(context, %Opening{} = opening) do
    with {:ok, opening} <- Opening.new(opening),
         :ok <- direct_scope_kind(opening.kind),
         :ok <- opening_context_binding(opening, context) do
      {:ok, opening}
    end
  end

  defp scope_opening(context, attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @scope_opening_fields, :scope_opening),
         :ok <- direct_scope_kind(Map.get(attrs, :kind, :session)),
         {:ok, opened_at} <- required_integer(attrs, :opened_at) do
      attrs
      |> Map.merge(%{
        ref: context.scope_ref,
        domain_ref: context.domain_ref,
        opened_by_ref: context.authenticated_principal_ref,
        submission_context_ref: context.ref,
        authentication_ref: context.authentication_ref,
        ingress_ref: context.ingress_ref,
        channel_ref: context.channel_ref,
        session_ref: context.session_ref,
        host_generation: context.host_generation,
        opened_at: opened_at
      })
      |> Opening.new()
    end
  end

  defp direct_scope_kind(kind) when kind in [:session, :child], do: :ok

  defp direct_scope_kind(kind) when kind in [:work, :vigil],
    do: {:error, {:governed_scope_opening_required, kind}}

  defp direct_scope_kind(kind), do: {:error, {:invalid_scope_kind, kind}}

  defp admitted_governed_scope(%{
         decision: %{outcome: :admitted},
         act: %Spectre.Act{},
         grant: nil,
         opening: %Opening{} = opening
       }),
       do: {:ok, opening}

  defp admitted_governed_scope(%{decision: %{outcome: outcome, ref: decision_ref}})
       when outcome in [:refused, :undecidable, :unknown_class],
       do: {:error, {:governed_scope_opening_not_admitted, outcome, decision_ref}}

  defp admitted_governed_scope(_admission),
    do: {:error, :invalid_governed_scope_opening_admission}

  defp opening_context_binding(opening, context) do
    fields = [
      {:ref, context.scope_ref},
      {:domain_ref, context.domain_ref},
      {:opened_by_ref, context.authenticated_principal_ref},
      {:submission_context_ref, context.ref},
      {:authentication_ref, context.authentication_ref},
      {:ingress_ref, context.ingress_ref},
      {:channel_ref, context.channel_ref},
      {:session_ref, context.session_ref},
      {:host_generation, context.host_generation}
    ]

    case Enum.find(fields, fn {field, expected} -> Map.fetch!(opening, field) != expected end) do
      nil -> :ok
      {field, _expected} -> {:error, {:scope_opening_context_mismatch, field}}
    end
  end

  defp presentation_scope(%Presentation{scope_ref: scope_ref}, scope_ref), do: :ok
  defp presentation_scope(%Presentation{}, _scope_ref), do: {:error, :presentation_scope_mismatch}

  defp fetch_presentation(%Projection{} = projection, presentation_ref) do
    case Map.fetch(projection.presentations, presentation_ref) do
      {:ok, %Presentation{} = presentation} -> {:ok, presentation}
      {:ok, _invalid} -> {:error, {:invalid_presentation_record, presentation_ref}}
      :error -> {:error, {:presentation_not_found, presentation_ref}}
    end
  end

  defp fetch_mandate(%Projection{} = projection, mandate_ref)
       when is_binary(mandate_ref) and mandate_ref != "" do
    case Map.fetch(projection.mandates, mandate_ref) do
      {:ok, %Mandate{} = mandate} -> {:ok, mandate}
      {:ok, _invalid} -> {:error, {:invalid_mandate_record, mandate_ref}}
      :error -> {:error, {:mandate_not_found, mandate_ref}}
    end
  end

  defp fetch_mandate(%Projection{}, _mandate_ref), do: {:error, :invalid_mandate_ref}

  defp presentation_show_candidate(scope, presentation, candidate_attrs) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(
             candidate_attrs,
             @presentation_show_fields,
             :presentation_show_candidate
           ),
         {:ok, identity_key} <- show_required_ref(attrs, :identity_key),
         {:ok, mandate_ref} <- show_required_ref(attrs, :requested_mandate_ref),
         {:ok, accountable_ref} <- show_required_ref(attrs, :accountable_ref),
         {:ok, executor_ref} <- show_required_ref(attrs, :executor_ref),
         {:ok, executor_contract_ref} <- show_required_ref(attrs, :executor_contract_ref) do
      Candidate.new(%{
        identity_key: identity_key,
        class: Presentation.show_class(),
        consequence: Presentation.show_consequence(presentation),
        row: Presentation.show_row(),
        requested_mandate_ref: mandate_ref,
        proposer_ref: scope.context.authenticated_principal_ref,
        executor_ref: executor_ref,
        accountable_ref: accountable_ref,
        scope_ref: scope.ref,
        subject_refs: Map.get(attrs, :subject_refs, []),
        target_refs: presentation.recipient_refs,
        purpose_ref: presentation.purpose_ref,
        purpose_params: presentation.purpose_params,
        consent: nil,
        evidence_refs:
          Map.get(attrs, :evidence_refs, []) ++ presentation.disclosure.source_evidence_refs,
        disclosure: presentation.disclosure,
        presentation_ref: nil,
        meter_requests: %{},
        executor_contract_ref: executor_contract_ref,
        observation_window_ms: Map.get(attrs, :observation_window_ms, 0)
      })
    end
  end

  defp show_required_ref(attrs, field) do
    case Map.get(attrs, field) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing_presentation_show_field, field}}
    end
  end

  defp submit_and_run(scope, candidate, opts) do
    with {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         {:ok, admission} <-
           sequencer_result(
             fn ->
               Sequencer.submit(
                 scope.domain.server,
                 scope.context,
                 candidate,
                 sequencer_opts
               )
             end,
             :domain_submission_failed
           ) do
      run_admission(scope.domain.server, {:ok, admission}, opts)
    end
  end

  defp declared_fallback(
         _scope,
         %Runner.Result{decision: %{outcome: :admitted}},
         _opts
       ),
       do: {:ok, :not_applicable}

  defp declared_fallback(
         _scope,
         %Runner.Result{decision: %{outcome: :undecidable}},
         _opts
       ),
       do: {:ok, :not_applicable}

  defp declared_fallback(
         _scope,
         %Runner.Result{decision: %{outcome: :unknown_class}},
         _opts
       ),
       do: {:ok, :silence}

  defp declared_fallback(
         scope,
         %Runner.Result{decision: %{outcome: :refused} = decision},
         opts
       ) do
    with {:ok, projection} <- fetch_projection(scope.domain),
         {:ok, surface} <- historical_surface(projection, decision.surface_revision),
         {:ok, policy} <- Surface.fallback(surface, decision.candidate_class),
         {:ok, fallback} <- Fallback.materialize(policy, decision, scope.context) do
      execute_fallback(scope, fallback, opts)
    end
  end

  defp declared_fallback(_scope, %Runner.Result{}, _opts),
    do: {:error, :invalid_primary_decision_outcome}

  defp execute_fallback(_scope, :silence, _opts), do: {:ok, :silence}

  defp execute_fallback(scope, {mode, candidate}, opts)
       when mode in [:candidate_template, :governed_handoff] do
    with {:ok, result} <- submit_and_run(scope, candidate, opts) do
      {:ok, %{mode: mode, result: result}}
    end
  end

  defp historical_surface(projection, revision) do
    matches =
      projection.surfaces
      |> Map.values()
      |> Enum.filter(&(&1.revision == revision))

    case matches do
      [surface] -> {:ok, surface}
      [] -> {:error, {:historical_surface_not_found, revision}}
      _many -> {:error, {:ambiguous_surface_revision, revision}}
    end
  end

  defp outcome_belongs_to_scope(projection, outcome, scope_ref) do
    case Map.fetch(projection.acts, outcome.act_ref) do
      {:ok, %{scope_ref: ^scope_ref}} -> :ok
      {:ok, _act} -> {:error, :outcome_scope_mismatch}
      :error -> {:error, {:outcome_act_not_found, outcome.act_ref}}
    end
  end

  defp late_outcome_has_evidence(%Outcome{status: :ambiguous}),
    do: {:error, :public_ambiguous_outcome_forbidden}

  defp late_outcome_has_evidence(%Outcome{evidence_refs: [_first | _rest]}), do: :ok
  defp late_outcome_has_evidence(%Outcome{}), do: {:error, :late_outcome_evidence_required}

  defp late_observation_cause(projection, scope_ref, attempt_ref) do
    with {:ok, attempt} <- Map.fetch(projection.attempts, attempt_ref),
         {:ok, act} <- Map.fetch(projection.acts, attempt.act_ref),
         true <- act.scope_ref == scope_ref,
         true <- attempt.executor_ref == act.executor_ref,
         true <- attempt.material_digest == act.material_digest do
      {:ok, act, attempt}
    else
      :error -> {:error, {:late_observation_attempt_not_found, attempt_ref}}
      false -> {:error, :late_observation_cause_mismatch}
    end
  end

  defp invoke_late_observer(observer, act, attempt, input, opts) do
    case safe_call(
           fn -> observer.observe(act, attempt, input, opts) end,
           :late_observation_unavailable
         ) do
      {:ok, {:ok, status, corrected_ref, metadata}}
      when status in [:succeeded, :failed, :definitive_no_effect, :ambiguous] and
             (is_nil(corrected_ref) or is_binary(corrected_ref)) and is_map(metadata) ->
        {:ok, status, corrected_ref, metadata}

      {:ok, {:error, _reason}} ->
        {:error, :late_observation_unavailable}

      {:ok, _invalid} ->
        {:error, :invalid_late_observer_response}

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_late_correction(_projection, _observation, _act, _attempt, nil), do: :ok

  defp validate_late_correction(projection, observation, act, attempt, corrected_ref) do
    with :ok <- Portable.validate_ref(corrected_ref, :contradicts_outcome_ref),
         true <- observation.status in [:succeeded, :failed],
         {:ok, corrected} <- Map.fetch(projection.outcomes, corrected_ref),
         true <- corrected.status == :definitive_no_effect,
         true <- corrected.act_ref == act.ref and corrected.attempt_ref == attempt.ref do
      :ok
    else
      :error -> {:error, {:corrected_outcome_not_found, corrected_ref}}
      false -> {:error, :invalid_late_outcome_correction}
      {:error, _reason} = error -> error
    end
  end

  defp record_late_evidence(_sequencer, _act, _attempt, [], _opts), do: {:ok, []}

  defp record_late_evidence(sequencer, act, attempt, evidence, opts) do
    with {:ok, recorded} <-
           sequencer_result(
             fn ->
               Sequencer.record_executor_evidence(
                 sequencer,
                 act.ref,
                 attempt.ref,
                 evidence,
                 opts
               )
             end,
             :late_evidence_commit_failed
           ),
         true <- evidence_digests(recorded) == evidence_digests(evidence) do
      {:ok, recorded}
    else
      false -> {:error, :late_evidence_recovery_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp late_outcome(observation, act, attempt, corrected_ref) do
    Outcome.new(%{
      act_ref: act.ref,
      attempt_ref: attempt.ref,
      status: observation.status,
      evidence_refs: Enum.map(observation.outcome_evidence, & &1.ref),
      observed_at: observation.observed_at,
      details_ref: observation.details_ref,
      contradicts_outcome_ref: corrected_ref
    })
  end

  defp evidence_digests(evidence) when is_list(evidence) do
    Map.new(evidence, fn item -> {item.ref, Evidence.digest(item)} end)
  end

  defp duty_status(opts) do
    with :ok <- validate_keyword(opts, :duty_query_options),
         [] <- Keyword.keys(opts) -- [:status] do
      case Keyword.get(opts, :status, :all) do
        status when status in [:all, :open, :disposed] -> {:ok, status}
        status -> {:error, {:invalid_duty_status_filter, status}}
      end
    else
      [_unknown | _rest] = unknown -> {:error, {:unknown_query_options, :duties, unknown}}
      {:error, _reason} = error -> error
    end
  end

  defp filter_duty_status(duties, :all), do: duties
  defp filter_duty_status(duties, status), do: Enum.filter(duties, &(&1.status == status))

  defp empty_query_options(opts, query) do
    with :ok <- validate_keyword(opts, :query_options) do
      if opts == [], do: :ok, else: {:error, {:unknown_query_options, query, Keyword.keys(opts)}}
    end
  end

  defp required_integer(attrs, field) do
    case Map.get(attrs, field) do
      value when is_integer(value) -> {:ok, value}
      _missing -> {:error, {:missing_scope_opening_field, field}}
    end
  end

  defp sequencer_result(function, failure) do
    case safe_call(function, failure) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, _reason} = error} -> error
      {:ok, _invalid} -> {:error, {:invalid_sequencer_response, failure}}
      {:error, _reason} = error -> error
    end
  end

  defp reject_ingress_override(opts) do
    if Keyword.has_key?(opts, :ingress),
      do: {:error, :domain_ingress_cannot_be_overridden},
      else: :ok
  end

  defp context_evidence_refs(opts) do
    opts
    |> Keyword.get(:context_evidence_refs, [])
    |> Portable.normalize_refs(:context_evidence_refs)
  end

  defp run_admission(sequencer, admission, opts) do
    case safe_call(
           fn -> Runner.run(sequencer, admission, opts) end,
           :execution_orchestration_failed
         ) do
      {:ok, result} -> result
      {:error, _reason} = error -> error
    end
  end

  defp refresh_scope(%Scope{} = scope) do
    with {:ok, domain} <- resolve_domain(scope.domain),
         {:ok, context} <- SubmissionContext.new(scope.context),
         :ok <- context_domain_binding(context, domain),
         :ok <- current_generation(context, domain),
         {:ok, %Opening{}} <-
           sequencer_result(
             fn -> Sequencer.resume_scope(domain.server, context) end,
             :scope_validation_failed
           ),
         {:ok, scope} <- Scope.new(domain, scope.ref, context) do
      {:ok, scope}
    end
  end

  defp context_domain_binding(%SubmissionContext{domain_ref: domain_ref}, %Domain{ref: domain_ref}),
       do: :ok

  defp context_domain_binding(_context, _domain), do: {:error, :context_domain_mismatch}

  defp current_generation(context, domain) do
    with {:ok, generation} <-
           safe_call(
             fn -> Sequencer.generation(domain.server) end,
             :domain_generation_unavailable
           ) do
      if is_integer(generation) and context.host_generation == generation,
        do: :ok,
        else: {:error, :stale_submission_context}
    end
  end

  defp fetch_projection(domain_input) do
    with {:ok, domain} <- resolve_domain(domain_input),
         {:ok, %Projection{} = projection} <-
           safe_call(
             fn -> Sequencer.projection(domain.server) end,
             :domain_projection_unavailable
           ),
         true <- projection.domain_ref == domain.ref do
      {:ok, projection}
    else
      false -> {:error, :domain_projection_mismatch}
      {:ok, _invalid} -> {:error, :invalid_domain_projection}
      {:error, _reason} = error -> error
    end
  end

  defp resolve_domain(%Domain{ref: domain_ref}), do: lookup_domain(domain_ref)
  defp resolve_domain(domain_ref) when is_binary(domain_ref), do: lookup_domain(domain_ref)
  defp resolve_domain(_domain), do: {:error, :invalid_domain}

  defp registered_domain(domain_ref) do
    with :ok <- registry_available(),
         {:ok, registered} <-
           safe_call(
             fn -> Domain.whereis(domain_ref, @registry) end,
             :domain_registry_unavailable
           ) do
      normalize_registration(registered)
    end
  end

  defp registry_available do
    if Process.whereis(@registry),
      do: :ok,
      else: {:error, :domain_registry_unavailable}
  end

  defp normalize_registration(pid) when is_pid(pid), do: {:ok, pid}
  defp normalize_registration(nil), do: {:error, :domain_not_found}
  defp normalize_registration(_invalid), do: {:error, :invalid_domain_registration}

  defp start_domain_child(domain_ref, domain_opts) do
    case safe_call(
           fn -> DomainSupervisor.start_domain(domain_opts) end,
           :domain_supervisor_unavailable
         ) do
      {:ok, {:ok, pid}} when is_pid(pid) -> {:ok, Domain.handle(pid, domain_ref)}
      {:ok, {:ok, pid, _info}} when is_pid(pid) -> {:ok, Domain.handle(pid, domain_ref)}
      {:ok, {:error, {:already_started, _pid}}} -> {:error, {:domain_already_started, domain_ref}}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, :ignore} -> {:error, :domain_start_ignored}
      {:ok, _invalid} -> {:error, :invalid_domain_start_response}
      {:error, _reason} = error -> error
    end
  end

  defp domain_options(domain_ref, store, opts) do
    opts
    |> Keyword.put(:domain_ref, domain_ref)
    |> Keyword.put(:store, store)
    |> Keyword.put(:registry, @registry)
  end

  defp reject_reserved_domain_options(opts) do
    case Enum.find(@reserved_domain_options, &Keyword.has_key?(opts, &1)) do
      nil -> :ok
      option -> {:error, {:reserved_domain_option, option}}
    end
  end

  defp validate_public_execution_options(opts) do
    with :ok <- validate_keyword(opts, :execution_options),
         :ok <- validate_known_options(opts, @execution_options, :execution),
         {:ok, sequencer_opts} <- nested_keyword(opts, :sequencer_opts),
         :ok <- validate_sequencer_options(sequencer_opts) do
      :ok
    end
  end

  defp nested_keyword(opts, key) do
    value = Keyword.get(opts, key, [])

    case validate_keyword(value, key) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp validate_sequencer_options(opts) do
    case Keyword.keys(opts) -- [:timeout] do
      [] -> :ok
      unknown -> {:error, {:unknown_sequencer_options, unknown}}
    end
  end

  defp validate_known_options(opts, allowed, context) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_options, context, unknown}}
    end
  end

  defp validate_keyword(value, field) when is_list(value) do
    if Keyword.keyword?(value),
      do: :ok,
      else: {:error, {:invalid_keyword_options, field}}
  end

  defp validate_keyword(_value, field), do: {:error, {:invalid_keyword_options, field}}

  defp safe_call(function, failure) do
    {:ok, function.()}
  rescue
    _exception -> {:error, failure}
  catch
    :exit, _reason -> {:error, failure}
    :throw, _reason -> {:error, failure}
  end
end
