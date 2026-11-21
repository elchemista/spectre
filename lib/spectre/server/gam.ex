defmodule Spectre.Server.GAM do
  @moduledoc """
  Internal protocol adapter between AgentServer and the GAM kernel.

  `Spectre.Server.GAM.Managed` constructs the authenticated Scope, operation
  bindings, ingress and journal automatically. Applications configure allowed
  operations through `Spectre.Server.start_link/1`; this adapter is not a
  replacement bridge option. External actors use `Spectre.GAM.submit/4` to enter
  the same runtime path.

  Candidate construction, presentations and confirmation remain distinct from
  admission. Show and effect both cross the kernel. The adapter never turns a
  classifier label into user approval. Required Evidence must come from the
  fixed authenticated ingress.

  Consent expiry defaults to five minutes; `:infinity` explicitly disables
  expiry. A fresh presentation has its own absolute deadline. Recovery preserves
  recorded facts and restores a wait suspended until a fresh presentation.
  The adapter rechecks expiry after interpretation and before submission;
  Evidence validity also fences admission across queued Domain commands.
  """
  alias Spectre.GAM
  alias Spectre.GAM.{Candidate, Presentation, Scope}
  alias Spectre.GAM.Domain.Sequencer
  alias Spectre.GAM.Facade.Proposal
  alias Spectre.GAM.Mind.Turn
  alias Spectre.Server.Store.Port, as: Store

  @doc "Whether the host explicitly connected Server lifecycle observations to its fixed ingress."
  def lifecycle_configured?(config) when is_list(config),
    do: Keyword.keyword?(config) and Keyword.get(config, :lifecycle) == true

  def lifecycle_configured?(_config), do: false

  @doc "Records a host lifecycle fact as scoped ingress Evidence, without proposing an Act."
  def record_lifecycle(event, context, opts) do
    with {:ok, config} <- config(opts),
         true <- lifecycle_configured?(config),
         {:ok, scope} <- scope(config, context) do
      Spectre.Server.GAM.Lifecycle.record(scope, event, observation_options(config))
    else
      false -> {:error, :lifecycle_not_configured}
      {:error, _} = error -> error
    end
  end

  def propose(operation, args, context, opts) do
    context = Map.put(context, :proposal_metadata, Keyword.get(opts, :proposal_metadata, %{}))

    with :ok <- skill_authority(context, operation),
         {:ok, config} <- config(opts),
         {:ok, binding} <- binding(config, operation),
         :ok <-
           Spectre.Server.Catalog.validate(operation, context.proposal_metadata, binding, context),
         {:ok, scope} <- scope(config, context),
         {:ok, invocation_refs} <-
           Spectre.Server.GAM.Invocation.record(
             scope,
             context,
             operation,
             observation_options(config)
           ),
         {:ok, turn} <-
           GAM.open_turn(
             scope,
             context.input,
             Keyword.put(observation_options(config), :context_evidence_refs, invocation_refs)
           ),
         {:ok, attrs} <- invoke(binding[:candidate], [args, turn, context]),
         {:ok, candidate} <- Candidate.new(attrs),
         :ok <- input_basis(candidate, turn, scope),
         :ok <- invocation_basis(candidate, invocation_refs) do
      if binding[:presentation] || opts[:confirmation] || get_in(context, [:routing, :protected]) do
        prepare_confirmation(scope, candidate, binding, context, opts, config)
      else
        execute(scope, candidate, config, context)
      end
    end
  end

  def confirm(pending, input, context, opts) do
    with {:ok, config} <- config(opts),
         {:ok, binding} <- binding(config, pending.operation),
         {:ok, scope} <- scope(config, context),
         :ok <- matching_scope(scope, pending),
         :ok <- current_activity(scope, config, context, pending),
         :ok <- not_expired(pending),
         :confirm <-
           interpret(binding[:interpreter] || pending[:interpreter], input, pending.presentation),
         :ok <- not_expired(pending),
         {:ok, recovered} <- GAM.recover_proposal(scope, pending.show),
         :ok <- successful_show(recovered),
         :ok <- not_expired(pending),
         {:ok, evidence} <-
           observe_response(scope, config, pending, recovered, input, context, :supports),
         {:ok, refs} <- approval_refs(evidence, pending, recovered),
         {:ok, candidate} <- final_candidate(pending.candidate, pending.presentation, refs),
         :ok <- not_expired(pending) do
      execute(scope, candidate, config, context)
    else
      :unclear -> {:error, :confirmation_unclear}
      :reject -> reject(pending, input, context, opts)
      {:error, _} = error -> error
      _ -> {:error, :confirmation_not_supported}
    end
  end

  def reject(pending, input, context, opts) do
    with {:ok, config} <- config(opts),
         {:ok, binding} <- binding(config, pending.operation),
         {:ok, scope} <- scope(config, context),
         :ok <- matching_scope(scope, pending),
         :ok <- current_activity(scope, config, context, pending),
         :reject <-
           interpret(binding[:interpreter] || pending[:interpreter], input, pending.presentation),
         {:ok, recovered} <- GAM.recover_proposal(scope, pending.show),
         :ok <- successful_show(recovered),
         {:ok, _evidence} <-
           observe_response(scope, config, pending, recovered, input, context, :contradicts) do
      {:consent, :rejected}
    else
      {:error, _} = error -> error
      _ -> {:error, :rejection_unclear}
    end
  end

  def explain(pending, input, context, opts), do: resume(pending, input, context, opts)

  def resume(pending, _input, context, opts) do
    with {:ok, config} <- config(opts),
         {:ok, binding} <- binding(config, pending.operation),
         {:ok, scope} <- scope(config, context),
         :ok <- matching_scope(scope, pending),
         :ok <- current_activity(scope, config, context, pending) do
      binding = Map.put(binding, :interpreter, binding[:interpreter] || pending[:interpreter])
      # A new show identity is mandatory on resume; the host presentation
      # builder must produce a fresh identity, never reuse the original show.
      case prepare_confirmation(scope, pending.candidate, binding, context, opts, config) do
        {:pending, fresh} when fresh.show.primary.act.ref != pending.show.primary.act.ref ->
          {:pending, fresh}

        {:pending, _same} ->
          {:error, :presentation_show_identity_reused}

        other ->
          other
      end
    end
  end

  defp prepare_confirmation(scope, candidate, binding, context, opts, config) do
    interpreter =
      binding[:interpreter] || get_in(Keyword.get(opts, :confirmation, []), [:interpreter])

    with :ok <- validate_interpreter(interpreter),
         {:ok, expires_at} <- consent_expiry(config),
         {:ok, presentation, show_attrs} <-
           invoke(binding[:presentation], [
             candidate,
             Map.put(context, :consent_expires_at, expires_at),
             Keyword.get(opts, :confirmation, [])
           ]),
         {:ok, presentation} <- Presentation.new(presentation),
         true <-
           presentation.candidate_binding_ref == Candidate.presentation_binding_ref(candidate),
         :ok <- show_window(show_attrs),
         {:ok, presentation} <- GAM.prepare_presentation(scope, presentation),
         :ok <-
           journal(config, context, %{
             kind: :show,
             interpreter: interpreter,
             expires_at: expires_at,
             operation: binding.operation,
             candidate: Candidate.canonical(candidate),
             presentation: Presentation.canonical(presentation),
             show_attrs: show_attrs,
             domain_ref: Scope.domain_ref(scope),
             scope_ref: Scope.ref(scope),
             principal_ref: scope.context.authenticated_principal_ref
           }),
         {:ok, show} <- show_presentation(scope, presentation.ref, show_attrs, config, context),
         :ok <- successful_show(show) do
      {:pending,
       maybe_activity(
         %{
           kind: :consent,
           interpreter: interpreter,
           operation: binding.operation,
           candidate: candidate,
           presentation: presentation,
           show: show,
           shown_at: System.system_time(:millisecond),
           domain_ref: Scope.domain_ref(scope),
           scope_ref: Scope.ref(scope),
           principal_ref: scope.context.authenticated_principal_ref,
           expires_at: expires_at
         },
         context
       )}
    else
      false -> {:error, :presentation_candidate_mismatch}
      {:error, _} = error -> error
      other -> {:error, {:invalid_confirmation_material, other}}
    end
  end

  defp execute(scope, candidate, config, context) do
    with :ok <-
           journal(config, context, %{
             kind: :effect,
             candidate: Candidate.canonical(candidate),
             domain_ref: Scope.domain_ref(scope),
             scope_ref: Scope.ref(scope),
             principal_ref: scope.context.authenticated_principal_ref
           }) do
      submit(scope, candidate, config, context)
    end
  end

  defp show_presentation(scope, ref, attrs, config, context) do
    case Map.get(context, :activity) do
      nil -> GAM.show_presentation(scope, ref, attrs)
      origin -> GAM.show_activity_presentation(scope, ref, attrs, config[:activity_fence], origin)
    end
  end

  defp submit(scope, candidate, config, context) do
    result =
      case Map.get(context, :activity) do
        nil -> GAM.propose(scope, candidate)
        origin -> Proposal.run_activity(scope, candidate, config[:activity_fence], origin)
      end

    case result do
      {:ok, result} -> {:governed, Map.put(Map.from_struct(result.primary), :proposal, result)}
      {:error, _} = error -> error
    end
  end

  @doc "Recovers only an exact previously journaled command through normal kernel admission."
  def recover_command(command_id, context, opts) do
    with {:ok, config} <- config(opts),
         {:ok, store} <- journal_store(config),
         {:ok, %{value: saved}} <- Store.fetch(store, journal_key(command_id)),
         {:ok, scope} <- scope(config, context),
         :ok <- matching_scope(scope, saved),
         :ok <- matching_skill(saved, context),
         :ok <- matching_activity(saved, context),
         {:ok, candidate} <- Candidate.from_canonical(saved.candidate) do
      recover_saved(scope, saved, candidate, config)
    else
      :not_found -> {:error, :governed_recovery_required}
      {:error, _} = error -> error
    end
  end

  defp recover_saved(scope, %{kind: :effect} = saved, candidate, config),
    do: submit(scope, candidate, config, saved)

  defp recover_saved(scope, %{kind: :show} = saved, candidate, config) do
    with :ok <- current_activity(scope, config, saved, saved),
         {:ok, presentation} <- Presentation.from_canonical(saved.presentation),
         {:ok, show} <-
           show_presentation(scope, presentation.ref, saved.show_attrs, config, saved),
         :ok <- successful_show(show) do
      {:pending,
       Map.merge(
         Map.take(saved, [
           :operation,
           :domain_ref,
           :scope_ref,
           :principal_ref,
           :interpreter,
           :activity
         ]),
         %{
           kind: :consent,
           status: :suspended,
           candidate: candidate,
           presentation: presentation,
           show: show,
           expires_at: Map.get(saved, :expires_at, 0)
         }
       )}
    end
  end

  @doc "Releases an exact command journal only after durable receiver acquisition."
  def release_command(command_id, context, opts) do
    with {:ok, config} <- config(opts) do
      case Keyword.get(config, :store) do
        nil -> :ok
        store -> release_journal(store, command_id, config, context)
      end
    end
  end

  defp release_journal(store, id, config, context) do
    case Store.fetch(store, journal_key(id)) do
      :not_found ->
        :ok

      {:ok, %{revision: revision, value: saved}} ->
        with {:ok, scope} <- scope(config, context),
             :ok <- matching_scope(scope, saved),
             :ok <- matching_skill(saved, context),
             :ok <- matching_activity(saved, context),
             do: Store.delete(store, journal_key(id), revision)

      {:error, _} = error ->
        error
    end
  end

  @doc "Returns the durable reference used by both live and delivered results."
  def result_reference({:governed, %{decision: decision, act: act, outcome: outcome}})
      when not is_nil(decision) and not is_nil(act) do
    {:ok,
     %{decision_ref: decision.ref, act_ref: act.ref, outcome_ref: if(outcome, do: outcome.ref)}}
  end

  def result_reference(_result), do: {:error, :durable_result_reference_required}

  @doc "Canonical inbox identity for one exact governed result revision."
  def result_key(result) do
    with {:ok, reference} <- result_reference(result),
         do: {:ok, "gam-result:" <> Spectre.GAM.Canonical.Value.digest!(reference)}
  end

  @doc "Resolves references through the host's authenticated Scope without executing an effect."
  def resolve_result(reference, context, opts) when is_map(reference) do
    with {:ok, config} <- config(opts),
         {:ok, scope} <- scope(config, context),
         {:ok, view} <- Spectre.GAM.Facade.Access.scoped_query(scope, {:selected_view, reference}),
         {:ok, result} <- referenced_result(view, reference, scope) do
      {:governed, result}
    end
  end

  def resolve_result(_reference, _context, _opts), do: {:error, :invalid_result_reference}

  @doc "Resolves an exact journaled command's result without submitting its Candidate."
  def resolve_command_result(command_id, reference, context, opts) do
    with {:ok, config} <- config(opts),
         {:ok, store} <- journal_store(config),
         {:ok, %{value: saved}} <- Store.fetch(store, journal_key(command_id)),
         {:ok, scope} <- scope(config, context),
         :ok <- matching_scope(scope, saved),
         :ok <- matching_skill(saved, context),
         {:ok, candidate} <- Candidate.from_canonical(saved.candidate),
         {:governed, result} <- resolve_result(reference, context, opts),
         true <- result.act.candidate_identity_key == candidate.identity_key,
         true <- result.act.material_digest == candidate.material_digest do
      {:governed, result}
    else
      false -> {:error, :result_continuation_mismatch}
      :not_found -> {:error, :governed_recovery_required}
      {:error, _} = error -> error
    end
  end

  defp referenced_result(
         view,
         %{decision_ref: decision_ref, act_ref: act_ref, outcome_ref: outcome_ref},
         scope
       ) do
    with %GAM.Decision{} = decision <- Enum.find(view.decisions, &(&1.ref == decision_ref)),
         %GAM.Act{decision_ref: ^decision_ref} = act <- Enum.find(view.acts, &(&1.ref == act_ref)),
         true <- act.scope_ref == Scope.ref(scope),
         true <- act.authenticated_principal_ref == scope.context.authenticated_principal_ref,
         {:ok, outcome} <- referenced_outcome(view, act, outcome_ref),
         {:ok, attempt} <- referenced_attempt(view, act, outcome),
         evidence_refs = if(outcome, do: outcome.evidence_refs, else: []),
         evidence = Enum.filter(view.evidence, &(&1.ref in evidence_refs)),
         {:ok, primary} <- GAM.Attempt.Runner.Result.ok(decision, act, attempt, evidence, outcome) do
      proposal = %GAM.Proposal.Result{primary: primary, fallback: :not_applicable}
      {:ok, Map.put(Map.from_struct(primary), :proposal, proposal)}
    else
      {:error, _} = error -> error
      _ -> {:error, :execution_result_not_found}
    end
  end

  defp referenced_result(_view, _reference, _scope), do: {:error, :invalid_result_reference}

  defp referenced_outcome(view, act, nil) do
    if Enum.any?(view.outcomes, &(&1.act_ref == act.ref)),
      do: {:error, :result_revision_changed},
      else: {:ok, nil}
  end

  defp referenced_outcome(view, act, ref) when is_binary(ref) do
    case Enum.find(view.outcomes, &(&1.ref == ref and &1.act_ref == act.ref)) do
      nil -> {:error, :execution_result_not_found}
      outcome -> {:ok, outcome}
    end
  end

  defp referenced_outcome(_view, _act, _ref), do: {:error, :invalid_result_reference}

  defp referenced_attempt(view, act, nil),
    do: {:ok, Enum.find(view.attempts, &(&1.act_ref == act.ref))}

  defp referenced_attempt(view, act, outcome) do
    case Enum.find(view.attempts, &(&1.ref == outcome.attempt_ref and &1.act_ref == act.ref)) do
      nil -> {:error, :execution_result_not_found}
      attempt -> {:ok, attempt}
    end
  end

  defp consent_expiry(config) do
    case Keyword.get(config, :consent_ttl_ms, 300_000) do
      :infinity -> {:ok, nil}
      ttl when is_integer(ttl) and ttl > 0 -> {:ok, System.system_time(:millisecond) + ttl}
      _ -> {:error, :invalid_consent_ttl_ms}
    end
  end

  defp journal(config, context, entry) do
    case Keyword.get(config, :store) do
      nil ->
        :ok

      store ->
        write_journal(
          store,
          Map.get(context, :command_id),
          entry |> Map.put(:skill, Map.get(context, :skill)) |> maybe_activity(context)
        )
    end
  end

  defp write_journal(store, id, entry) when is_binary(id) and id != "" do
    case Store.put_new(store, journal_key(id), entry) do
      {:ok, _revision} -> :ok
      {:error, :exists} -> match_journal(store, id, entry)
      {:error, _} = error -> error
    end
  end

  defp write_journal(_, _, _), do: {:error, :durable_command_id_required}

  defp match_journal(store, id, entry) do
    case Store.fetch(store, journal_key(id)) do
      {:ok, %{value: ^entry}} -> :ok
      _ -> {:error, :governed_command_conflict}
    end
  end

  defp journal_store(config) do
    case Keyword.fetch(config, :store) do
      {:ok, store} -> {:ok, store}
      :error -> {:error, :governed_recovery_required}
    end
  end

  defp journal_key(id), do: {:spectre_gam_command, id}

  defp maybe_activity(entry, %{activity: %{ref: _, revision: _} = origin}),
    do: Map.put(entry, :activity, Map.take(origin, [:ref, :revision]))

  defp maybe_activity(entry, _context), do: entry

  defp current_activity(scope, config, context, pending) do
    case {Map.get(context, :activity), Map.get(pending, :activity)} do
      {nil, nil} ->
        :ok

      {%{ref: ref, revision: revision}, %{ref: ref, revision: revision} = origin} ->
        Sequencer.activity_fence(scope.domain.server, config[:activity_fence], {:current, origin})

      _ ->
        {:error, :superseded}
    end
  end

  defp matching_activity(saved, context) do
    if get_in(saved, [:activity, :ref]) == get_in(context, [:activity, :ref]),
      do: :ok,
      else: {:error, :journal_activity_mismatch}
  end

  defp successful_show(%{primary: %{act: act, outcome: %{status: :succeeded}}})
       when not is_nil(act), do: :ok

  defp successful_show(_), do: {:error, :presentation_not_shown}

  defp show_window(attrs) do
    window =
      cond do
        is_map(attrs) -> Map.get(attrs, :observation_window_ms)
        is_list(attrs) -> Keyword.get(attrs, :observation_window_ms)
        true -> nil
      end

    if is_integer(window) and window > 0,
      do: :ok,
      else: {:error, :presentation_observation_window_required}
  end

  defp input_basis(candidate, turn, scope) do
    cond do
      candidate.scope_ref != Scope.ref(scope) ->
        {:error, :candidate_scope_mismatch}

      candidate.proposer_ref != scope.context.authenticated_principal_ref ->
        {:error, :candidate_principal_mismatch}

      not Enum.all?(Turn.evidence_refs(turn), &(&1 in candidate.evidence_refs)) ->
        {:error, :candidate_input_basis_missing}

      true ->
        :ok
    end
  end

  defp matching_scope(scope, pending) do
    if pending.domain_ref == Scope.domain_ref(scope) and pending.scope_ref == Scope.ref(scope) and
         pending.principal_ref == scope.context.authenticated_principal_ref,
       do: :ok,
       else: {:error, :pending_scope_mismatch}
  end

  defp not_expired(%{expires_at: time}) when is_integer(time) do
    if System.system_time(:millisecond) < time, do: :ok, else: {:error, :consent_expired}
  end

  defp not_expired(_), do: :ok

  defp final_candidate(candidate, presentation, refs) do
    candidate
    |> Map.from_struct()
    |> Map.drop([:ref, :material_digest])
    |> Map.put(:presentation_ref, presentation.ref)
    |> Map.put(:evidence_refs, Enum.uniq(candidate.evidence_refs ++ refs))
    |> Candidate.new()
  end

  defp observe_response(scope, config, pending, show, input, context, stance) do
    case GAM.observe(
           Keyword.get(config, :response_scope, scope),
           response_input(pending, show, input, context, stance),
           observation_options(config)
         ) do
      {:error, _} = error ->
        with :ok <- current_activity(scope, config, context, pending), do: error

      observed ->
        observed
    end
  end

  defp response_input(pending, show, input, context, stance) do
    %{
      kind: :presentation_response,
      input: input,
      presentation: pending.presentation,
      show_act: show.primary.act,
      stance: stance,
      received_at: Map.get(context, :received_at),
      event_sequence: Map.get(context, :event_sequence),
      expires_at: Map.get(pending, :expires_at)
    }
  end

  defp approval_refs(evidence, pending, show) do
    proposition =
      Presentation.approval_proposition(pending.presentation.ref, show.primary.act.ref)

    refs = for e <- evidence, e.proposition == proposition and e.stance == :supports, do: e.ref
    if refs == [], do: {:error, :approval_evidence_missing}, else: {:ok, refs}
  end

  defp config(opts) do
    case Keyword.fetch(opts, :bridge_config) do
      {:ok, config} when is_list(config) -> {:ok, config}
      _ -> {:error, :gam_bridge_config_required}
    end
  end

  defp binding(config, operation) do
    case Map.fetch(Keyword.get(config, :bindings, %{}), operation) do
      {:ok, binding} when is_map(binding) -> {:ok, Map.put(binding, :operation, operation)}
      _ -> {:error, {:unbound_governed_operation, operation}}
    end
  end

  @doc "Pins the host integration to one Domain before starting its agent and Skill runtimes."
  @spec pin_domain(term(), map()) :: {:ok, term()} | {:error, term()}
  def pin_domain({__MODULE__, config}, context) do
    with {:ok, scope} <- scope(config, context) do
      {:ok, {__MODULE__, Keyword.put(config, :domain_ref, Scope.domain_ref(scope))}}
    end
  end

  def pin_domain({Spectre.Server.GAM.Managed, config} = bridge, _context) do
    if is_pid(Keyword.get(config, :server)),
      do: {:ok, bridge},
      else: {:error, :managed_domain_required}
  end

  def pin_domain(nil, _context), do: {:ok, nil}
  def pin_domain(_bridge, _context), do: {:error, :skills_require_standard_gam_bridge}

  @spec scope(keyword(), map()) :: {:ok, Scope.t()} | {:error, term()}
  defp scope(config, context) do
    result =
      case Keyword.get(config, :scope) do
        %Scope{} = scope -> {:ok, scope}
        {module, function} -> invoke({module, function}, [context])
        _ -> {:error, :authenticated_scope_required}
      end

    with {:ok, %Scope{} = scope} <- result do
      if Keyword.get(config, :domain_ref, Scope.domain_ref(scope)) == Scope.domain_ref(scope),
        do: {:ok, scope},
        else: {:error, :agent_domain_mismatch}
    end
  end

  @spec skill_authority(map(), term()) :: :ok | {:error, term()}
  defp skill_authority(%{skill: %{governed: allowed}}, operation) do
    if operation in allowed, do: :ok, else: {:error, {:skill_operation_not_allowed, operation}}
  end

  defp skill_authority(_context, _operation), do: :ok

  @spec matching_skill(map(), map()) :: :ok | {:error, atom()}
  defp matching_skill(saved, context) do
    if skill_identity(Map.get(saved, :skill)) == skill_identity(Map.get(context, :skill)),
      do: :ok,
      else: {:error, :journal_skill_mismatch}
  end

  @spec skill_identity(map() | nil) :: map() | nil
  defp skill_identity(nil), do: nil
  defp skill_identity(skill), do: Map.take(skill, [:id, :module])

  @spec invocation_basis(Candidate.t(), [binary()]) :: :ok | {:error, atom()}
  defp invocation_basis(candidate, refs) do
    if Enum.all?(refs, &(&1 in candidate.evidence_refs)),
      do: :ok,
      else: {:error, :candidate_skill_invocation_missing}
  end

  defp observation_options(config), do: Keyword.take(config, [:ingress_opts])

  defp interpret({module, function}, input, presentation),
    do: apply(module, function, [input, presentation])

  defp interpret(_, _, _), do: :unclear

  defp validate_interpreter({module, function}) when is_atom(module) and is_atom(function) do
    if Code.ensure_loaded?(module) and function_exported?(module, function, 2),
      do: :ok,
      else: {:error, :confirmation_interpreter_required}
  end

  defp validate_interpreter(_), do: {:error, :confirmation_interpreter_required}

  defp invoke({module, function}, args) when is_atom(module) and is_atom(function),
    do: apply(module, function, args)

  defp invoke(_, _), do: {:error, :gam_binding_callback_required}
end
