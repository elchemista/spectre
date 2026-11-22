defmodule Spectre.Server.GAM.Lifecycle do
  @moduledoc """
  Scoped host observations of a Server pending intention's lifecycle.

  The Domain's fixed ingress must authenticate `:spectre_server_lifecycle`
  envelopes as host events before calling `evidence/3`. This helper creates
  observed Evidence from that ingress; it creates no Act, permission, approval
  or user rejection. The source and issuer are the ingress, not the user.

  Each immutable phase has a distinct stable event id. `:requested` describes
  an instruction. `:applied` describes an already acquired local transition;
  the Runtime must save that transition and its report outbox together before
  recording it. `:ignored` describes an instruction that did not apply.
  Reasons and status names remain host facts, not changes to GAM's laws.
  """

  alias Spectre.GAM
  alias Spectre.GAM.{Evidence, Ingress, Scope, SubmissionContext}
  alias Spectre.GAM.Canonical.Value
  alias Spectre.Server.GAM.Managed.Payload

  @required [:id, :phase, :kind, :pending_id, :revision]
  @optional [
    :schema_version,
    :command_id,
    :reason,
    :deadline,
    :candidate_ref,
    :show_ref,
    :input_id,
    :interaction_id,
    :origin_id,
    :source,
    :status,
    :outcome_reason,
    :from_status,
    :to_status,
    :policy_ref,
    :requested_revision,
    :timer_owner,
    :schedule_id,
    :domain_ref,
    :scope_ref,
    :principal_ref
  ]
  @phases [:requested, :applied, :ignored]
  @kinds [:schedule_close, :cancel_close, :close, :suspend, :resume]
  @identity_binding "spectre_server_lifecycle_event_id"
  @digest_binding "spectre_server_lifecycle_event_digest"

  @doc "Builds host-observed Evidence inside the Domain's authenticated ingress callback."
  @spec evidence(SubmissionContext.t(), map(), integer()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def evidence(%SubmissionContext{} = context, event, observed_at) when is_integer(observed_at) do
    with {:ok, digest} <- validate(event),
         :ok <- matching_subject(event, context) do
      Ingress.evidence(context, observed_at,
        proposition: proposition(event.id),
        stance: :supports,
        issuer_ref: context.ingress_ref,
        bindings: %{@identity_binding => event.id, @digest_binding => digest},
        payload: %{event: event, event_digest: digest}
      )
    end
  end

  def evidence(_context, _event, _observed_at), do: {:error, :invalid_lifecycle_observation}

  @doc "Finds or records one immutable phase through normal authenticated GAM observation."
  @spec record(Scope.t(), map(), keyword()) ::
          {:lifecycle_recorded,
           %{event_id: binary(), event_digest: binary(), evidence_refs: [binary()]}}
          | {:error, term()}
  def record(%Scope{} = scope, event, opts) when is_list(opts) do
    with {:ok, digest} <- validate(event),
         :ok <- matching_subject(event, scope.context) do
      lock_record(scope, event, digest, opts)
    end
  end

  def record(_scope, _event, _opts), do: {:error, :authenticated_scope_required}

  defp lock_record(scope, event, digest, opts) do
    # This is only local race coordination. The durable fact and recovery
    # identity remain in GAM. A crashed owner releases the lock automatically.
    key =
      {__MODULE__, Scope.domain_ref(scope), Scope.ref(scope),
       scope.context.authenticated_principal_ref, event.id}

    case :global.trans(
           {key, self()},
           fn -> recover_or_observe(scope, event, digest, opts) end,
           [node()]
         ) do
      :aborted -> {:error, :lifecycle_recording_unavailable}
      result -> result
    end
  end

  @doc "Validates the closed, portable host event and returns its exact digest."
  @spec validate(term()) :: {:ok, binary()} | {:error, term()}
  def validate(event) when is_map(event) and not is_struct(event) do
    cond do
      Enum.any?(@required, &(not Map.has_key?(event, &1))) ->
        {:error, :lifecycle_event_fields_required}

      Map.keys(event) -- (@required ++ @optional) != [] ->
        {:error, :unknown_lifecycle_event_fields}

      not nonempty?(event.id) or is_nil(event.pending_id) ->
        {:error, :invalid_lifecycle_identity}

      true ->
        with :ok <- validate_transition(event),
             :ok <- validate_timer_owner(event),
             :ok <- Value.validate(event),
             do: {:ok, Value.digest!(event)}
    end
  end

  def validate(_event), do: {:error, :invalid_lifecycle_event}

  defp validate_transition(event) do
    cond do
      event.phase not in @phases or event.kind not in @kinds ->
        {:error, :invalid_lifecycle_transition}

      not is_integer(event.revision) or event.revision < 0 ->
        {:error, :invalid_lifecycle_revision}

      Map.get(event, :schema_version, 1) != 1 ->
        {:error, :unsupported_lifecycle_schema_version}

      not is_nil(Map.get(event, :deadline)) and not is_integer(event.deadline) ->
        {:error, :invalid_lifecycle_deadline}

      true ->
        :ok
    end
  end

  defp validate_timer_owner(event) do
    if Map.get(event, :timer_owner) in [nil, :runtime, :application],
      do: :ok,
      else: {:error, :invalid_lifecycle_timer_owner}
  end

  defp recover_or_observe(scope, event, digest, opts) do
    with {:ok, records} <-
           Spectre.GAM.Facade.Access.scoped_query(
             scope,
             {:evidence_proposition, proposition(event.id)}
           ) do
      case Enum.filter(records, &(&1.bindings[@identity_binding] == event.id)) do
        [] -> observe(scope, event, digest, opts)
        existing -> receipt(existing, scope, event, digest, opts)
      end
    end
  end

  defp observe(scope, event, digest, opts) do
    with {:ok, observed} <-
           GAM.observe(scope, %{kind: :spectre_server_lifecycle, event: event}, opts) do
      receipt(observed, scope, event, digest, opts)
    end
  end

  defp receipt(records, scope, event, digest, opts) do
    with {:ok, records} <- Payload.restore_evidence(records, opts, Scope.domain_ref(scope)) do
      validated_receipt(records, scope, event, digest)
    end
  end

  defp validated_receipt(records, scope, event, digest) do
    cond do
      Enum.any?(records, &conflicting_evidence?(&1, event.id, digest)) ->
        {:error, :lifecycle_event_conflict}

      records == [] or not Enum.all?(records, &valid_evidence?(&1, scope, event, digest)) ->
        {:error, :invalid_lifecycle_evidence}

      true ->
        {:lifecycle_recorded,
         %{
           event_id: event.id,
           event_digest: digest,
           evidence_refs: records |> Enum.map(& &1.ref) |> Enum.sort()
         }}
    end
  end

  defp conflicting_evidence?(evidence, id, digest),
    do:
      evidence.bindings[@identity_binding] == id and evidence.bindings[@digest_binding] != digest

  defp valid_evidence?(
         %Evidence{
           provenance: :observed,
           stance: :supports,
           parent_refs: [],
           assumptions: [],
           provisional: false
         } = evidence,
         scope,
         event,
         digest
       ) do
    host_source?(evidence, scope.context) and event_binding?(evidence, event, digest) and
      context_binding?(evidence, scope.context)
  end

  defp valid_evidence?(_evidence, _scope, _event, _digest), do: false

  defp host_source?(evidence, context),
    do: evidence.source_ref == context.ingress_ref and evidence.issuer_ref == context.ingress_ref

  defp event_binding?(evidence, event, digest) do
    evidence.proposition == proposition(event.id) and
      evidence.bindings[@identity_binding] == event.id and
      evidence.bindings[@digest_binding] == digest and
      evidence.payload == %{event: event, event_digest: digest}
  end

  defp context_binding?(evidence, context) do
    expected = SubmissionContext.evidence_bindings(context)
    stable_context = ["domain_ref", "scope_ref", "authenticated_principal_ref", "ingress_ref"]

    Enum.all?(stable_context, &(evidence.bindings[&1] == expected[&1]))
  end

  defp matching_subject(event, %SubmissionContext{} = context) do
    expected = %{
      domain_ref: context.domain_ref,
      scope_ref: context.scope_ref,
      principal_ref: context.authenticated_principal_ref
    }

    if Enum.all?(expected, fn {field, value} ->
         is_nil(Map.get(event, field)) or Map.get(event, field) == value
       end), do: :ok, else: {:error, :lifecycle_scope_mismatch}
  end

  defp matching_subject(_event, _context), do: {:error, :authenticated_scope_required}

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp proposition(id), do: {:spectre_server_lifecycle, id}
end
