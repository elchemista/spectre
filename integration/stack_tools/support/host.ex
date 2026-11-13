Code.require_file("../../../test/gam/v0_4/support/fixture.ex", __DIR__)

defmodule Outreach.Mind do
  use Spectre.GAM.Mind, ref: "mind:outreach-integration"
  def deliberate(_, _), do: {:ok, []}
end

defmodule Outreach.Ingress do
  alias Spectre.GAM
  defdelegate ref(), to: GAM.V04Test.Ingress
  defdelegate authenticate(d, s, i, g, o), to: GAM.V04Test.Ingress

  def observe(context, %{kind: :presentation_response} = envelope, now, _) do
    GAM.Presentation.response_evidence(
      context,
      envelope.presentation,
      envelope.show_act,
      envelope.stance,
      now,
      payload: envelope.input.text,
      valid_until: envelope.expires_at
    )
  end

  def observe(context, %{kind: :spectre_server_lifecycle, event: event}, now, _),
    do: Spectre.Server.GAM.Lifecycle.evidence(context, event, now)

  def observe(context, %Spectre.Input{text: text}, now, _) do
    GAM.Ingress.evidence(context, now,
      proposition: "outreach:request",
      issuer_ref: context.authenticated_principal_ref,
      payload: text
    )
  end

  defdelegate observe(context, attrs, now, opts), to: GAM.V04Test.Ingress
end

defmodule Outreach.Host do
  alias Spectre.GAM
  alias GAM.V04Test.Fixture

  def email(%{"to" => "dev@example.com"} = args, turn, context),
    do: candidate("email.send", args, turn, context, false)

  def email(_, _, _), do: {:error, :recipient_not_allowed}
  def notice(args, turn, context), do: candidate("notice.send", args, turn, context, false)

  def report(args, turn, context) do
    # Freeze the authenticated host partition into the Candidate. The model
    # and later mutable Server context cannot redirect the admitted write.
    args = Map.put(args, "memory_subject", Map.fetch!(context.identity, :subject))
    candidate("report.save", args, turn, context, true)
  end

  defp candidate(class, args, turn, context, confirmation?) do
    fixture = context.options[:host_fixture]

    attrs =
      Fixture.refund_candidate(fixture, 1,
        identity_key: "outreach:" <> context.command_id,
        evidence_refs:
          Enum.uniq([fixture.refs.payment_evidence | GAM.Mind.Turn.evidence_refs(turn)])
      )

    attrs = %{attrs | class: class, consequence: Map.put(attrs.consequence, "payload", args)}

    attrs =
      if confirmation? do
        {:ok, digest} = GAM.Consent.data_digest(attrs.consequence)

        Map.put(attrs, :consent, %{
          schema_version: 1,
          recipient_refs: [fixture.refs.proposer],
          data_digest: digest,
          cost: 1,
          purpose_ref: attrs.purpose_ref,
          purpose_params: attrs.purpose_params,
          risk: "persistent storage",
          reversibility: false,
          alternatives: ["cancel"]
        })
      else
        attrs
      end

    {:ok, attrs}
  end

  def presentation(candidate, context, _opts) do
    fixture = context.options[:host_fixture]
    consent = candidate.consent

    {:ok, presentation} =
      GAM.Presentation.new(%{
        candidate_binding_ref: GAM.Candidate.presentation_binding_ref(candidate),
        scope_ref: candidate.scope_ref,
        recipient_refs: consent["recipient_refs"],
        approval_source_refs: [Outreach.Ingress.ref()],
        data: candidate.consequence,
        cost: consent["cost"],
        purpose_ref: consent["purpose_ref"],
        purpose_params: consent["purpose_params"],
        risk: consent["risk"],
        reversibility: consent["reversibility"],
        alternatives: consent["alternatives"],
        renderer_ref: "renderer:outreach",
        rendered_payload: "Save the outreach report?",
        prepared_at: GAM.V04Test.Runtime.now()
      })

    {:ok, presentation,
     %{
       identity_key: "show:" <> context.command_id,
       requested_mandate_ref: fixture.mandate.ref,
       executor_ref: fixture.refs.executor,
       executor_contract_ref: fixture.refs.executor_contract,
       accountable_ref: fixture.refs.accountable,
       subject_refs: candidate.subject_refs,
       evidence_refs: candidate.evidence_refs,
       observation_window_ms: fixture.observation_window_ms
     }}
  end

  def interpret(%Spectre.Input{text: "yes"}, _), do: :confirm
  def interpret(%Spectre.Input{text: "no"}, _), do: :reject
  def interpret(_, _), do: :unclear

  def contract do
    {:ok, contract} =
      GAM.Consequence.Contract.new(%{
        shape: %{
          "amount_cents" => "positive_integer",
          "currency" => %{"$const" => "EUR"},
          "customer_ref" => "subject_ref",
          "order_ref" => "ref",
          "destination_ref" => "destination_ref",
          "meter_requests" => "meter_requests",
          "payload" => "portable"
        }
      })

    contract
  end
end

defmodule Outreach.Executor do
  alias Spectre.GAM
  defdelegate executor_ref(), to: GAM.V04Test.Executor
  defdelegate contract_ref(), to: GAM.V04Test.Executor

  def execute(act, attempt, _capability, opts) do
    send(opts[:observer], {:admitted_effect, act.class})
    result = perform(act, opts)

    case result do
      {:ok, _receipt} ->
        attest(act, attempt, :succeeded, result)

      {:error, :already_contacted} ->
        attest(act, attempt, :definitive_no_effect, result)

      # A transport error is not proof that its external effect did not happen.
      # Keep the Attempt ambiguous for host reconciliation, never attest failure.
      {:error, _reason} ->
        {:error, :ambiguous, %{evidence: [], details_ref: "uncertain:" <> act.ref}}
    end
  end

  defp attest(act, attempt, status, result) do
    {:ok, evidence} =
      GAM.Attempt.Executor.outcome_evidence(act, attempt, status, GAM.V04Test.Runtime.now(),
        payload: result
      )

    observation = %{evidence: [evidence], details_ref: "receipt:" <> act.ref}
    if status == :succeeded, do: {:ok, observation}, else: {:error, status, observation}
  end

  defp perform(%{class: "presentation.show"}, _opts), do: {:ok, %{shown: true}}

  defp perform(%{class: "email.send", consequence: %{"payload" => args}}, _opts) do
    Spectre.Kinetic.Actions.execute(%{name: :send_email, args: args}, %{},
      module: Outreach.Actions
    )
  end

  defp perform(%{class: "notice.send", consequence: %{"payload" => args}} = act, _opts) do
    Spectre.Beam.ServerTool.execute(args, %{agent: Outreach.Agent, command_id: act.ref})
  end

  defp perform(%{class: "report.save", consequence: %{"payload" => args}} = act, opts) do
    {subject, args} = Map.pop!(args, "memory_subject")

    Spectre.Mnemonic.ServerTool.execute(:remember, args, %{
      agent: Outreach.Agent,
      command_id: act.ref,
      identity: %{subject: subject},
      options: opts[:memory_options] || []
    })
  end
end
