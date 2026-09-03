defmodule Spectre.Candidate do
  @moduledoc """
  Portable proposal with no authority or execution capability.

  A candidate contains every field that may materially affect classification,
  mandate matching, consent or admission.  `identity_key` provides idempotency:
  the same key and material digest is the same proposal; the same key with a
  different digest is a conflict for the kernel to reject.

  `consent` is one closed, portable declaration of the exact material a person
  must evaluate. Consent uses a separate pre-consent binding covering that
  declaration and every other field knowable before presentation. Only verified
  approval Evidence for that Presentation may be excluded to break the causal
  cycle; all other Evidence remains bound. The final candidate digest still
  covers the Presentation and every Evidence ref.
  """

  alias Spectre.{Consent, Disclosure, Portable, Row}

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :identity_key,
    :material_digest,
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
    :consent,
    :evidence_refs,
    :disclosure,
    :presentation_ref,
    :meter_requests,
    :executor_contract_ref,
    :observation_window_ms
  ]

  @enforce_keys [
    :schema_version,
    :ref,
    :identity_key,
    :material_digest,
    :class,
    :consequence,
    :row,
    :proposer_ref,
    :executor_ref,
    :accountable_ref,
    :scope_ref,
    :subject_refs,
    :target_refs,
    :purpose_ref,
    :purpose_params,
    :consent,
    :evidence_refs,
    :meter_requests,
    :executor_contract_ref,
    :observation_window_ms
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            identity_key: nil,
            material_digest: nil,
            class: nil,
            consequence: nil,
            row: nil,
            requested_mandate_ref: nil,
            proposer_ref: nil,
            executor_ref: nil,
            accountable_ref: nil,
            scope_ref: nil,
            subject_refs: [],
            target_refs: [],
            purpose_ref: nil,
            purpose_params: %{},
            consent: nil,
            evidence_refs: [],
            disclosure: nil,
            presentation_ref: nil,
            meter_requests: %{},
            executor_contract_ref: nil,
            observation_window_ms: 0

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          identity_key: String.t(),
          material_digest: String.t(),
          class: String.t(),
          consequence: term(),
          row: Row.t(),
          requested_mandate_ref: String.t() | nil,
          proposer_ref: String.t(),
          executor_ref: String.t(),
          accountable_ref: String.t(),
          scope_ref: String.t(),
          subject_refs: [String.t()],
          target_refs: [String.t()],
          purpose_ref: String.t(),
          purpose_params: map(),
          consent: Consent.t() | nil,
          evidence_refs: [String.t()],
          disclosure: Disclosure.t() | nil,
          presentation_ref: String.t() | nil,
          meter_requests: %{optional(String.t()) => non_neg_integer()},
          executor_contract_ref: String.t(),
          observation_window_ms: non_neg_integer()
        }

  @doc "Builds and validates a candidate, computing its material digest and ref."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = candidate), do: candidate |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :candidate),
         attrs <- defaults(attrs),
         {:ok, row} <- Row.new(Map.get(attrs, :row, %{})),
         {:ok, attrs} <- normalize_sets(Map.put(attrs, :row, row)),
         {:ok, attrs} <- normalize_disclosure(attrs),
         {:ok, attrs} <- normalize_consent(attrs),
         {:ok, expected_digest} <- Portable.digest(material_attrs(attrs)),
         :ok <- verify_material_digest(Map.get(attrs, :material_digest), expected_digest),
         attrs = Map.put(attrs, :material_digest, expected_digest),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         candidate = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(candidate),
         :ok <- Portable.validate(canonical(candidate)) do
      {:ok, candidate}
    end
  end

  @doc "Returns exactly the fields bound by `material_digest`."
  @spec material(t()) :: map()
  def material(%__MODULE__{} = candidate) do
    %{
      "class" => candidate.class,
      "consequence" => candidate.consequence,
      "row" => Row.canonical(candidate.row),
      "requested_mandate_ref" => candidate.requested_mandate_ref,
      "proposer_ref" => candidate.proposer_ref,
      "executor_ref" => candidate.executor_ref,
      "accountable_ref" => candidate.accountable_ref,
      "scope_ref" => candidate.scope_ref,
      "subject_refs" => candidate.subject_refs,
      "target_refs" => candidate.target_refs,
      "purpose_ref" => candidate.purpose_ref,
      "purpose_params" => candidate.purpose_params,
      "consent" => candidate.consent,
      "evidence_refs" => candidate.evidence_refs,
      "disclosure" => canonical_disclosure(candidate.disclosure),
      "presentation_ref" => candidate.presentation_ref,
      "meter_requests" => candidate.meter_requests,
      "executor_contract_ref" => candidate.executor_contract_ref,
      "observation_window_ms" => candidate.observation_window_ms
    }
  end

  @doc "Returns the exact, acyclic candidate material bound by a Presentation."
  @spec presentation_binding(t(), [String.t()]) :: map()
  def presentation_binding(%__MODULE__{} = candidate, approval_evidence_refs \\ [])
      when is_list(approval_evidence_refs) do
    approval_evidence_refs = MapSet.new(approval_evidence_refs)

    %{
      "schema_version" => candidate.schema_version,
      "identity_key" => candidate.identity_key,
      "class" => candidate.class,
      "consequence" => candidate.consequence,
      "row" => Row.canonical(candidate.row),
      "requested_mandate_ref" => candidate.requested_mandate_ref,
      "proposer_ref" => candidate.proposer_ref,
      "executor_ref" => candidate.executor_ref,
      "accountable_ref" => candidate.accountable_ref,
      "scope_ref" => candidate.scope_ref,
      "subject_refs" => candidate.subject_refs,
      "target_refs" => candidate.target_refs,
      "purpose_ref" => candidate.purpose_ref,
      "purpose_params" => candidate.purpose_params,
      "consent" => candidate.consent,
      "evidence_refs" =>
        Enum.reject(candidate.evidence_refs, &MapSet.member?(approval_evidence_refs, &1)),
      "disclosure" => canonical_disclosure(candidate.disclosure),
      "meter_requests" => candidate.meter_requests,
      "executor_contract_ref" => candidate.executor_contract_ref,
      "observation_window_ms" => candidate.observation_window_ms
    }
  end

  @doc "Returns the content address of `presentation_binding/2`."
  @spec presentation_binding_ref(t(), [String.t()]) :: String.t()
  def presentation_binding_ref(%__MODULE__{} = candidate, approval_evidence_refs \\ []),
    do:
      Portable.content_ref!(
        :candidate_binding,
        presentation_binding(candidate, approval_evidence_refs)
      )

  defp material_attrs(attrs) do
    %{
      "class" => Map.get(attrs, :class),
      "consequence" => Map.get(attrs, :consequence),
      "row" => Row.canonical(Map.fetch!(attrs, :row)),
      "requested_mandate_ref" => Map.get(attrs, :requested_mandate_ref),
      "proposer_ref" => Map.get(attrs, :proposer_ref),
      "executor_ref" => Map.get(attrs, :executor_ref),
      "accountable_ref" => Map.get(attrs, :accountable_ref),
      "scope_ref" => Map.get(attrs, :scope_ref),
      "subject_refs" => Map.fetch!(attrs, :subject_refs),
      "target_refs" => Map.fetch!(attrs, :target_refs),
      "purpose_ref" => Map.get(attrs, :purpose_ref),
      "purpose_params" => Map.fetch!(attrs, :purpose_params),
      "consent" => Map.get(attrs, :consent),
      "evidence_refs" => Map.fetch!(attrs, :evidence_refs),
      "disclosure" => canonical_disclosure(Map.get(attrs, :disclosure)),
      "presentation_ref" => Map.get(attrs, :presentation_ref),
      "meter_requests" => Map.fetch!(attrs, :meter_requests),
      "executor_contract_ref" => Map.get(attrs, :executor_contract_ref),
      "observation_window_ms" => Map.fetch!(attrs, :observation_window_ms)
    }
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = candidate) do
    material(candidate)
    |> Map.merge(%{
      "schema_version" => candidate.schema_version,
      "ref" => candidate.ref,
      "identity_key" => candidate.identity_key,
      "material_digest" => candidate.material_digest
    })
  end

  @doc "Restores a candidate from its canonical map and verifies its digest."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :candidate)

  @doc "Returns the stable digest of the complete candidate."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = candidate), do: candidate |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = candidate),
    do: Portable.content_ref!(:candidate, identity(candidate))

  @doc false
  @spec effect_digest(map()) :: {:ok, String.t()} | {:error, term()}
  def effect_digest(record) when is_map(record) do
    with {:ok, row} <- Row.new(field(record, :row)),
         {:ok, subject_refs} <-
           Portable.normalize_refs(field(record, :subject_refs, []), :subject_refs),
         {:ok, target_refs} <-
           Portable.normalize_refs(field(record, :target_refs, []), :target_refs),
         class when is_binary(class) and class != "" <- field(record, :class),
         consequence when not is_nil(consequence) <- field(record, :consequence) do
      Portable.digest(%{
        "class" => class,
        "consequence" => consequence,
        "row" => Row.canonical(row),
        "subject_refs" => subject_refs,
        "target_refs" => target_refs,
        "disclosure" => canonical_disclosure(field(record, :disclosure))
      })
    else
      nil -> {:error, :invalid_candidate_effect}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_candidate_effect}
    end
  end

  def effect_digest(_record), do: {:error, :invalid_candidate_effect}

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:requested_mandate_ref, nil)
    |> Map.put_new(:subject_refs, [])
    |> Map.put_new(:target_refs, [])
    |> Map.put_new(:purpose_params, %{})
    |> Map.put_new(:consent, nil)
    |> Map.put_new(:evidence_refs, [])
    |> Map.put_new(:disclosure, nil)
    |> Map.put_new(:presentation_ref, nil)
    |> Map.put_new(:meter_requests, %{})
    |> Map.put_new(:observation_window_ms, 0)
  end

  defp normalize_sets(attrs) do
    with {:ok, subjects} <-
           Portable.normalize_refs(Map.fetch!(attrs, :subject_refs), :subject_refs),
         {:ok, targets} <- Portable.normalize_refs(Map.fetch!(attrs, :target_refs), :target_refs),
         {:ok, evidence} <-
           Portable.normalize_refs(Map.fetch!(attrs, :evidence_refs), :evidence_refs) do
      {:ok,
       attrs
       |> Map.put(:subject_refs, subjects)
       |> Map.put(:target_refs, targets)
       |> Map.put(:evidence_refs, evidence)}
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

  defp verify_material_digest(nil, _expected), do: :ok
  defp verify_material_digest(expected, expected), do: :ok

  defp verify_material_digest(value, expected),
    do: {:error, {:candidate_material_digest_mismatch, value, expected}}

  defp resolve_ref(ref, attrs),
    do: Portable.resolve_content_ref(:candidate, ref, identity(attrs))

  defp identity(%__MODULE__{} = candidate),
    do: %{
      "identity_key" => candidate.identity_key,
      "material_digest" => candidate.material_digest
    }

  defp identity(attrs),
    do: %{
      "identity_key" => Map.get(attrs, :identity_key),
      "material_digest" => Map.get(attrs, :material_digest)
    }

  defp validate_record(%__MODULE__{} = candidate) do
    cond do
      candidate.schema_version != @schema_version ->
        {:error, {:unsupported_candidate_schema_version, candidate.schema_version}}

      not is_binary(candidate.class) or candidate.class == "" ->
        {:error, {:invalid_candidate_class, candidate.class}}

      is_nil(candidate.consequence) ->
        {:error, :missing_candidate_consequence}

      not is_map(candidate.purpose_params) or is_struct(candidate.purpose_params) ->
        {:error, {:invalid_candidate_purpose_params, Portable.shape(candidate.purpose_params)}}

      not valid_meter_requests?(candidate.meter_requests) ->
        {:error, {:invalid_candidate_meter_requests, candidate.meter_requests}}

      not (is_integer(candidate.observation_window_ms) and candidate.observation_window_ms >= 0) ->
        {:error, {:invalid_candidate_observation_window_ms, candidate.observation_window_ms}}

      true ->
        with :ok <- validate_refs(candidate),
             :ok <- validate_consent(candidate) do
          Disclosure.validate_boundary(
            candidate.row,
            candidate.disclosure,
            candidate.target_refs,
            candidate.evidence_refs
          )
        end
    end
  end

  defp validate_refs(candidate) do
    with :ok <- Portable.validate_ref(candidate.ref, :ref),
         :ok <- Portable.validate_non_empty_binary(candidate.identity_key, :identity_key),
         :ok <- Portable.validate_non_empty_binary(candidate.material_digest, :material_digest),
         :ok <- validate_optional_ref(candidate.requested_mandate_ref, :requested_mandate_ref),
         :ok <- Portable.validate_ref(candidate.proposer_ref, :proposer_ref),
         :ok <- Portable.validate_ref(candidate.executor_ref, :executor_ref),
         :ok <- Portable.validate_ref(candidate.accountable_ref, :accountable_ref),
         :ok <- Portable.validate_ref(candidate.scope_ref, :scope_ref),
         :ok <- Portable.validate_refs(candidate.subject_refs, :subject_refs),
         :ok <- Portable.validate_refs(candidate.target_refs, :target_refs),
         :ok <- Portable.validate_ref(candidate.purpose_ref, :purpose_ref),
         :ok <- Portable.validate_refs(candidate.evidence_refs, :evidence_refs),
         :ok <- validate_optional_ref(candidate.presentation_ref, :presentation_ref),
         :ok <- Portable.validate_ref(candidate.executor_contract_ref, :executor_contract_ref) do
      :ok
    end
  end

  defp valid_meter_requests?(requests) when is_map(requests) and not is_struct(requests) do
    Enum.all?(requests, fn {ref, quantity} ->
      is_binary(ref) and ref != "" and is_integer(quantity) and quantity > 0
    end)
  end

  defp valid_meter_requests?(_requests), do: false

  defp validate_optional_ref(nil, _field), do: :ok
  defp validate_optional_ref(value, field), do: Portable.validate_ref(value, field)

  defp validate_consent(%__MODULE__{consent: nil, presentation_ref: nil}), do: :ok

  defp validate_consent(%__MODULE__{consent: nil}),
    do: {:error, :presentation_missing_consent_material}

  defp validate_consent(%__MODULE__{} = candidate) do
    Consent.validate_purpose(candidate.consent, candidate.purpose_ref, candidate.purpose_params)
  end

  defp canonical_disclosure(nil), do: nil
  defp canonical_disclosure(%Disclosure{} = disclosure), do: Disclosure.canonical(disclosure)
  defp canonical_disclosure(value), do: value

  defp field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
