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

  alias Spectre.{Act, Candidate, Consent, Disclosure, Evidence, Outcome, Portable, Row}
  alias Spectre.GovernedAct.Class, as: GovernedClass
  alias Spectre.Presentation.Approval

  @schema_version 1
  @show_class "presentation.show"
  @material_fields [
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
    :alternatives
  ]
  @delivery_fields [
    :renderer_ref,
    :rendered_payload,
    :rendered_payload_ref,
    :prepared_at,
    :material_digest
  ]
  @fields [:schema_version, :ref] ++ @material_fields ++ @delivery_fields

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
  def material(%__MODULE__{} = presentation), do: material_fields(presentation)

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
  @spec validate_candidate(Candidate.t(), t()) :: :ok | {:error, term()}
  def validate_candidate(%Candidate{} = candidate, %__MODULE__{} = presentation) do
    with {:ok, candidate_consent} <- Consent.new(candidate.consent),
         :ok <-
           Consent.validate_purpose(
             candidate_consent,
             candidate.purpose_ref,
             candidate.purpose_params
           ),
         {:ok, presented_consent} <- consent_material(presentation) do
      cond do
        candidate.scope_ref != presentation.scope_ref ->
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
  def show_dimensions do
    {:ok, dimensions} = GovernedClass.dimensions(@show_class)
    dimensions
  end

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
  @spec validate_show(Candidate.t() | Act.t(), t()) :: :ok | {:error, term()}
  def validate_show(%Candidate{} = record, %__MODULE__{} = presentation),
    do: validate_show_record(record, presentation)

  def validate_show(%Act{} = record, %__MODULE__{} = presentation),
    do: validate_show_record(record, presentation)

  def validate_show(_record, %__MODULE__{}), do: {:error, :invalid_presentation_show}

  defp validate_show_record(record, presentation) do
    cond do
      record.class != @show_class ->
        {:error, :presentation_show_class_mismatch}

      not exact_show_row?(record.row) ->
        {:error, :presentation_show_row_mismatch}

      record.consequence != show_consequence(presentation) ->
        {:error, :presentation_show_consequence_mismatch}

      not is_nil(record.presentation_ref) ->
        {:error, :presentation_show_cannot_require_approval}

      record.scope_ref != presentation.scope_ref ->
        {:error, :presentation_show_scope_mismatch}

      record.target_refs != presentation.recipient_refs ->
        {:error, :presentation_show_recipients_mismatch}

      record.disclosure != presentation.disclosure ->
        {:error, :presentation_show_disclosure_mismatch}

      record.purpose_ref != presentation.purpose_ref or
          record.purpose_params != presentation.purpose_params ->
        {:error, :presentation_show_purpose_mismatch}

      true ->
        :ok
    end
  end

  @doc "Returns the closed proposition approving one successful show Act."
  @spec approval_proposition(String.t(), String.t()) :: map()
  defdelegate approval_proposition(presentation_ref, show_act_ref), to: Approval, as: :proposition

  @doc "Builds an authenticated supporting or contradicting response to one exact show Act."
  @spec response_evidence(
          SubmissionContext.t(),
          t(),
          Act.t(),
          Evidence.stance(),
          integer(),
          map() | keyword()
        ) :: {:ok, Evidence.t()} | {:error, term()}
  defdelegate response_evidence(context, presentation, show_act, stance, observed_at, attrs),
    to: Approval

  @doc "Classifies a reserved approval proposition and rejects non-canonical variants."
  @spec approval_refs(Evidence.t()) ::
          :not_approval | {:ok, String.t(), String.t()} | {:error, term()}
  defdelegate approval_refs(evidence), to: Approval, as: :refs

  @doc "Validates one approval against its prepared material and successful show."
  @spec validate_approval(
          Evidence.t(),
          t(),
          map(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: :ok | {:error, term()}
  defdelegate validate_approval(approval, presentation, show_act, outcomes, evidence, time),
    to: Approval

  @doc "Validates either a supporting approval or a contradicting response with its basis."
  @spec validate_response_with_basis(
          Evidence.t(),
          t(),
          map(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate validate_response_with_basis(
                response,
                presentation,
                show_act,
                outcomes,
                evidence,
                time
              ),
              to: Approval

  @doc false
  defdelegate classify_responses(presentation, acts, outcomes, evidence, time), to: Approval

  @doc "Validates an approval and returns its exact Evidence basis."
  @spec validate_approval_with_basis(
          Evidence.t(),
          t(),
          map(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate validate_approval_with_basis(
                approval,
                presentation,
                show_act,
                outcomes,
                evidence,
                time
              ),
              to: Approval

  @doc false
  @spec validate_approval_contradiction_with_basis(
          Evidence.t(),
          t(),
          map(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate validate_approval_contradiction_with_basis(
                approval,
                presentation,
                show_act,
                outcomes,
                evidence,
                time
              ),
              to: Approval

  @doc false
  @spec validate_assumption_contradiction_with_basis(
          Evidence.t(),
          Evidence.t(),
          t(),
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  defdelegate validate_assumption_contradiction_with_basis(
                item,
                approval,
                presentation,
                evidence,
                time
              ),
              to: Approval

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = presentation) do
    canonical_fields(presentation, @fields)
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

  defp material_attrs(attrs), do: material_fields(attrs)

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

  defp content(attrs), do: canonical_fields(attrs, @fields -- [:ref])

  defp material_fields(source), do: canonical_fields(source, @material_fields)

  defp canonical_fields(source, fields) do
    source
    |> Portable.canonical_fields(fields)
    |> Map.update!("disclosure", &Disclosure.canonical/1)
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

  defp exact_show_row?(%Row{} = row), do: Row.dimensions(row) == show_dimensions()
  defp exact_show_row?(_row), do: false

  defp validate_optional_payload_ref(nil), do: :ok

  defp validate_optional_payload_ref(value),
    do: Portable.validate_content_ref(value, :payload, :rendered_payload_ref)
end
