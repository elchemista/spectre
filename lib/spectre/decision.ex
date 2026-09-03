defmodule Spectre.Decision do
  @moduledoc """
  Durable result of evaluating a candidate at one authority revision.

  The four outcomes are intentionally disjoint.  Only `:admitted` may be paired
  with an Act; refusal, inability to decide and an unknown surface class must
  never be collapsed into one generic error. `recognition_refs` identifies the
  evaluated Conditions; `recognition_evidence_refs` separately freezes the
  Evidence basis that actually reached the Recognition stage.
  """

  alias Spectre.{Consent, Portable}
  alias Spectre.Kernel.Meter.Amounts

  @schema_version 1
  @outcomes [:admitted, :refused, :undecidable, :unknown_class]
  @fields [
    :schema_version,
    :ref,
    :outcome,
    :reasons,
    :candidate_identity_key,
    :candidate_digest,
    :candidate_class,
    :consent,
    :submission_context_ref,
    :domain_ref,
    :channel_ref,
    :session_ref,
    :authenticated_principal_ref,
    :authentication_ref,
    :ingress_ref,
    :host_generation,
    :mandate_ref,
    :mandate_revision,
    :recognition_refs,
    :recognition_evidence_refs,
    :reservations,
    :proposer_ref,
    :executor_ref,
    :authorizer_ref,
    :accountable_ref,
    :scope_ref,
    :host_profile_ref,
    :surface_revision,
    :authority_revision,
    :decided_at
  ]

  @enforce_keys [
    :schema_version,
    :ref,
    :outcome,
    :reasons,
    :candidate_identity_key,
    :candidate_digest,
    :candidate_class,
    :consent,
    :submission_context_ref,
    :domain_ref,
    :authenticated_principal_ref,
    :authentication_ref,
    :ingress_ref,
    :host_generation,
    :recognition_refs,
    :recognition_evidence_refs,
    :reservations,
    :proposer_ref,
    :scope_ref,
    :host_profile_ref,
    :surface_revision,
    :authority_revision,
    :decided_at
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            outcome: nil,
            reasons: [],
            candidate_identity_key: nil,
            candidate_digest: nil,
            candidate_class: nil,
            consent: nil,
            submission_context_ref: nil,
            domain_ref: nil,
            channel_ref: nil,
            session_ref: nil,
            authenticated_principal_ref: nil,
            authentication_ref: nil,
            ingress_ref: nil,
            host_generation: nil,
            mandate_ref: nil,
            mandate_revision: nil,
            recognition_refs: [],
            recognition_evidence_refs: [],
            reservations: %{},
            proposer_ref: nil,
            executor_ref: nil,
            authorizer_ref: nil,
            accountable_ref: nil,
            scope_ref: nil,
            host_profile_ref: nil,
            surface_revision: nil,
            authority_revision: nil,
            decided_at: nil

  @type outcome :: :admitted | :refused | :undecidable | :unknown_class
  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          outcome: outcome(),
          reasons: [term()],
          candidate_identity_key: String.t(),
          candidate_digest: String.t(),
          candidate_class: String.t(),
          consent: Consent.t() | nil,
          submission_context_ref: String.t(),
          domain_ref: String.t(),
          channel_ref: String.t() | nil,
          session_ref: String.t() | nil,
          authenticated_principal_ref: String.t(),
          authentication_ref: String.t(),
          ingress_ref: String.t(),
          host_generation: non_neg_integer(),
          mandate_ref: String.t() | nil,
          mandate_revision: pos_integer() | nil,
          recognition_refs: [String.t()],
          recognition_evidence_refs: [String.t()],
          reservations: Amounts.t(),
          proposer_ref: String.t(),
          executor_ref: String.t() | nil,
          authorizer_ref: String.t() | nil,
          accountable_ref: String.t() | nil,
          scope_ref: String.t(),
          host_profile_ref: String.t(),
          surface_revision: non_neg_integer(),
          authority_revision: non_neg_integer(),
          decided_at: integer()
        }

  @doc "Builds and validates a durable decision."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = decision), do: decision |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :decision),
         attrs <- defaults(attrs),
         {:ok, recognition_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :recognition_refs), :recognition_refs),
         {:ok, recognition_evidence_refs} <-
           Portable.normalize_refs(
             Map.fetch!(attrs, :recognition_evidence_refs),
             :recognition_evidence_refs
           ),
         attrs =
           attrs
           |> Map.put(:recognition_refs, recognition_refs)
           |> Map.put(:recognition_evidence_refs, recognition_evidence_refs),
         {:ok, attrs} <- normalize_reservations(attrs),
         {:ok, attrs} <- normalize_consent(attrs),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         decision = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(decision),
         :ok <- Portable.validate(canonical(decision)) do
      {:ok, decision}
    end
  end

  @doc "Returns true only for the sole outcome that can produce an Act."
  @spec admitted?(t()) :: boolean()
  def admitted?(%__MODULE__{outcome: :admitted}), do: true
  def admitted?(%__MODULE__{}), do: false

  @doc "Returns whether Admission planned any Meter reservation."
  @spec reservations?(t()) :: boolean()
  def reservations?(%__MODULE__{reservations: reservations}), do: map_size(reservations) > 0

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = decision) do
    %{
      "schema_version" => decision.schema_version,
      "ref" => decision.ref,
      "outcome" => decision.outcome,
      "reasons" => decision.reasons,
      "candidate_identity_key" => decision.candidate_identity_key,
      "candidate_digest" => decision.candidate_digest,
      "candidate_class" => decision.candidate_class,
      "consent" => decision.consent,
      "submission_context_ref" => decision.submission_context_ref,
      "domain_ref" => decision.domain_ref,
      "channel_ref" => decision.channel_ref,
      "session_ref" => decision.session_ref,
      "authenticated_principal_ref" => decision.authenticated_principal_ref,
      "authentication_ref" => decision.authentication_ref,
      "ingress_ref" => decision.ingress_ref,
      "host_generation" => decision.host_generation,
      "mandate_ref" => decision.mandate_ref,
      "mandate_revision" => decision.mandate_revision,
      "recognition_refs" => decision.recognition_refs,
      "recognition_evidence_refs" => decision.recognition_evidence_refs,
      "reservations" => decision.reservations,
      "proposer_ref" => decision.proposer_ref,
      "executor_ref" => decision.executor_ref,
      "authorizer_ref" => decision.authorizer_ref,
      "accountable_ref" => decision.accountable_ref,
      "scope_ref" => decision.scope_ref,
      "host_profile_ref" => decision.host_profile_ref,
      "surface_revision" => decision.surface_revision,
      "authority_revision" => decision.authority_revision,
      "decided_at" => decision.decided_at
    }
  end

  @doc "Restores a decision from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :decision)

  @doc "Returns the stable digest of the complete decision."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = decision), do: decision |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = decision),
    do: Portable.content_ref!(:decision, content(decision))

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:reasons, [])
    |> Map.put_new(:consent, nil)
    |> Map.put_new(:channel_ref, nil)
    |> Map.put_new(:session_ref, nil)
    |> Map.put_new(:mandate_ref, nil)
    |> Map.put_new(:mandate_revision, nil)
    |> Map.put_new(:recognition_refs, [])
    |> Map.put_new(:recognition_evidence_refs, [])
    |> Map.put_new(:reservations, %{})
    |> Map.put_new(:executor_ref, nil)
    |> Map.put_new(:authorizer_ref, nil)
    |> Map.put_new(:accountable_ref, nil)
  end

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:decision, ref, content(attrs))

  defp normalize_consent(%{consent: nil} = attrs), do: {:ok, attrs}

  defp normalize_consent(attrs) do
    with {:ok, consent} <- Consent.new(Map.fetch!(attrs, :consent)) do
      {:ok, Map.put(attrs, :consent, consent)}
    end
  end

  defp content(%__MODULE__{} = decision), do: decision |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    @fields
    |> Enum.reject(&(&1 == :ref))
    |> Map.new(fn field -> {Atom.to_string(field), Map.get(attrs, field)} end)
  end

  defp validate_record(%__MODULE__{} = decision) do
    cond do
      decision.schema_version != @schema_version ->
        {:error, {:unsupported_decision_schema_version, decision.schema_version}}

      decision.outcome not in @outcomes ->
        {:error, {:invalid_decision_outcome, decision.outcome}}

      not is_list(decision.reasons) ->
        {:error, {:invalid_decision_reasons, Portable.shape(decision.reasons)}}

      decision.outcome != :admitted and decision.reasons == [] ->
        {:error, {:missing_decision_reasons, decision.outcome}}

      not is_map(decision.reservations) or is_struct(decision.reservations) ->
        {:error, {:invalid_decision_reservations, Portable.shape(decision.reservations)}}

      not is_integer(decision.surface_revision) or decision.surface_revision < 0 ->
        {:error, {:invalid_decision_surface_revision, decision.surface_revision}}

      not is_integer(decision.authority_revision) or decision.authority_revision < 0 ->
        {:error, {:invalid_decision_authority_revision, decision.authority_revision}}

      not is_integer(decision.decided_at) ->
        {:error, {:invalid_decision_decided_at, decision.decided_at}}

      not is_integer(decision.host_generation) or decision.host_generation < 0 ->
        {:error, {:invalid_decision_host_generation, decision.host_generation}}

      true ->
        with :ok <- validate_admission(decision),
             :ok <- validate_refs(decision) do
          :ok
        end
    end
  end

  defp validate_admission(%__MODULE__{outcome: :admitted} = decision) do
    cond do
      is_nil(decision.mandate_ref) ->
        {:error, :admitted_decision_missing_mandate_ref}

      not is_integer(decision.mandate_revision) or decision.mandate_revision <= 0 ->
        {:error, {:invalid_admitted_mandate_revision, decision.mandate_revision}}

      is_nil(decision.executor_ref) ->
        {:error, :admitted_decision_missing_executor_ref}

      is_nil(decision.authorizer_ref) ->
        {:error, :admitted_decision_missing_authorizer_ref}

      is_nil(decision.accountable_ref) ->
        {:error, :admitted_decision_missing_accountable_ref}

      true ->
        :ok
    end
  end

  defp validate_admission(%__MODULE__{
         mandate_ref: nil,
         recognition_evidence_refs: [_first | _rest]
       }),
       do: {:error, :decision_without_mandate_has_recognition_evidence}

  defp validate_admission(_decision), do: :ok

  defp validate_refs(decision) do
    with :ok <- Portable.validate_ref(decision.ref, :ref),
         :ok <-
           Portable.validate_non_empty_binary(
             decision.candidate_identity_key,
             :candidate_identity_key
           ),
         :ok <- Portable.validate_non_empty_binary(decision.candidate_digest, :candidate_digest),
         :ok <- Portable.validate_non_empty_binary(decision.candidate_class, :candidate_class),
         :ok <- Portable.validate_ref(decision.submission_context_ref, :submission_context_ref),
         :ok <- Portable.validate_ref(decision.domain_ref, :domain_ref),
         :ok <- validate_optional_ref(decision.channel_ref, :channel_ref),
         :ok <- validate_optional_ref(decision.session_ref, :session_ref),
         :ok <-
           Portable.validate_ref(
             decision.authenticated_principal_ref,
             :authenticated_principal_ref
           ),
         :ok <- Portable.validate_ref(decision.authentication_ref, :authentication_ref),
         :ok <- Portable.validate_ref(decision.ingress_ref, :ingress_ref),
         :ok <- validate_optional_ref(decision.mandate_ref, :mandate_ref),
         :ok <- Portable.validate_refs(decision.recognition_refs, :recognition_refs),
         :ok <-
           Portable.validate_refs(
             decision.recognition_evidence_refs,
             :recognition_evidence_refs
           ),
         :ok <- Portable.validate_ref(decision.proposer_ref, :proposer_ref),
         :ok <- validate_optional_ref(decision.executor_ref, :executor_ref),
         :ok <- validate_optional_ref(decision.authorizer_ref, :authorizer_ref),
         :ok <- validate_optional_ref(decision.accountable_ref, :accountable_ref),
         :ok <- Portable.validate_ref(decision.scope_ref, :scope_ref),
         :ok <- Portable.validate_ref(decision.host_profile_ref, :host_profile_ref) do
      :ok
    end
  end

  defp validate_optional_ref(nil, _field), do: :ok
  defp validate_optional_ref(value, field), do: Portable.validate_ref(value, field)

  defp normalize_reservations(attrs) do
    case Amounts.normalize(Map.fetch!(attrs, :reservations)) do
      {:ok, reservations} -> {:ok, Map.put(attrs, :reservations, reservations)}
      {:error, reason} -> {:error, {:invalid_decision_reservations, reason}}
    end
  end
end
