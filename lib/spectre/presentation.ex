defmodule Spectre.Presentation do
  @moduledoc """
  Immutable material prepared for a later, governed consent request.

  A Presentation records what may be shown; recording it does not claim that
  anybody saw it. Delivery is the closed `presentation.show` consequence and
  must cross the normal Candidate -> Act -> Attempt -> Outcome boundary.

  `candidate_binding_ref` addresses the final Candidate's acyclic pre-consent
  material. The final Candidate may therefore add this Presentation and the
  later approval Evidence without creating a reference cycle.

  Approval is observed Evidence for the exact Presentation and the exact
  successful show Act. Its source must be one of `approval_source_refs`, and
  its authenticated issuer must be one of the declared recipients.
  """

  alias Spectre.{Act, Consent, Disclosure, Evidence, Ingress, Outcome, Portable, Row}
  alias Spectre.SubmissionContext

  @schema_version 1
  @show_class "presentation.show"
  @show_dimensions [:attempt, :disclose, :present]
  @approval_contract_ref "spectre.presentation.approval.v1"
  @response_evidence_fields [
    :ref,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :assumptions,
    :labels,
    :payload,
    :payload_ref
  ]
  @fields [
    :schema_version,
    :ref,
    :candidate_binding_ref,
    :scope_ref,
    :recipient_refs,
    :approval_source_refs,
    :disclosure,
    :data,
    :cost,
    :purpose_ref,
    :purpose_params,
    :risk,
    :reversibility,
    :alternatives,
    :renderer_ref,
    :rendered_payload,
    :rendered_payload_ref,
    :prepared_at,
    :material_digest
  ]

  @enforce_keys [
    :schema_version,
    :ref,
    :candidate_binding_ref,
    :scope_ref,
    :recipient_refs,
    :approval_source_refs,
    :disclosure,
    :data,
    :cost,
    :purpose_ref,
    :purpose_params,
    :risk,
    :reversibility,
    :alternatives,
    :renderer_ref,
    :prepared_at,
    :material_digest
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            candidate_binding_ref: nil,
            scope_ref: nil,
            recipient_refs: [],
            approval_source_refs: [],
            disclosure: nil,
            data: nil,
            cost: nil,
            purpose_ref: nil,
            purpose_params: %{},
            risk: nil,
            reversibility: nil,
            alternatives: [],
            renderer_ref: nil,
            rendered_payload: nil,
            rendered_payload_ref: nil,
            prepared_at: nil,
            material_digest: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          candidate_binding_ref: String.t(),
          scope_ref: String.t(),
          recipient_refs: [String.t()],
          approval_source_refs: [String.t()],
          disclosure: Disclosure.t(),
          data: term(),
          cost: term(),
          purpose_ref: String.t(),
          purpose_params: map(),
          risk: term(),
          reversibility: term(),
          alternatives: [term()],
          renderer_ref: String.t(),
          rendered_payload: term(),
          rendered_payload_ref: String.t() | nil,
          prepared_at: integer(),
          material_digest: String.t()
        }

  @doc "Builds and validates prepared consent material."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = presentation), do: presentation |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :presentation),
         attrs <- defaults(attrs),
         {:ok, recipients} <-
           Portable.normalize_refs(Map.fetch!(attrs, :recipient_refs), :recipient_refs),
         {:ok, approval_sources} <-
           Portable.normalize_refs(
             Map.fetch!(attrs, :approval_source_refs),
             :approval_source_refs
           ),
         attrs =
           attrs
           |> Map.put(:recipient_refs, recipients)
           |> Map.put(:approval_source_refs, approval_sources),
         {:ok, disclosure} <- disclosure(attrs, recipients),
         attrs = Map.put(attrs, :disclosure, disclosure),
         {:ok, expected_digest} <- Portable.digest(material_attrs(attrs)),
         :ok <- verify_digest(Map.get(attrs, :material_digest), expected_digest),
         attrs = Map.put(attrs, :material_digest, expected_digest),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         presentation = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(presentation),
         :ok <- Portable.validate(canonical(presentation)) do
      {:ok, presentation}
    end
  end

  @doc "Returns the fields whose exact value is material to consent."
  @spec material(t()) :: map()
  def material(%__MODULE__{} = presentation) do
    %{
      "candidate_binding_ref" => presentation.candidate_binding_ref,
      "scope_ref" => presentation.scope_ref,
      "recipient_refs" => presentation.recipient_refs,
      "approval_source_refs" => presentation.approval_source_refs,
      "disclosure" => Disclosure.canonical(presentation.disclosure),
      "data" => presentation.data,
      "cost" => presentation.cost,
      "purpose_ref" => presentation.purpose_ref,
      "purpose_params" => presentation.purpose_params,
      "risk" => presentation.risk,
      "reversibility" => presentation.reversibility,
      "alternatives" => presentation.alternatives
    }
  end

  @doc "Recalculates the closed consent material represented by this Presentation."
  @spec consent_material(t()) :: {:ok, Consent.t()} | {:error, term()}
  def consent_material(%__MODULE__{} = presentation) do
    with {:ok, data_digest} <- Consent.data_digest(presentation.data) do
      Consent.new(%{
        schema_version: 1,
        recipient_refs: presentation.recipient_refs,
        data_digest: data_digest,
        cost: presentation.cost,
        purpose_ref: presentation.purpose_ref,
        purpose_params: presentation.purpose_params,
        risk: presentation.risk,
        reversibility: presentation.reversibility,
        alternatives: presentation.alternatives
      })
    end
  end

  @doc "Validates every consent field against one current Candidate-like record."
  @spec validate_candidate(map(), t()) :: :ok | {:error, term()}
  def validate_candidate(candidate, %__MODULE__{} = presentation) when is_map(candidate) do
    with {:ok, candidate_consent} <- Consent.new(field(candidate, :consent)),
         :ok <-
           Consent.validate_purpose(
             candidate_consent,
             field(candidate, :purpose_ref),
             field(candidate, :purpose_params)
           ),
         {:ok, presented_consent} <- consent_material(presentation) do
      cond do
        field(candidate, :scope_ref) != presentation.scope_ref ->
          {:error, :presentation_scope_mismatch}

        candidate_consent != presented_consent ->
          {:error, :presentation_consent_material_mismatch}

        true ->
          :ok
      end
    else
      {:error, reason} -> {:error, {:invalid_presentation_consent_material, reason}}
    end
  end

  def validate_candidate(_candidate, %__MODULE__{}),
    do: {:error, :invalid_presentation_candidate}

  @doc "Returns the one reserved class used to show prepared material."
  @spec show_class() :: String.t()
  def show_class, do: @show_class

  @doc "Returns the exact Row dimensions of `presentation.show`."
  @spec show_dimensions() :: [Row.dimension()]
  def show_dimensions, do: @show_dimensions

  @doc "Returns the exact Row of `presentation.show`."
  @spec show_row() :: Row.t()
  def show_row, do: %Row{attempt: true, disclose: true, present: true}

  @doc "Returns the exact executor-facing consequence for this Presentation."
  @spec show_consequence(t()) :: map()
  def show_consequence(%__MODULE__{} = presentation) do
    %{
      "presentation_show" => %{
        "presentation_ref" => presentation.ref,
        "scope_ref" => presentation.scope_ref,
        "recipient_refs" => presentation.recipient_refs,
        "material_digest" => presentation.material_digest,
        "renderer_ref" => presentation.renderer_ref,
        "rendered_payload" => presentation.rendered_payload,
        "rendered_payload_ref" => presentation.rendered_payload_ref,
        "disclosure" => Disclosure.canonical(presentation.disclosure)
      }
    }
  end

  @doc "Extracts a Presentation ref only from the closed show consequence."
  @spec show_presentation_ref(term()) :: {:ok, String.t()} | {:error, term()}
  def show_presentation_ref(
        %{
          "presentation_show" =>
            %{
              "presentation_ref" => presentation_ref,
              "scope_ref" => _scope_ref,
              "recipient_refs" => _recipient_refs,
              "material_digest" => _material_digest,
              "renderer_ref" => _renderer_ref,
              "rendered_payload" => _rendered_payload,
              "rendered_payload_ref" => _rendered_payload_ref,
              "disclosure" => _disclosure
            } = show
        } = consequence
      )
      when map_size(consequence) == 1 and map_size(show) == 8 and is_binary(presentation_ref) and
             presentation_ref != "" do
    {:ok, presentation_ref}
  end

  def show_presentation_ref(_consequence), do: {:error, :invalid_presentation_show_consequence}

  @doc "Validates the closed show semantics shared by a Candidate and its Act."
  @spec validate_show(map(), t()) :: :ok | {:error, term()}
  def validate_show(record, %__MODULE__{} = presentation) when is_map(record) do
    cond do
      field(record, :class) != @show_class ->
        {:error, :presentation_show_class_mismatch}

      not exact_show_row?(field(record, :row)) ->
        {:error, :presentation_show_row_mismatch}

      field(record, :consequence) != show_consequence(presentation) ->
        {:error, :presentation_show_consequence_mismatch}

      not is_nil(field(record, :presentation_ref)) ->
        {:error, :presentation_show_cannot_require_approval}

      field(record, :scope_ref) != presentation.scope_ref ->
        {:error, :presentation_show_scope_mismatch}

      field(record, :target_refs) != presentation.recipient_refs ->
        {:error, :presentation_show_recipients_mismatch}

      field(record, :disclosure) != presentation.disclosure ->
        {:error, :presentation_show_disclosure_mismatch}

      field(record, :purpose_ref) != presentation.purpose_ref or
          field(record, :purpose_params) != presentation.purpose_params ->
        {:error, :presentation_show_purpose_mismatch}

      true ->
        :ok
    end
  end

  def validate_show(_record, %__MODULE__{}), do: {:error, :invalid_presentation_show}

  @doc "Returns the closed proposition approving one successful show Act."
  @spec approval_proposition(String.t(), String.t()) :: map()
  def approval_proposition(presentation_ref, show_act_ref)
      when is_binary(presentation_ref) and presentation_ref != "" and is_binary(show_act_ref) and
             show_act_ref != "" do
    %{
      "contract_ref" => @approval_contract_ref,
      "presentation_ref" => presentation_ref,
      "show_act_ref" => show_act_ref
    }
  end

  @doc "Builds an authenticated supporting or contradicting response to one exact show Act."
  @spec response_evidence(
          SubmissionContext.t(),
          t(),
          Act.t(),
          Evidence.stance(),
          integer(),
          map() | keyword()
        ) :: {:ok, Evidence.t()} | {:error, term()}
  def response_evidence(
        %SubmissionContext{} = context,
        %__MODULE__{} = presentation,
        %Act{} = show_act,
        stance,
        observed_at,
        attrs
      )
      when stance in [:supports, :contradicts] and is_integer(observed_at) do
    with {:ok, context} <- SubmissionContext.new(context),
         {:ok, presentation} <- new(presentation),
         {:ok, show_act} <- Act.new(show_act),
         :ok <- response_context(context, presentation, show_act, observed_at),
         {:ok, attrs} <-
           Portable.normalize_attrs(
             attrs,
             @response_evidence_fields,
             :presentation_response_evidence
           ) do
      attrs
      |> Map.merge(%{
        proposition: approval_proposition(presentation.ref, show_act.ref),
        stance: stance,
        issuer_ref: context.authenticated_principal_ref,
        bindings: %{
          "presentation_ref" => presentation.ref,
          "show_act_ref" => show_act.ref,
          "recipient_ref" => context.authenticated_principal_ref
        },
        provisional: false
      })
      |> then(&Ingress.evidence(context, observed_at, &1))
    end
  end

  def response_evidence(
        _context,
        _presentation,
        _show_act,
        _stance,
        _observed_at,
        _attrs
      ),
      do: {:error, :invalid_presentation_response_evidence}

  @doc "Classifies a reserved approval proposition and rejects non-canonical variants."
  @spec approval_refs(Evidence.t()) ::
          :not_approval | {:ok, String.t(), String.t()} | {:error, term()}
  def approval_refs(%Evidence{proposition: proposition}) when is_map(proposition) do
    if field(proposition, :contract_ref) == @approval_contract_ref do
      presentation_ref = field(proposition, :presentation_ref)
      show_act_ref = field(proposition, :show_act_ref)

      if valid_ref?(presentation_ref) and valid_ref?(show_act_ref) and
           proposition == approval_proposition(presentation_ref, show_act_ref) do
        {:ok, presentation_ref, show_act_ref}
      else
        {:error, :noncanonical_presentation_approval_proposition}
      end
    else
      :not_approval
    end
  end

  def approval_refs(%Evidence{}), do: :not_approval

  @doc "Validates one approval against its prepared material and successful show."
  @spec validate_approval(
          Evidence.t(),
          t(),
          map(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: :ok | {:error, term()}
  def validate_approval(
        %Evidence{} = approval,
        %__MODULE__{} = presentation,
        show_act,
        outcomes,
        evidence,
        time
      )
      when is_map(show_act) and is_list(outcomes) and is_list(evidence) and is_integer(time) do
    with {:ok, _basis_refs} <-
           validate_approval_with_basis(
             approval,
             presentation,
             show_act,
             outcomes,
             evidence,
             time
           ) do
      :ok
    end
  end

  def validate_approval(_approval, _presentation, _show_act, _outcomes, _evidence, _time),
    do: {:error, :invalid_presentation_approval}

  @doc "Validates either a supporting approval or a contradicting response with its basis."
  @spec validate_response_with_basis(
          Evidence.t(),
          t(),
          map(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def validate_response_with_basis(
        %Evidence{stance: stance} = response,
        %__MODULE__{} = presentation,
        show_act,
        outcomes,
        evidence,
        time
      )
      when stance in [:supports, :contradicts] and is_map(show_act) and is_list(outcomes) and
             is_list(evidence) and is_integer(time) do
    validate_approval_evidence_with_basis(
      response,
      stance,
      presentation,
      show_act,
      outcomes,
      evidence,
      time
    )
  end

  def validate_response_with_basis(
        _response,
        _presentation,
        _show_act,
        _outcomes,
        _evidence,
        _time
      ),
      do: {:error, :invalid_presentation_response}

  @doc "Validates an approval and returns its exact Evidence basis."
  @spec validate_approval_with_basis(
          Evidence.t(),
          t(),
          map(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def validate_approval_with_basis(
        %Evidence{} = approval,
        %__MODULE__{} = presentation,
        show_act,
        outcomes,
        evidence,
        time
      )
      when is_map(show_act) and is_list(outcomes) and is_list(evidence) and is_integer(time) do
    validate_approval_evidence_with_basis(
      approval,
      :supports,
      presentation,
      show_act,
      outcomes,
      evidence,
      time
    )
  end

  def validate_approval_with_basis(
        _approval,
        _presentation,
        _show_act,
        _outcomes,
        _evidence,
        _time
      ),
      do: {:error, :invalid_presentation_approval}

  @doc false
  @spec validate_approval_contradiction_with_basis(
          Evidence.t(),
          t(),
          map(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def validate_approval_contradiction_with_basis(
        %Evidence{} = approval,
        %__MODULE__{} = presentation,
        show_act,
        outcomes,
        evidence,
        time
      )
      when is_map(show_act) and is_list(outcomes) and is_list(evidence) and is_integer(time) do
    validate_approval_evidence_with_basis(
      approval,
      :contradicts,
      presentation,
      show_act,
      outcomes,
      evidence,
      time
    )
  end

  def validate_approval_contradiction_with_basis(
        _approval,
        _presentation,
        _show_act,
        _outcomes,
        _evidence,
        _time
      ),
      do: {:error, :invalid_presentation_approval_contradiction}

  defp validate_approval_evidence_with_basis(
         approval,
         stance,
         presentation,
         show_act,
         outcomes,
         evidence,
         time
       ) do
    with {:ok, presentation_ref, show_act_ref} <- approval_refs(approval),
         true <- approval.stance == stance,
         true <- presentation_ref == presentation.ref,
         true <- show_act_ref == field(show_act, :ref),
         :ok <- validate_show(show_act, presentation),
         :ok <- validate_approval_identity(approval, presentation, show_act_ref),
         :ok <- current_observation(approval, time),
         :ok <- successful_show_precedes_approval(approval, show_act, outcomes, time),
         {:ok, assumption_refs} <- recognized_assumptions(approval, presentation, evidence, time) do
      {:ok, normalize_basis_refs([approval.ref | assumption_refs])}
    else
      false -> {:error, :presentation_approval_stance_or_binding_mismatch}
      :not_approval -> {:error, :not_presentation_approval}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec validate_assumption_contradiction_with_basis(
          Evidence.t(),
          Evidence.t(),
          t(),
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def validate_assumption_contradiction_with_basis(
        %Evidence{} = item,
        %Evidence{} = approval,
        %__MODULE__{} = presentation,
        evidence,
        time
      )
      when is_list(evidence) and is_integer(time) do
    with true <- item.stance == :contradicts,
         true <- valid_assumption_identity?(item, approval, presentation),
         true <- current_assumption?(item, time, time),
         {:ok, basis_refs} <-
           qualified_evidence_basis(
             item,
             approval,
             presentation,
             evidence,
             time,
             MapSet.new([approval.ref, item.ref]),
             time
           ) do
      {:ok, basis_refs}
    else
      false -> {:error, :presentation_assumption_evidence_not_current}
      {:error, _reason} = error -> error
    end
  end

  def validate_assumption_contradiction_with_basis(
        _item,
        _approval,
        _presentation,
        _evidence,
        _time
      ),
      do: {:error, :invalid_presentation_assumption_evidence}

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = presentation) do
    Map.merge(material(presentation), %{
      "schema_version" => presentation.schema_version,
      "ref" => presentation.ref,
      "renderer_ref" => presentation.renderer_ref,
      "rendered_payload" => presentation.rendered_payload,
      "rendered_payload_ref" => presentation.rendered_payload_ref,
      "prepared_at" => presentation.prepared_at,
      "material_digest" => presentation.material_digest
    })
  end

  @doc "Restores a presentation from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :presentation)

  @doc "Returns the stable digest of the complete presentation."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = presentation),
    do: presentation |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = presentation),
    do: Portable.content_ref!(:presentation, content(presentation))

  defp material_attrs(attrs) do
    %{
      "candidate_binding_ref" => Map.get(attrs, :candidate_binding_ref),
      "scope_ref" => Map.get(attrs, :scope_ref),
      "recipient_refs" => Map.fetch!(attrs, :recipient_refs),
      "approval_source_refs" => Map.fetch!(attrs, :approval_source_refs),
      "disclosure" => attrs |> Map.fetch!(:disclosure) |> Disclosure.canonical(),
      "data" => Map.get(attrs, :data),
      "cost" => Map.get(attrs, :cost),
      "purpose_ref" => Map.get(attrs, :purpose_ref),
      "purpose_params" => Map.fetch!(attrs, :purpose_params),
      "risk" => Map.get(attrs, :risk),
      "reversibility" => Map.get(attrs, :reversibility),
      "alternatives" => Map.fetch!(attrs, :alternatives)
    }
  end

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:recipient_refs, [])
    |> Map.put_new(:approval_source_refs, [])
    |> Map.put_new(:disclosure, nil)
    |> Map.put_new(:purpose_params, %{})
    |> Map.put_new(:alternatives, [])
    |> Map.put_new(:rendered_payload, nil)
    |> Map.put_new(:rendered_payload_ref, nil)
  end

  defp disclosure(%{disclosure: nil}, recipients) do
    Disclosure.new(%{
      destination_refs: recipients,
      source_evidence_refs: [],
      labels: []
    })
  end

  defp disclosure(attrs, _recipients), do: Disclosure.new(Map.fetch!(attrs, :disclosure))

  defp verify_digest(nil, _expected), do: :ok
  defp verify_digest(expected, expected), do: :ok

  defp verify_digest(value, expected),
    do: {:error, {:presentation_material_digest_mismatch, value, expected}}

  defp resolve_ref(ref, attrs),
    do: Portable.resolve_content_ref(:presentation, ref, content(attrs))

  defp content(%__MODULE__{} = presentation), do: presentation |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    material_attrs(attrs)
    |> Map.merge(%{
      "schema_version" => Map.fetch!(attrs, :schema_version),
      "renderer_ref" => Map.get(attrs, :renderer_ref),
      "rendered_payload" => Map.fetch!(attrs, :rendered_payload),
      "rendered_payload_ref" => Map.fetch!(attrs, :rendered_payload_ref),
      "prepared_at" => Map.get(attrs, :prepared_at),
      "material_digest" => Map.fetch!(attrs, :material_digest)
    })
  end

  defp validate_record(%__MODULE__{} = presentation) do
    cond do
      presentation.schema_version != @schema_version ->
        {:error, {:unsupported_presentation_schema_version, presentation.schema_version}}

      presentation.recipient_refs == [] ->
        {:error, :missing_presentation_recipients}

      presentation.approval_source_refs == [] ->
        {:error, :missing_presentation_approval_sources}

      presentation.disclosure.destination_refs != presentation.recipient_refs ->
        {:error, :presentation_disclosure_recipients_mismatch}

      not is_map(presentation.purpose_params) or is_struct(presentation.purpose_params) ->
        {:error,
         {:invalid_presentation_purpose_params, Portable.shape(presentation.purpose_params)}}

      not is_list(presentation.alternatives) ->
        {:error, {:invalid_presentation_alternatives, Portable.shape(presentation.alternatives)}}

      not is_integer(presentation.prepared_at) ->
        {:error, {:invalid_presentation_prepared_at, presentation.prepared_at}}

      is_nil(presentation.rendered_payload) and is_nil(presentation.rendered_payload_ref) ->
        {:error, :missing_presentation_rendered_payload_or_ref}

      not is_nil(presentation.rendered_payload) and
          not is_nil(presentation.rendered_payload_ref) ->
        {:error, :presentation_rendered_payload_and_ref_are_mutually_exclusive}

      true ->
        with :ok <- Portable.validate_ref(presentation.ref, :ref),
             :ok <-
               Portable.validate_ref(
                 presentation.candidate_binding_ref,
                 :candidate_binding_ref
               ),
             :ok <- Portable.validate_ref(presentation.scope_ref, :scope_ref),
             :ok <- Portable.validate_refs(presentation.recipient_refs, :recipient_refs),
             :ok <-
               Portable.validate_refs(
                 presentation.approval_source_refs,
                 :approval_source_refs
               ),
             :ok <- Portable.validate_ref(presentation.purpose_ref, :purpose_ref),
             :ok <- Portable.validate_ref(presentation.renderer_ref, :renderer_ref),
             :ok <- validate_optional_payload_ref(presentation.rendered_payload_ref),
             {:ok, _consent} <- consent_material(presentation),
             :ok <-
               Portable.validate_non_empty_binary(presentation.material_digest, :material_digest) do
          :ok
        end
    end
  end

  defp exact_show_row?(%Row{} = row), do: Row.dimensions(row) == @show_dimensions
  defp exact_show_row?(_row), do: false

  defp validate_approval_identity(approval, presentation, show_act_ref) do
    recipient_ref = field(approval.bindings, :recipient_ref)
    authenticated_ref = field(approval.bindings, :authenticated_principal_ref)

    cond do
      approval.provenance != :observed or approval.provisional ->
        {:error, :presentation_approval_not_final_observation}

      approval.parent_refs != [] ->
        {:error, :presentation_approval_has_parents}

      approval.source_ref not in presentation.approval_source_refs ->
        {:error, :presentation_approval_source_not_configured}

      is_nil(approval.issuer_ref) or approval.issuer_ref != recipient_ref or
          approval.issuer_ref != authenticated_ref ->
        {:error, :presentation_approval_principal_mismatch}

      recipient_ref not in presentation.recipient_refs ->
        {:error, :presentation_approval_recipient_mismatch}

      field(approval.bindings, :presentation_ref) != presentation.ref or
          field(approval.bindings, :show_act_ref) != show_act_ref ->
        {:error, :presentation_approval_binding_mismatch}

      not valid_ref?(field(approval.bindings, :scope_ref)) or
          not valid_ref?(field(approval.bindings, :authentication_ref)) ->
        {:error, :presentation_approval_authentication_missing}

      true ->
        :ok
    end
  end

  defp response_context(context, presentation, show_act, observed_at) do
    cond do
      context.scope_ref != presentation.scope_ref ->
        {:error, :presentation_response_scope_mismatch}

      context.authenticated_principal_ref not in presentation.recipient_refs ->
        {:error, :presentation_response_recipient_mismatch}

      context.ingress_ref not in presentation.approval_source_refs ->
        {:error, :presentation_response_source_not_configured}

      observed_at < show_act.committed_at ->
        {:error, :presentation_response_precedes_show_act}

      true ->
        validate_show(show_act, presentation)
    end
  end

  defp current_observation(evidence, time) do
    cond do
      evidence.observed_at > time ->
        {:error, :presentation_approval_from_future}

      not is_nil(evidence.valid_from) and evidence.valid_from > time ->
        {:error, :presentation_approval_not_yet_valid}

      not is_nil(evidence.valid_until) and time >= evidence.valid_until ->
        {:error, :presentation_approval_expired}

      not is_nil(evidence.freshness_ms) and time - evidence.observed_at > evidence.freshness_ms ->
        {:error, :presentation_approval_stale}

      true ->
        :ok
    end
  end

  defp successful_show_precedes_approval(approval, show_act, outcomes, _time) do
    eligible =
      Enum.filter(outcomes, fn
        %Outcome{} = outcome ->
          outcome.act_ref == field(show_act, :ref) and outcome.status == :succeeded and
            outcome.observed_at <= approval.observed_at

        _other ->
          false
      end)

    cond do
      field(show_act, :committed_at) > approval.observed_at ->
        {:error, :presentation_approval_precedes_show_act}

      eligible == [] ->
        {:error, :presentation_approval_precedes_successful_show}

      true ->
        :ok
    end
  end

  defp recognized_assumptions(%Evidence{assumptions: []}, _presentation, _evidence, _time),
    do: {:ok, []}

  defp recognized_assumptions(approval, presentation, evidence, time) do
    approval.assumptions
    |> Enum.reduce_while({:ok, []}, fn assumption, {:ok, refs} ->
      case assumption_basis(
             assumption,
             approval,
             presentation,
             evidence,
             time,
             MapSet.new([approval.ref]),
             approval.observed_at
           ) do
        {:ok, assumption_refs} ->
          {:cont, {:ok, assumption_refs ++ refs}}

        {:error, _reason} ->
          {:halt, {:error, {:unrecognized_presentation_approval_assumption, assumption}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, normalize_basis_refs(refs)}
      {:error, _reason} = error -> error
    end
  end

  defp assumption_basis(
         assumption,
         approval,
         presentation,
         evidence,
         time,
         visited,
         observed_by
       ) do
    supporting =
      assumption_evidence_bases(
        assumption,
        :supports,
        approval,
        presentation,
        evidence,
        time,
        visited,
        observed_by
      )

    contradicting =
      assumption_evidence_bases(
        assumption,
        :contradicts,
        approval,
        presentation,
        evidence,
        time,
        visited,
        time
      )

    cond do
      supporting == [] or contradicting != [] ->
        {:error, :assumption_not_supported}

      true ->
        {:ok, supporting |> List.flatten() |> normalize_basis_refs()}
    end
  end

  defp assumption_evidence_bases(
         assumption,
         stance,
         approval,
         presentation,
         evidence,
         time,
         visited,
         observed_by
       ) do
    evidence
    |> Enum.filter(fn
      %Evidence{} = item ->
        item.proposition == assumption and item.stance == stance and item.ref != approval.ref and
          not MapSet.member?(visited, item.ref) and
          valid_assumption_identity?(item, approval, presentation) and
          current_assumption?(item, time, observed_by)

      _other ->
        false
    end)
    |> Enum.sort_by(& &1.ref)
    |> Enum.reduce([], fn item, bases ->
      case qualified_evidence_basis(
             item,
             approval,
             presentation,
             evidence,
             time,
             MapSet.put(visited, item.ref),
             observed_by
           ) do
        {:ok, refs} -> [refs | bases]
        {:error, _reason} -> bases
      end
    end)
  end

  defp qualified_evidence_basis(
         item,
         approval,
         presentation,
         evidence,
         time,
         visited,
         observed_by
       ) do
    item.assumptions
    |> Enum.reduce_while({:ok, [item.ref]}, fn nested, {:ok, refs} ->
      case assumption_basis(
             nested,
             approval,
             presentation,
             evidence,
             time,
             visited,
             observed_by
           ) do
        {:ok, nested_refs} -> {:cont, {:ok, nested_refs ++ refs}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, normalize_basis_refs(refs)}
      {:error, _reason} = error -> error
    end
  end

  defp valid_assumption_identity?(item, approval, presentation) do
    item.provenance == :observed and not item.provisional and item.parent_refs == [] and
      item.source_ref in presentation.approval_source_refs and
      item.issuer_ref == approval.issuer_ref and
      field(item.bindings, :authenticated_principal_ref) == approval.issuer_ref
  end

  defp current_assumption?(item, time, observed_by) do
    item.observed_at <= observed_by and item.observed_at <= time and
      (is_nil(item.valid_from) or item.valid_from <= time) and
      (is_nil(item.valid_until) or time < item.valid_until) and
      (is_nil(item.freshness_ms) or time - item.observed_at <= item.freshness_ms)
  end

  defp normalize_basis_refs(refs), do: refs |> Enum.uniq() |> Enum.sort()

  defp valid_ref?(value), do: is_binary(value) and value != ""

  defp validate_optional_payload_ref(nil), do: :ok

  defp validate_optional_payload_ref(value),
    do: Portable.validate_content_ref(value, :payload, :rendered_payload_ref)

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_value, _key), do: nil
end
