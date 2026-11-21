defmodule Spectre.Server.GAM.Managed.Binding do
  @moduledoc false
  alias Spectre.GAM
  alias Spectre.GAM.Mind.Turn
  alias Spectre.Server.GAM.Effect
  alias Spectre.Server.GAM.Managed.{Approval, Content, Executor, Gate, Ingress, Material}

  @doc false
  @spec validate_overrides(map(), map()) :: :ok | {:error, term()}
  def validate_overrides(effects, overrides) do
    validate_overrides!(effects, overrides)
  rescue
    error in ArgumentError -> {:error, {:invalid_managed_bindings, Exception.message(error)}}
  end

  @doc false
  @spec validate_overrides!(map(), map()) :: :ok
  def validate_overrides!(effects, overrides)
      when is_map(overrides) and not is_struct(overrides) do
    Enum.each(overrides, fn {operation, override} ->
      entry = Map.get(effects, operation) || invalid!("override operation is not enabled")
      validate_override!(entry, override)
    end)

    :ok
  end

  def validate_overrides!(_, _), do: invalid!("bindings must be a plain map")
  @doc false
  @spec bindings(map(), term(), map()) :: map()
  def bindings(state, current, policy) do
    Map.new(state.effects, fn {operation, entry} ->
      override = override(state.options, operation)

      confirm? =
        Keyword.get(entry.settings, :confirm, false) or
          (operation == current and Map.get(policy, :confirm, false)) or
          not is_nil(Map.get(override, :presentation))

      binding = %{candidate: {__MODULE__, :candidate}, schema_hash: entry.effect.schema_hash}

      binding =
        if confirm?,
          do:
            Map.merge(binding, %{
              presentation: {__MODULE__, :presentation},
              interpreter: {__MODULE__, :interpret}
            }),
          else: binding

      effective = %{entry | settings: Keyword.put(entry.settings, :confirm, confirm?)}
      validate_override!(effective, override)
      {operation, Map.merge(binding, Map.drop(override, [:candidate, :presentation]))}
    end)
  end

  @doc false
  @spec candidate(map(), GAM.Mind.Turn.t(), map()) :: {:ok, map()} | {:error, term()}
  def candidate(args, turn, context) do
    with {:ok, expected} <- standard_candidate(args, turn, context) do
      callback = override(context.managed.options, context.managed_operation)[:candidate]
      custom_candidate(callback, expected, args, turn, context)
    end
  end

  @spec custom_candidate(nil | {module(), atom()}, map(), map(), GAM.Mind.Turn.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defp custom_candidate(nil, expected, _args, _turn, _context), do: {:ok, expected}

  defp custom_candidate({module, function}, expected, args, turn, context) do
    context = context |> application_context() |> Map.put(:candidate_template, expected)

    with {:ok, supplied} <- apply(module, function, [args, turn, context]),
         {:ok, supplied} <- GAM.Candidate.new(supplied),
         {:ok, expected} <- GAM.Candidate.new(expected),
         :ok <- matching_envelope(supplied, expected) do
      {:ok, supplied}
    end
  end

  @spec matching_envelope(GAM.Candidate.t(), GAM.Candidate.t()) :: :ok | {:error, atom()}
  defp matching_envelope(supplied, expected) do
    fields = [
      :identity_key,
      :class,
      :consequence,
      :row,
      :requested_mandate_ref,
      :proposer_ref,
      :executor_ref,
      :accountable_ref,
      :scope_ref,
      :subject_refs,
      :target_refs,
      :purpose_ref,
      :purpose_params,
      :executor_contract_ref,
      :consent,
      :disclosure,
      :meter_requests,
      :observation_window_ms,
      :presentation_ref
    ]

    if Map.take(supplied, fields) == Map.take(expected, fields) and
         expected.evidence_refs -- supplied.evidence_refs == [],
       do: :ok,
       else: {:error, :managed_candidate_envelope_changed}
  end

  @spec standard_candidate(map(), GAM.Mind.Turn.t(), map()) :: {:ok, map()} | {:error, term()}
  defp standard_candidate(args, turn, context) do
    host = context.managed
    entry = host.effects[context.managed_operation]

    with %{effect: effect} <- entry,
         {:ok, actual} <-
           Effect.resolve(
             context.agent,
             context.managed_operation,
             context.proposal_metadata,
             context
           ),
         true <- actual.contract_ref == effect.contract_ref,
         true <- is_map(args) do
      refs = host.refs
      policy = frozen_policy(entry, context)

      consequence = %{
        "payload" => args,
        "subject_ref" => refs.subject,
        "target_ref" => refs.target,
        "destination_ref" => refs.target,
        "effect_contract_ref" => effect.contract_ref,
        "execution_identity" =>
          context.identity
          |> Map.new(fn {key, value} -> {to_string(key), value} end),
        "execution_context" => execution_context(context),
        "managed_policy" => Map.new(policy, fn {key, value} -> {to_string(key), value} end),
        "bound" => Map.get(policy, :bind, %{})
      }

      with {:ok, consequence} <-
             Content.protect_consequence(
               host.options[:payload_store],
               consequence,
               host.refs.domain,
               context.command_id
             ) do
        {:ok, digest} = GAM.Consent.data_digest(consequence)
        evidence = Turn.evidence_refs(turn)

        {:ok,
         %{
           identity_key: "spectre:managed:" <> context.command_id,
           class: entry.class,
           consequence: consequence,
           row: host.row,
           requested_mandate_ref: host.mandate.ref,
           proposer_ref: refs.proposer,
           executor_ref: refs.executor,
           accountable_ref: refs.accountable,
           scope_ref: refs.scope,
           subject_refs: [refs.subject],
           target_refs: [refs.target],
           purpose_ref: refs.purpose,
           purpose_params: host.mandate.purpose_params,
           evidence_refs: evidence,
           disclosure: %{
             destination_refs: [refs.target],
             source_evidence_refs: evidence,
             labels: []
           },
           meter_requests: %{},
           executor_contract_ref: Executor.contract_ref(),
           observation_window_ms: 30_000,
           consent: %{
             schema_version: 1,
             recipient_refs: recipient_refs(host, entry),
             data_digest: digest,
             cost: 0,
             purpose_ref: refs.purpose,
             purpose_params: host.mandate.purpose_params,
             risk: "Application effect",
             reversibility: false,
             alternatives: ["cancel"]
           }
         }}
      end
    else
      false -> {:error, :managed_effect_contract_mismatch}
      {:error, _} = error -> error
      _ -> {:error, :managed_operation_unavailable}
    end
  end

  @doc false
  @spec presentation(GAM.Candidate.t(), map(), keyword()) ::
          {:ok, GAM.Presentation.t(), map()} | {:error, term()}
  def presentation(candidate, context, opts) do
    callback = override(context.managed.options, context.managed_operation)[:presentation]

    with {:ok, expected, show} <- standard_presentation(candidate, context),
         {:ok, presentation, show} <-
           custom_presentation(callback, candidate, context, opts, expected, show),
         {:ok, presentation} <-
           Content.presentation(
             context.managed.options[:payload_store],
             presentation,
             context.managed.refs.domain
           ),
         :ok <-
           prepare_approval(
             context.managed,
             context.managed.effects[context.managed_operation],
             presentation,
             context
           ) do
      {:ok, presentation, show}
    end
  end

  @spec standard_presentation(GAM.Candidate.t(), map()) ::
          {:ok, GAM.Presentation.t(), map()} | {:error, term()}
  defp standard_presentation(candidate, context) do
    host = context.managed
    entry = host.effects[context.managed_operation]

    with {:ok, material} <-
           Content.consequence(
             host.options[:payload_store],
             candidate.consequence,
             host.refs.domain
           ) do
      message =
        Map.get(
          context.managed_policy,
          :message,
          Keyword.get(entry.settings, :message, "Confermare questa operazione?")
        )

      rendered =
        "Operation: " <>
          Material.render(context.managed_operation) <>
          "\n" <>
          Material.render(message) <>
          "\n\n" <>
          Material.render(material["payload"])

      rendered =
        if material["bound"] == %{},
          do: rendered,
          else: rendered <> "\n" <> Material.render(material["bound"])

      consent = candidate.consent

      with {:ok, presentation} <-
             GAM.Presentation.new(%{
               candidate_binding_ref: GAM.Candidate.presentation_binding_ref(candidate),
               scope_ref: candidate.scope_ref,
               recipient_refs: consent["recipient_refs"],
               approval_source_refs: [Ingress.ref()],
               data: candidate.consequence,
               cost: 0,
               purpose_ref: candidate.purpose_ref,
               purpose_params: candidate.purpose_params,
               risk: consent["risk"],
               reversibility: false,
               alternatives: consent["alternatives"],
               renderer_ref: "spectre:managed:consumer:v1",
               rendered_payload: rendered,
               prepared_at: System.system_time(:millisecond)
             }) do
        {:ok, presentation,
         %{
           identity_key: "spectre:managed:show:" <> context.command_id,
           requested_mandate_ref: show_mandate(host, entry).ref,
           executor_ref: host.refs.executor,
           executor_contract_ref: host.refs.contract,
           accountable_ref: host.refs.accountable,
           subject_refs: candidate.subject_refs,
           evidence_refs: candidate.evidence_refs,
           observation_window_ms: 30_000
         }}
      end
    end
  end

  defp recipient_refs(host, entry) do
    case Approval.approver(host.options, entry.settings) do
      {:ok, nil} -> [host.refs.proposer]
      {:ok, {_, trust}} -> [trust.principal.ref]
    end
  end

  defp show_mandate(host, entry) do
    case Approval.approver(host.options, entry.settings) do
      {:ok, nil} -> host.mandate
      {:ok, _} -> host.show_mandate
    end
  end

  defp prepare_approval(host, entry, presentation, context) do
    case Approval.approver(host.options, entry.settings) do
      {:ok, nil} ->
        :ok

      {:ok, approver} ->
        with {:ok, material} <-
               Content.shown(
                 host.options[:payload_store],
                 %{"rendered_payload" => presentation.rendered_payload},
                 host.refs.domain
               ) do
          presentation = %{presentation | rendered_payload: material["rendered_payload"]}

          Gate.prepare_external(
            host.gate,
            presentation,
            approver,
            context.consent_expires_at,
            Map.get(context, :managed_revision, 1),
            Map.get(context, :skill)
          )
        end
    end
  end

  @spec custom_presentation(
          nil | {module(), atom()},
          GAM.Candidate.t(),
          map(),
          keyword(),
          GAM.Presentation.t(),
          map()
        ) :: {:ok, GAM.Presentation.t(), map()} | {:error, term()}
  defp custom_presentation(nil, _candidate, _context, _opts, expected, show),
    do: {:ok, expected, show}

  defp custom_presentation({module, function}, candidate, context, opts, expected, show) do
    public =
      context
      |> application_context()
      |> Map.put(:presentation_template, expected)
      |> Map.put(:show_template, show)

    with {:ok, supplied, supplied_show} <- apply(module, function, [candidate, public, opts]),
         {:ok, supplied} <- GAM.Presentation.new(supplied),
         true <- matching_presentation?(supplied, expected) and supplied_show == show,
         {:ok, rendered} <- retain_material(supplied, expected) do
      {:ok, rendered, show}
    else
      false -> {:error, :managed_presentation_envelope_changed}
      {:error, _} = error -> error
    end
  end

  @spec matching_presentation?(GAM.Presentation.t(), GAM.Presentation.t()) :: boolean()
  defp matching_presentation?(supplied, expected) do
    GAM.Presentation.material(supplied) == GAM.Presentation.material(expected) and
      supplied.renderer_ref == expected.renderer_ref and
      supplied.prepared_at == expected.prepared_at
  end

  @spec retain_material(GAM.Presentation.t(), GAM.Presentation.t()) ::
          {:ok, GAM.Presentation.t()} | {:error, term()}
  defp retain_material(%{rendered_payload: payload}, %{rendered_payload: payload} = expected),
    do: {:ok, expected}

  defp retain_material(supplied, expected) do
    expected
    |> Map.from_struct()
    |> Map.drop([:ref, :material_digest, :rendered_payload_ref])
    |> Map.put(
      :rendered_payload,
      Material.render(supplied.rendered_payload) <> "\n\n" <> expected.rendered_payload
    )
    |> GAM.Presentation.new()
  end

  @doc false
  @spec interpret(Spectre.Input.t(), GAM.Presentation.t()) :: :confirm | :reject | :unclear
  def interpret(%Spectre.Input{text: text}, _) do
    case String.downcase(String.trim(text)) do
      value when value in ["confermo", "confirm", "yes", "si", "sì"] -> :confirm
      value when value in ["annulla", "cancel", "no"] -> :reject
      _ -> :unclear
    end
  end

  @spec validate_override!(map(), term()) :: :ok
  defp validate_override!(entry, override) when is_map(override) and not is_struct(override) do
    if Map.keys(override) -- [:candidate, :presentation, :interpreter, :schema_hash] != [],
      do: invalid!("unknown binding field")

    Enum.each([candidate: 3, presentation: 3, interpreter: 2], fn {name, arity} ->
      if Map.has_key?(override, name), do: validate_callback!(Map.fetch!(override, name), arity)
    end)

    if Map.has_key?(override, :schema_hash) and override.schema_hash != entry.effect.schema_hash,
      do: invalid!("schema override must match the registered effect")

    :ok
  end

  defp validate_override!(_, _), do: invalid!("operation binding must be a plain map")

  @spec validate_callback!(term(), pos_integer()) :: :ok
  defp validate_callback!({module, function}, arity)
       when is_atom(module) and is_atom(function) do
    if not Code.ensure_loaded?(module) or not function_exported?(module, function, arity),
      do: invalid!("binding callback is unavailable")

    :ok
  end

  defp validate_callback!(_, _), do: invalid!("binding callback must be an explicit MFA pair")

  @spec frozen_skill(map() | nil) :: map() | nil
  defp frozen_skill(skill) when is_map(skill), do: Map.take(skill, [:id, :module])
  defp frozen_skill(_), do: nil

  @spec frozen_policy(map(), map()) :: map()
  defp frozen_policy(entry, context) do
    override = override(context.managed.options, context.managed_operation)

    if Keyword.get(entry.settings, :confirm, false) or not is_nil(override[:presentation]),
      do: Map.put(context.managed_policy, :confirm, true),
      else: context.managed_policy
  end

  defp override(options, operation),
    do: options |> Keyword.get(:bindings, %{}) |> Map.get(operation, %{})

  @spec application_context(map()) :: map()
  defp application_context(context) do
    context
    |> Map.take([
      :agent,
      :server,
      :skill,
      :activity,
      :assigns,
      :input,
      :interaction,
      :received_at,
      :event_sequence,
      :routing,
      :history,
      :memory,
      :current_flow,
      :current_scope,
      :command_id,
      :proposal_metadata
    ])
    |> Map.put(:identity, context.identity)
    |> Map.put(
      :options,
      Keyword.take(context.options, [:namespace, :prompt_root, :runtime_scope])
    )
  end

  defp execution_context(context) do
    frozen = %{
      "current_flow" => Map.get(context, :current_flow),
      "current_scope" => Map.get(context, :current_scope),
      "skill" => frozen_skill(Map.get(context, :skill)),
      "namespace" => Keyword.get(context.options, :namespace)
    }

    case context[:activity] do
      %{ref: ref, revision: revision} ->
        Map.put(frozen, "activity", %{"ref" => ref, "revision" => revision})

      nil ->
        frozen
    end
  end

  @spec invalid!(binary()) :: no_return()
  defp invalid!(reason), do: raise(ArgumentError, "invalid managed GAM binding: #{reason}")
end
