defmodule Spectre.Outcome do
  @moduledoc """
  World-side observation associated with one durable attempt.

  `:ambiguous` is distinct from failure.  In particular, only
  `:definitive_no_effect` carries the semantic fact needed to safely release a
  reservation; a timeout or missing response must remain `:ambiguous`.
  """

  alias Spectre.Portable

  @schema_version 1
  @proposition_contract_ref "spectre.outcome.proposition.v1"
  @statuses [:succeeded, :failed, :definitive_no_effect, :ambiguous]
  @fields [
    :schema_version,
    :ref,
    :act_ref,
    :attempt_ref,
    :status,
    :evidence_refs,
    :observed_at,
    :details_ref,
    :contradicts_outcome_ref
  ]

  @enforce_keys @fields
  defstruct @fields

  @type status :: :succeeded | :failed | :definitive_no_effect | :ambiguous
  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          act_ref: String.t(),
          attempt_ref: String.t(),
          status: status(),
          evidence_refs: [String.t()],
          observed_at: integer(),
          details_ref: String.t(),
          contradicts_outcome_ref: String.t() | nil
        }

  @doc "Builds and validates an observed outcome."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = outcome), do: outcome |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :outcome),
         attrs =
           attrs
           |> Map.put_new(:schema_version, @schema_version)
           |> Map.put_new(:evidence_refs, [])
           |> Map.put_new(:contradicts_outcome_ref, nil),
         {:ok, evidence_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :evidence_refs), :evidence_refs),
         attrs = Map.put(attrs, :evidence_refs, evidence_refs),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         outcome = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(outcome),
         :ok <- Portable.validate(canonical(outcome)) do
      {:ok, outcome}
    end
  end

  @doc "Returns true when Evidence proves that no external effect occurred."
  @spec definitive_no_effect?(t()) :: boolean()
  def definitive_no_effect?(%__MODULE__{status: :definitive_no_effect}), do: true
  def definitive_no_effect?(%__MODULE__{}), do: false

  @doc "Returns true for a concrete late observation correcting a prior no-effect claim."
  @spec correction?(t()) :: boolean()
  def correction?(%__MODULE__{contradicts_outcome_ref: ref}),
    do: is_binary(ref) and ref != ""

  @doc "Returns the exact, versioned proposition that Evidence for an Outcome must carry."
  @spec proposition(status(), String.t(), String.t(), String.t()) :: map()
  def proposition(status, act_ref, attempt_ref, executor_contract_ref) do
    %{
      "contract_ref" => @proposition_contract_ref,
      "status" => status,
      "act_ref" => act_ref,
      "attempt_ref" => attempt_ref,
      "executor_contract_ref" => executor_contract_ref
    }
  end

  @doc "Returns the Evidence stance required for an Outcome status."
  @spec evidence_stance(status()) :: :supports
  def evidence_stance(status) when status in @statuses, do: :supports

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = outcome) do
    Portable.canonical_fields(outcome, @fields)
  end

  @doc "Restores an outcome from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :outcome)

  @doc "Returns the stable digest of the complete outcome."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = outcome), do: outcome |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived outcome reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = outcome), do: Portable.content_ref!(:outcome, content(outcome))

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:outcome, ref, content(attrs))

  defp content(%__MODULE__{} = outcome), do: outcome |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    Portable.canonical_fields(attrs, @fields -- [:ref])
  end

  defp validate_record(%__MODULE__{} = outcome) do
    cond do
      outcome.schema_version != @schema_version ->
        {:error, {:unsupported_outcome_schema_version, outcome.schema_version}}

      outcome.status not in @statuses ->
        {:error, {:invalid_outcome_status, outcome.status}}

      outcome.status != :ambiguous and outcome.evidence_refs == [] ->
        {:error, {:missing_outcome_evidence, outcome.status}}

      not is_nil(outcome.contradicts_outcome_ref) and
          outcome.status not in [:succeeded, :failed] ->
        {:error, {:invalid_outcome_correction_status, outcome.status}}

      not is_integer(outcome.observed_at) ->
        {:error, {:invalid_outcome_observed_at, outcome.observed_at}}

      true ->
        with :ok <- Portable.validate_ref(outcome.ref, :ref),
             :ok <- Portable.validate_ref(outcome.act_ref, :act_ref),
             :ok <- Portable.validate_ref(outcome.attempt_ref, :attempt_ref),
             :ok <- Portable.validate_refs(outcome.evidence_refs, :evidence_refs),
             :ok <- Portable.validate_ref(outcome.details_ref, :details_ref),
             :ok <- optional_ref(outcome.contradicts_outcome_ref, :contradicts_outcome_ref) do
          :ok
        end
    end
  end

  defp optional_ref(nil, _field), do: :ok
  defp optional_ref(ref, field), do: Portable.validate_ref(ref, field)
end
