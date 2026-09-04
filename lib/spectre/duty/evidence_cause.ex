defmodule Spectre.Duty.EvidenceCause do
  @moduledoc """
  Canonical description of an application Duty cause carried by Evidence.

  The marker records only facts about the unresolved gap.  Containment,
  closing conditions and disposition authority remain Constitution policy and
  are deliberately absent, so Evidence can never grant itself power.
  """

  alias Spectre.{Constitution, Duty, Evidence, Portable}

  @schema_version 1
  @proposition "spectre.duty.required"
  @fields [
    :schema_version,
    :class,
    :accountable_ref,
    :subject_refs,
    :mandate_ref,
    :related_evidence_refs,
    :missing
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          schema_version: 1,
          class: String.t(),
          accountable_ref: String.t(),
          subject_refs: [String.t()],
          mandate_ref: String.t() | nil,
          related_evidence_refs: [String.t()],
          missing: [term()]
        }

  @doc "The reserved proposition used by Evidence which declares a Duty cause."
  @spec proposition() :: String.t()
  def proposition, do: @proposition

  @doc "Builds the strict payload carried by a Duty-cause Evidence record."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = cause), do: cause |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :duty_evidence_cause),
         attrs <- defaults(attrs),
         {:ok, class} <- normalize_application_class(Map.get(attrs, :class)),
         {:ok, subject_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :subject_refs), :subject_refs),
         {:ok, evidence_refs} <-
           Portable.normalize_refs(
             Map.fetch!(attrs, :related_evidence_refs),
             :related_evidence_refs
           ),
         cause =
           struct(__MODULE__, %{
             attrs
             | class: class,
               subject_refs: subject_refs,
               related_evidence_refs: evidence_refs
           }),
         :ok <- validate(cause),
         :ok <- Portable.validate(canonical(cause)) do
      {:ok, cause}
    end
  end

  @doc "Returns the exact string-keyed value embedded in `Evidence.payload`."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = cause) do
    Portable.canonical_fields(cause, @fields)
  end

  @doc "Restores a cause payload from its canonical representation."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :duty_evidence_cause)

  @doc "Recognizes and validates the reserved Evidence marker and its configured source."
  @spec extract(Evidence.t(), map()) :: :not_cause | {:ok, t()} | {:error, term()}
  def extract(%Evidence{proposition: proposition}, _constitution)
      when proposition != @proposition,
      do: :not_cause

  def extract(%Evidence{} = evidence, constitution)
      when is_map(constitution) and not is_struct(constitution) do
    with :ok <- valid_evidence_envelope(evidence),
         {:ok, cause} <- from_canonical(evidence.payload),
         :ok <- configured_source(cause, evidence, constitution) do
      {:ok, cause}
    end
  end

  def extract(%Evidence{proposition: @proposition}, _constitution),
    do: {:error, :invalid_duty_evidence_constitution}

  def extract(_evidence, _constitution), do: :not_cause

  @doc "Returns the stable no-Act cause key derived from canonical Evidence."
  @spec cause_key(Evidence.t(), t()) :: term()
  def cause_key(%Evidence{ref: evidence_ref}, %__MODULE__{class: class}),
    do: {:evidence_gap, class, evidence_ref}

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:subject_refs, [])
    |> Map.put_new(:mandate_ref, nil)
    |> Map.put_new(:related_evidence_refs, [])
  end

  defp normalize_application_class(class) do
    with {:ok, normalized} <- Duty.normalize_class(class),
         true <- is_binary(normalized) do
      {:ok, normalized}
    else
      false -> {:error, {:duty_evidence_cause_requires_application_class, class}}
      {:error, _reason} = error -> error
    end
  end

  defp validate(%__MODULE__{} = cause) do
    cond do
      cause.schema_version != @schema_version ->
        {:error, {:unsupported_duty_evidence_cause_schema_version, cause.schema_version}}

      not is_list(cause.missing) or cause.missing == [] ->
        {:error, {:invalid_duty_evidence_cause_missing, Portable.shape(cause.missing)}}

      true ->
        with :ok <- Portable.validate_ref(cause.accountable_ref, :accountable_ref),
             :ok <- Portable.validate_optional_ref(cause.mandate_ref, :mandate_ref) do
          :ok
        end
    end
  end

  defp valid_evidence_envelope(evidence) do
    cond do
      evidence.stance != :supports ->
        {:error, {:duty_evidence_cause_must_support, evidence.ref}}

      evidence.provisional ->
        {:error, {:provisional_duty_evidence_cause, evidence.ref}}

      not is_map(evidence.payload) or is_struct(evidence.payload) ->
        {:error, {:invalid_duty_evidence_cause_payload, evidence.ref}}

      true ->
        :ok
    end
  end

  defp configured_source(cause, evidence, constitution) do
    allowed =
      constitution
      |> Constitution.duty_rule(cause.class)
      |> Constitution.rule_value(:cause_source_refs, [])

    if evidence.source_ref in allowed,
      do: :ok,
      else: {:error, {:duty_evidence_source_not_configured, cause.class, evidence.source_ref}}
  end
end
