defmodule Spectre.Server.GAM.Managed.Ingress do
  @moduledoc false
  use Spectre.GAM.Ingress, ref: "spectre:managed:ingress:v1"
  alias Spectre.GAM
  alias Spectre.Server.GAM.{Invocation, Lifecycle}
  alias Spectre.Server.GAM.Managed.Gate

  @impl true
  def authenticate(domain, scope, %{gate: gate, token: token}, generation, _opts) do
    with {:ok, auth} <- Gate.authenticate(gate, token),
         true <- domain == auth.domain and scope == auth.scope do
      GAM.SubmissionContext.new(%{
        domain_ref: domain,
        scope_ref: scope,
        authenticated_principal_ref: auth.principal,
        authentication_ref: auth.authentication,
        ingress_ref: ref(),
        channel_ref: "spectre:managed:transport",
        session_ref: auth.session,
        host_generation: generation
      })
    else
      _ -> {:error, :unauthenticated}
    end
  end

  def authenticate(_, _, _, _, _), do: {:error, :unauthenticated}

  @impl true
  def observe(context, %{kind: :presentation_response} = envelope, now, opts) do
    input_digest = Base.encode16(:crypto.hash(:sha256, envelope.input.text), case: :lower)

    with gate when is_pid(gate) <- opts[:gate],
         :ok <-
           Gate.consume(
             gate,
             envelope.presentation.ref,
             envelope.stance,
             opts[:consent_proof],
             input_digest
           ) do
      GAM.Presentation.response_evidence(
        context,
        envelope.presentation,
        envelope.show_act,
        envelope.stance,
        now,
        payload: %{text: envelope.input.text, source_digest: input_digest},
        valid_until: envelope.expires_at
      )
    else
      _ -> {:error, :consent_transport_proof_required}
    end
  end

  def observe(context, %{kind: kind, invocation: value}, now, _)
      when kind in [
             :spectre_skill_invocation,
             :spectre_agent_invocation,
             :spectre_external_invocation
           ],
      do: Invocation.evidence(context, value, now)

  def observe(context, %{kind: :spectre_server_lifecycle, event: value}, now, _),
    do: Lifecycle.evidence(context, value, now)

  def observe(context, %{kind: :spectre_action_rejected} = value, now, _),
    do:
      GAM.Ingress.evidence(context, now,
        proposition: {:spectre_action_preparation_rejected, value.command_id},
        issuer_ref: ref(),
        payload: value
      )

  def observe(context, nil, now, _),
    do:
      GAM.Ingress.evidence(context, now,
        proposition: "spectre:managed:host-callback-trigger",
        issuer_ref: ref(),
        payload: %{trigger: :otp_callback}
      )

  def observe(context, %Spectre.Input{text: text}, now, _),
    do:
      GAM.Ingress.evidence(context, now,
        proposition: "spectre:managed:user-request",
        issuer_ref: context.authenticated_principal_ref,
        payload: text
      )
end
