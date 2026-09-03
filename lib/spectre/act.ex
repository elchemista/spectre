defmodule Spectre.Act do
  @moduledoc """
  Immutable, durable exercise of authority.

  An Act freezes the admitted consequence and its complete authority-side
  context.  It intentionally has no mutable status, result or error field;
  attempts and outcomes are separate world-side records.

  `requested_mandate_ref` preserves the Candidate's exact selection separately
  from `mandate_ref`, which records the Mandate actually resolved by admission.
  Keeping both removes guesswork when the Candidate is rebuilt during replay.
  Condition refs and the Evidence actually used to recognize them remain
  separate in `recognition_refs` and `recognition_evidence_refs`.
  """

  alias Spectre.{Consent, Disclosure, Portable, Row}

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :decision_ref,
    :candidate_identity_key,
    :candidate_digest,
    :submission_context_ref,
    :authenticated_principal_ref,
    :authentication_ref,
    :ingress_ref,
    :host_generation,
    :class,
    :row,
    :consequence,
    :consent,
    :material_digest,
    :requested_mandate_ref,
    :proposer_ref,
    :executor_ref,
    :authorizer_ref,
    :accountable_ref,
    :scope_ref,
    :subject_refs,
    :target_refs,
    :purpose_ref,
    :purpose_params,
    :mandate_ref,
    :mandate_revision,
    :evidence_refs,
    :disclosure,
    :recognition_refs,
    :recognition_evidence_refs,
    :presentation_ref,
    :reservations,
    :host_profile_ref,
    :surface_revision,
    :executor_contract_ref,
    :observation_window_ms,
    :committed_at
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          decision_ref: String.t(),
          candidate_identity_key: String.t(),
          candidate_digest: String.t(),
          submission_context_ref: String.t(),
          authenticated_principal_ref: String.t(),
          authentication_ref: String.t(),
          ingress_ref: String.t(),
          host_generation: non_neg_integer(),
          class: String.t(),
          row: Row.t(),
          consequence: term(),
          consent: Consent.t() | nil,
          material_digest: String.t(),
          requested_mandate_ref: String.t() | nil,
          proposer_ref: String.t(),
          executor_ref: String.t(),
          authorizer_ref: String.t(),
          accountable_ref: String.t(),
          scope_ref: String.t(),
          subject_refs: [String.t()],
          target_refs: [String.t()],
          purpose_ref: String.t(),
          purpose_params: map(),
          mandate_ref: String.t(),
          mandate_revision: pos_integer(),
          evidence_refs: [String.t()],
          disclosure: Disclosure.t() | nil,
          recognition_refs: [String.t()],
          recognition_evidence_refs: [String.t()],
          presentation_ref: String.t() | nil,
          reservations: map() | list(),
          host_profile_ref: String.t(),
          surface_revision: non_neg_integer(),
          executor_contract_ref: String.t(),
          observation_window_ms: non_neg_integer(),
          committed_at: integer()
        }

  @doc "Builds and validates an immutable Act."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = act), do: act |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :act),
         attrs <- defaults(attrs),
         {:ok, row} <- Row.new(Map.get(attrs, :row, %{})),
         attrs = Map.put(attrs, :row, row),
         {:ok, attrs} <- normalize_ref_sets(attrs),
         {:ok, attrs} <- normalize_disclosure(attrs),
         {:ok, attrs} <- normalize_consent(attrs),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         act = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(act),
         :ok <- Portable.validate(canonical(act)) do
      {:ok, act}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = act) do
    @fields
    |> Map.new(fn field -> {Atom.to_string(field), Map.fetch!(act, field)} end)
    |> Map.put("row", Row.canonical(act.row))
    |> Map.put("disclosure", canonical_disclosure(act.disclosure))
  end

  @doc "Restores an Act from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :act)

  @doc "Returns the stable digest of the complete Act."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = act), do: act |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived Act reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = act), do: Portable.content_ref!(:act, content(act))

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:subject_refs, [])
    |> Map.put_new(:target_refs, [])
    |> Map.put_new(:purpose_params, %{})
    |> Map.put_new(:consent, nil)
    |> Map.put_new(:evidence_refs, [])
    |> Map.put_new(:disclosure, nil)
    |> Map.put_new(:recognition_refs, [])
    |> Map.put_new(:recognition_evidence_refs, [])
    |> Map.put_new(:presentation_ref, nil)
    |> Map.put_new(:requested_mandate_ref, nil)
    |> Map.put_new(:reservations, %{})
    |> Map.put_new(:observation_window_ms, 0)
  end

  defp normalize_ref_sets(attrs) do
    with {:ok, subjects} <-
           Portable.normalize_refs(Map.fetch!(attrs, :subject_refs), :subject_refs),
         {:ok, targets} <- Portable.normalize_refs(Map.fetch!(attrs, :target_refs), :target_refs),
         {:ok, evidence} <-
           Portable.normalize_refs(Map.fetch!(attrs, :evidence_refs), :evidence_refs),
         {:ok, recognition} <-
           Portable.normalize_refs(Map.fetch!(attrs, :recognition_refs), :recognition_refs),
         {:ok, recognition_evidence} <-
           Portable.normalize_refs(
             Map.fetch!(attrs, :recognition_evidence_refs),
             :recognition_evidence_refs
           ) do
      {:ok,
       attrs
       |> Map.put(:subject_refs, subjects)
       |> Map.put(:target_refs, targets)
       |> Map.put(:evidence_refs, evidence)
       |> Map.put(:recognition_refs, recognition)
       |> Map.put(:recognition_evidence_refs, recognition_evidence)}
    end
  end

  defp normalize_disclosure(%{disclosure: nil} = attrs), do: {:ok, attrs}

  defp normalize_disclosure(attrs) do
    with {:ok, disclosure} <- Disclosure.new(Map.fetch!(attrs, :disclosure)) do
      {:ok, Map.put(attrs, :disclosure, disclosure)}
    end
  end

  defp normalize_consent(%{consent: nil} = attrs), do: {:ok, attrs}

  defp normalize_consent(attrs) do
    with {:ok, consent} <- Consent.new(Map.fetch!(attrs, :consent)) do
      {:ok, Map.put(attrs, :consent, consent)}
    end
  end

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:act, ref, content(attrs))

  defp content(%__MODULE__{} = act), do: act |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    @fields
    |> Enum.reject(&(&1 == :ref))
    |> Map.new(fn field -> {Atom.to_string(field), Map.get(attrs, field)} end)
    |> Map.put("row", Row.canonical(Map.fetch!(attrs, :row)))
    |> Map.put("disclosure", canonical_disclosure(Map.get(attrs, :disclosure)))
  end

  defp validate_record(%__MODULE__{} = act) do
    cond do
      act.schema_version != @schema_version ->
        {:error, {:unsupported_act_schema_version, act.schema_version}}

      not is_binary(act.class) or act.class == "" ->
        {:error, {:invalid_act_class, act.class}}

      is_nil(act.consequence) ->
        {:error, :missing_act_consequence}

      act.candidate_digest != act.material_digest ->
        {:error, {:act_material_digest_mismatch, act.material_digest, act.candidate_digest}}

      not is_map(act.purpose_params) or is_struct(act.purpose_params) ->
        {:error, {:invalid_act_purpose_params, Portable.shape(act.purpose_params)}}

      not portable_collection?(act.reservations) ->
        {:error, {:invalid_act_reservations, Portable.shape(act.reservations)}}

      not is_integer(act.mandate_revision) or act.mandate_revision <= 0 ->
        {:error, {:invalid_act_mandate_revision, act.mandate_revision}}

      not is_integer(act.surface_revision) or act.surface_revision < 0 ->
        {:error, {:invalid_act_surface_revision, act.surface_revision}}

      not is_integer(act.observation_window_ms) or act.observation_window_ms < 0 ->
        {:error, {:invalid_act_observation_window_ms, act.observation_window_ms}}

      not is_integer(act.committed_at) ->
        {:error, {:invalid_act_committed_at, act.committed_at}}

      not is_integer(act.host_generation) or act.host_generation < 0 ->
        {:error, {:invalid_act_host_generation, act.host_generation}}

      true ->
        with :ok <- validate_refs(act),
             :ok <- validate_consent(act),
             :ok <- validate_recognition_evidence(act) do
          Disclosure.validate_boundary(
            act.row,
            act.disclosure,
            act.target_refs,
            act.evidence_refs
          )
        end
    end
  end

  defp validate_refs(act) do
    with :ok <- Portable.validate_ref(act.ref, :ref),
         :ok <- Portable.validate_ref(act.decision_ref, :decision_ref),
         :ok <-
           Portable.validate_non_empty_binary(act.candidate_identity_key, :candidate_identity_key),
         :ok <- Portable.validate_non_empty_binary(act.candidate_digest, :candidate_digest),
         :ok <- Portable.validate_non_empty_binary(act.material_digest, :material_digest),
         :ok <- validate_optional_ref(act.requested_mandate_ref, :requested_mandate_ref),
         :ok <- Portable.validate_ref(act.submission_context_ref, :submission_context_ref),
         :ok <-
           Portable.validate_ref(
             act.authenticated_principal_ref,
             :authenticated_principal_ref
           ),
         :ok <- Portable.validate_ref(act.authentication_ref, :authentication_ref),
         :ok <- Portable.validate_ref(act.ingress_ref, :ingress_ref),
         :ok <- Portable.validate_ref(act.proposer_ref, :proposer_ref),
         :ok <- Portable.validate_ref(act.executor_ref, :executor_ref),
         :ok <- Portable.validate_ref(act.authorizer_ref, :authorizer_ref),
         :ok <- Portable.validate_ref(act.accountable_ref, :accountable_ref),
         :ok <- Portable.validate_ref(act.scope_ref, :scope_ref),
         :ok <- Portable.validate_refs(act.subject_refs, :subject_refs),
         :ok <- Portable.validate_refs(act.target_refs, :target_refs),
         :ok <- Portable.validate_ref(act.purpose_ref, :purpose_ref),
         :ok <- Portable.validate_ref(act.mandate_ref, :mandate_ref),
         :ok <- Portable.validate_refs(act.evidence_refs, :evidence_refs),
         :ok <- Portable.validate_refs(act.recognition_refs, :recognition_refs),
         :ok <-
           Portable.validate_refs(
             act.recognition_evidence_refs,
             :recognition_evidence_refs
           ),
         :ok <- validate_optional_ref(act.presentation_ref, :presentation_ref),
         :ok <- Portable.validate_ref(act.host_profile_ref, :host_profile_ref),
         :ok <- Portable.validate_ref(act.executor_contract_ref, :executor_contract_ref) do
      :ok
    end
  end

  defp validate_optional_ref(nil, _field), do: :ok
  defp validate_optional_ref(value, field), do: Portable.validate_ref(value, field)

  defp validate_consent(%__MODULE__{consent: nil, presentation_ref: nil}), do: :ok

  defp validate_consent(%__MODULE__{consent: nil}),
    do: {:error, :act_presentation_missing_consent_material}

  defp validate_consent(%__MODULE__{} = act) do
    Consent.validate_purpose(act.consent, act.purpose_ref, act.purpose_params)
  end

  defp validate_recognition_evidence(%__MODULE__{} = act) do
    if MapSet.subset?(
         MapSet.new(act.recognition_evidence_refs),
         MapSet.new(act.evidence_refs)
       ),
       do: :ok,
       else: {:error, :act_recognition_evidence_not_declared}
  end

  defp canonical_disclosure(nil), do: nil
  defp canonical_disclosure(%Disclosure{} = disclosure), do: Disclosure.canonical(disclosure)
  defp canonical_disclosure(value), do: value

  defp portable_collection?(value) when is_map(value), do: not is_struct(value)
  defp portable_collection?(value) when is_list(value), do: true
  defp portable_collection?(_value), do: false
end
