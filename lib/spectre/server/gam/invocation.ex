defmodule Spectre.Server.GAM.Invocation do
  @moduledoc """
  Host-observed attribution of governed commands in the shared GAM ledger.

  The fixed ingress records Agent, Skill and authenticated external-actor
  invocations separately. This is computational provenance, not user approval
  or a grant. The bridge requires this Evidence in the Candidate. Legacy host
  integrations retain their existing Skill envelope and root observation path.
  """
  alias Spectre.GAM
  alias Spectre.GAM.{Evidence, Ingress, Scope, SubmissionContext}
  alias Spectre.GAM.Canonical.Value

  @doc "Builds attribution Evidence inside the authenticated Domain ingress."
  @spec evidence(SubmissionContext.t(), map(), integer()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def evidence(%SubmissionContext{} = context, invocation, now) when is_map(invocation) do
    with :ok <- validate(invocation, context) do
      Ingress.evidence(context, now,
        proposition: {kind(invocation), invocation.command_id},
        issuer_ref: context.ingress_ref,
        bindings: %{digest_key(invocation) => Value.digest!(invocation)},
        payload: invocation
      )
    end
  end

  @doc false
  @spec record(Scope.t(), map(), term(), keyword()) :: {:ok, [binary()]} | {:error, term()}
  def record(scope, %{skill: %{id: id, module: module}} = context, operation, opts) do
    invocation = Map.merge(base(scope, context, operation), %{skill: id, module: module})
    record_invocation(scope, invocation, opts)
  end

  def record(scope, %{managed: _, external_submission: external} = context, operation, opts)
      when not is_nil(external) do
    case external do
      %{source: :external_actor, submitter_ref: ref} when is_binary(ref) and ref != "" ->
        invocation =
          Map.merge(base(scope, context, operation), %{
            source: :external_actor,
            agent: context.agent,
            submitter_ref: ref
          })

        record_invocation(scope, invocation, opts)

      _ ->
        {:error, :invalid_external_invocation}
    end
  end

  def record(scope, %{managed: _} = context, operation, opts) do
    invocation =
      Map.merge(base(scope, context, operation), %{source: :agent, agent: context.agent})

    record_invocation(scope, invocation, opts)
  end

  def record(_scope, _context, _operation, _opts), do: {:ok, []}

  @spec record_invocation(Scope.t(), map(), keyword()) :: {:ok, [binary()]} | {:error, term()}
  defp record_invocation(scope, invocation, opts) do
    with :ok <- validate(invocation, scope.context),
         {:ok, evidence} <-
           GAM.observe(scope, %{kind: kind(invocation), invocation: invocation}, opts) do
      matching = Enum.filter(evidence, &matches?(&1, invocation, scope.context))

      if matching == [],
        do: {:error, missing_evidence(invocation)},
        else: {:ok, Enum.map(matching, & &1.ref)}
    end
  end

  @spec base(Scope.t(), map(), term()) :: map()
  defp base(scope, context, operation) do
    %{
      command_id: context.command_id,
      interaction: Map.get(context, :interaction),
      operation: operation,
      domain_ref: Scope.domain_ref(scope),
      scope_ref: Scope.ref(scope),
      principal_ref: scope.context.authenticated_principal_ref
    }
  end

  @spec validate(map(), SubmissionContext.t()) :: :ok | {:error, atom()}
  defp validate(invocation, context) do
    if is_binary(invocation[:command_id]) and invocation[:command_id] != "" and
         invocation[:domain_ref] == context.domain_ref and
         invocation[:scope_ref] == context.scope_ref and
         invocation[:principal_ref] == context.authenticated_principal_ref and
         valid_source?(invocation) and
         Value.validate(invocation) == :ok,
       do: :ok,
       else: {:error, :invalid_skill_invocation}
  end

  @spec valid_source?(map()) :: boolean()
  defp valid_source?(%{source: :external_actor, agent: agent, submitter_ref: ref}),
    do: is_atom(agent) and agent not in [nil, true, false] and is_binary(ref) and ref != ""

  defp valid_source?(%{source: :agent, agent: agent}),
    do: is_atom(agent) and agent not in [nil, true, false]

  defp valid_source?(%{source: _}), do: false
  defp valid_source?(%{skill: _, module: module}), do: is_atom(module) and not is_nil(module)
  defp valid_source?(_), do: false

  @spec kind(map()) :: atom()
  defp kind(%{source: :external_actor}), do: :spectre_external_invocation
  defp kind(%{source: :agent}), do: :spectre_agent_invocation
  defp kind(_), do: :spectre_skill_invocation

  @spec digest_key(map()) :: binary()
  defp digest_key(invocation), do: Atom.to_string(kind(invocation)) <> "_digest"

  @spec missing_evidence(map()) :: atom()
  defp missing_evidence(%{source: :external_actor}), do: :external_invocation_evidence_missing
  defp missing_evidence(%{source: :agent}), do: :agent_invocation_evidence_missing
  defp missing_evidence(_), do: :skill_invocation_evidence_missing

  @spec matches?(Evidence.t(), map(), SubmissionContext.t()) :: boolean()
  defp matches?(
         %Evidence{
           provenance: :observed,
           parent_refs: [],
           assumptions: [],
           provisional: false,
           stance: :supports
         } = evidence,
         invocation,
         context
       ) do
    evidence.source_ref == context.ingress_ref and evidence.issuer_ref == context.ingress_ref and
      evidence.proposition == {kind(invocation), invocation.command_id} and
      evidence.payload == invocation and
      evidence.bindings[digest_key(invocation)] == Value.digest!(invocation) and
      Enum.all?(SubmissionContext.evidence_bindings(context), fn {key, value} ->
        evidence.bindings[key] == value
      end)
  end

  defp matches?(_evidence, _invocation, _context), do: false
end
