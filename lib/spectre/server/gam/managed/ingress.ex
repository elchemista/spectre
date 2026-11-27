defmodule Spectre.Server.GAM.Managed.Ingress do
  @moduledoc false
  use ExGAM.Ingress, ref: "spectre:managed:ingress:v1"
  alias ExGAM, as: GAM
  alias Spectre.Server.GAM.{Invocation, Lifecycle}
  alias Spectre.Server.GAM.Managed.{Gate, Payload}

  @impl true
  def authenticate(domain, scope, %{gate: gate, external_proof: proof}, generation, _opts),
    do:
      submission_context(
        Gate.external_auth(gate, proof),
        domain,
        scope,
        generation,
        "external-approval"
      )

  def authenticate(domain, scope, %{gate: gate, token: token}, generation, _opts),
    do: submission_context(Gate.authenticate(gate, token), domain, scope, generation, "transport")

  def authenticate(_, _, _, _, _), do: {:error, :unauthenticated}

  defp submission_context(
         {:ok, %{domain: domain, scope: scope} = auth},
         domain,
         scope,
         generation,
         channel
       ) do
    GAM.SubmissionContext.new(%{
      domain_ref: domain,
      scope_ref: scope,
      authenticated_principal_ref: auth.principal,
      authentication_ref: auth.authentication,
      ingress_ref: ref(),
      channel_ref: "spectre:managed:" <> channel,
      session_ref: auth.session,
      host_generation: generation
    })
  end

  defp submission_context(_, _, _, _, _), do: {:error, :unauthenticated}

  @impl true
  def observe(context, input, now, opts) do
    with {:ok, evidence} <- do_observe(context, input, now, opts),
         {:ok, payload} <-
           Payload.protect(opts[:payload_store], evidence.payload, %{
             kind: :evidence,
             domain_ref: context.domain_ref,
             evidence_ref: evidence.ref
           }) do
      if payload == evidence.payload do
        {:ok, evidence}
      else
        evidence
        |> Map.from_struct()
        |> Map.delete(:ref)
        |> Map.put(:payload, payload)
        |> GAM.Evidence.new()
      end
    end
  end

  defp do_observe(context, %{kind: :presentation_response} = envelope, now, opts) do
    input_digest = Base.encode16(:crypto.hash(:sha256, envelope.input.text), case: :lower)

    external =
      case opts[:gate] && Gate.external_auth(opts[:gate], opts[:consent_proof]) do
        {:ok, auth} -> %{external_approval: %{request: auth.request, response: auth.response}}
        _ -> %{}
      end

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
        payload: Map.merge(%{text: envelope.input.text, source_digest: input_digest}, external),
        valid_until:
          get_in(external, [:external_approval, :request, "expires_at"]) || envelope.expires_at
      )
    else
      _ -> {:error, :consent_transport_proof_required}
    end
  end

  defp do_observe(context, %{kind: kind, invocation: value}, now, _)
       when kind in [
              :spectre_skill_invocation,
              :spectre_agent_invocation,
              :spectre_external_invocation
            ],
       do: Invocation.evidence(context, value, now)

  defp do_observe(context, %{kind: :spectre_server_lifecycle, event: value}, now, _),
    do: Lifecycle.evidence(context, value, now)

  defp do_observe(context, %{kind: :spectre_action_rejected} = value, now, _),
    do:
      GAM.Ingress.evidence(context, now,
        proposition: {:spectre_action_preparation_rejected, value.command_id},
        issuer_ref: ref(),
        payload: value
      )

  defp do_observe(context, nil, now, _),
    do:
      GAM.Ingress.evidence(context, now,
        proposition: "spectre:managed:host-callback-trigger",
        issuer_ref: ref(),
        payload: %{trigger: :otp_callback}
      )

  defp do_observe(context, %Spectre.Input{text: text}, now, _),
    do:
      GAM.Ingress.evidence(context, now,
        proposition: "spectre:managed:user-request",
        issuer_ref: context.authenticated_principal_ref,
        payload: text
      )
end
