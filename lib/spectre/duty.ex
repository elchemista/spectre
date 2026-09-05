defmodule Spectre.Duty do
  @moduledoc """
  Durable normative debt derived from unresolved canonical facts.

  `cause_key` is the idempotency key for materializing a required duty.  A
  duty never expires by timer, restart or deployment.  A disposed projection
  must point at the later Act that authorized its disposition; the original
  cause and evidence remain unchanged. `conflict_refs` freezes both interested
  principals and the causal Mandate reference so independence can be verified
  from the ledger rather than inferred from the current configuration.

  `Spectre.Duty.Derive` is the pure cause-family facade. Commit materializes
  missing causes idempotently, while `GovernedAct.Transition.Duty` proves and
  replays disposition. The record itself contains no scheduler or policy
  callback.
  """

  require Spectre.Portable

  alias Spectre.Portable

  @schema_version 1
  @statuses [:open, :disposed]
  @core_classes [
    :ambiguous_outcome,
    :contradicted_outcome,
    :disputed_evidence,
    :scope_promise_overdue,
    :erasure_reduces_verifiability
  ]
  @configurable_core_classes @core_classes
  @core_classes_by_name Map.new(@core_classes, &{Atom.to_string(&1), &1})
  @fields [
    :schema_version,
    :ref,
    :cause_key,
    :class,
    :act_ref,
    :attempt_ref,
    :mandate_ref,
    :subjects,
    :accountable,
    :evidence_refs,
    :missing,
    :containment,
    :closing_conditions,
    :disposition_authority_refs,
    :conflict_refs,
    :opened_at,
    :status,
    :disposition_act_ref
  ]
  @cause_fields @fields -- [:status, :disposition_act_ref]

  @enforce_keys @fields
  defstruct @fields

  @type class ::
          :ambiguous_outcome
          | :contradicted_outcome
          | :disputed_evidence
          | :scope_promise_overdue
          | :erasure_reduces_verifiability
          | String.t()

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          cause_key: term(),
          class: class(),
          act_ref: String.t() | nil,
          attempt_ref: String.t() | nil,
          mandate_ref: String.t() | nil,
          subjects: [String.t()],
          accountable: String.t(),
          evidence_refs: [String.t()],
          missing: [term()],
          containment: term(),
          closing_conditions: [term()],
          disposition_authority_refs: [String.t()],
          conflict_refs: [String.t()],
          opened_at: integer(),
          status: :open | :disposed,
          disposition_act_ref: String.t() | nil
        }

  @doc "Builds and validates a duty projection."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = duty), do: duty |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :duty),
         attrs <- defaults(attrs),
         {:ok, class} <- normalize_class(Map.get(attrs, :class)),
         attrs = Map.put(attrs, :class, class),
         {:ok, attrs} <- normalize_ref_sets(attrs),
         {:ok, cause_key} <- resolve_cause_key(Map.get(attrs, :cause_key), attrs),
         attrs = Map.put(attrs, :cause_key, cause_key),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), cause_key),
         duty = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(duty),
         :ok <- Portable.validate(canonical(duty)) do
      {:ok, duty}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = duty) do
    Portable.canonical_fields(duty, @fields)
  end

  @doc "Restores a duty from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :duty)

  @doc "Returns the stable digest of the complete duty projection."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = duty), do: duty |> canonical() |> Portable.digest!()

  @doc "Returns the stable reference derived only from the idempotent cause key."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{cause_key: cause_key}),
    do: Portable.content_ref!(:duty, %{"cause_key" => cause_key})

  @doc false
  @spec same_cause?(t(), t()) :: boolean()
  def same_cause?(%__MODULE__{} = left, %__MODULE__{} = right) do
    Map.take(left, @cause_fields) == Map.take(right, @cause_fields)
  end

  @doc false
  @spec normalize_class(term()) :: {:ok, class()} | {:error, term()}
  def normalize_class(class) when class in @core_classes, do: {:ok, class}

  def normalize_class(class) when is_binary(class) do
    case Map.fetch(@core_classes_by_name, class) do
      {:ok, core_class} -> {:ok, core_class}
      :error -> if application_class?(class), do: {:ok, class}, else: invalid_class(class)
    end
  end

  def normalize_class(class), do: invalid_class(class)

  @doc false
  @spec configurable_class?(term()) :: boolean()
  def configurable_class?(class) do
    case normalize_class(class) do
      {:ok, normalized} -> normalized in @configurable_core_classes or is_binary(normalized)
      {:error, _reason} -> false
    end
  end

  @doc false
  @spec application_class?(term()) :: boolean()
  def application_class?(class) when is_binary(class) do
    case String.split(class, ".", trim: false) do
      [_unqualified] -> false
      segments -> Enum.all?(segments, &(&1 != "" and String.trim(&1) == &1))
    end
  end

  def application_class?(_class), do: false

  defp defaults(attrs) do
    default_conflicts =
      case Map.get(attrs, :accountable) do
        accountable when Portable.is_non_empty_binary(accountable) -> [accountable]
        _missing_or_invalid -> []
      end

    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:act_ref, nil)
    |> Map.put_new(:attempt_ref, nil)
    |> Map.put_new(:mandate_ref, nil)
    |> Map.put_new(:subjects, [])
    |> Map.put_new(:evidence_refs, [])
    |> Map.put_new(:missing, [])
    |> Map.put_new(:containment, %{})
    |> Map.put_new(:closing_conditions, [])
    |> Map.put_new(:disposition_authority_refs, [])
    |> Map.put_new(:conflict_refs, default_conflicts)
    |> Map.put_new(:status, :open)
    |> Map.put_new(:disposition_act_ref, nil)
  end

  defp resolve_cause_key(nil, attrs) do
    Portable.content_ref(:duty_cause, %{
      "class" => Map.get(attrs, :class),
      "act_ref" => Map.get(attrs, :act_ref),
      "attempt_ref" => Map.get(attrs, :attempt_ref)
    })
  end

  defp resolve_cause_key(value, _attrs), do: {:ok, value}

  defp normalize_ref_sets(attrs) do
    with {:ok, subjects} <- Portable.normalize_refs(Map.fetch!(attrs, :subjects), :subjects),
         {:ok, evidence} <-
           Portable.normalize_refs(Map.fetch!(attrs, :evidence_refs), :evidence_refs),
         {:ok, authorities} <-
           Portable.normalize_refs(
             Map.fetch!(attrs, :disposition_authority_refs),
             :disposition_authority_refs
           ),
         {:ok, conflicts} <-
           Portable.normalize_refs(
             Map.fetch!(attrs, :conflict_refs),
             :conflict_refs
           ) do
      {:ok,
       attrs
       |> Map.put(:subjects, subjects)
       |> Map.put(:evidence_refs, evidence)
       |> Map.put(:disposition_authority_refs, authorities)
       |> Map.put(:conflict_refs, conflicts)}
    end
  end

  defp resolve_ref(ref, cause_key),
    do: Portable.resolve_content_ref(:duty, ref, %{"cause_key" => cause_key})

  defp validate_record(%__MODULE__{} = duty) do
    cond do
      duty.schema_version != @schema_version ->
        {:error, {:unsupported_duty_schema_version, duty.schema_version}}

      duty.status not in @statuses ->
        {:error, {:invalid_duty_status, duty.status}}

      duty.status == :open and not is_nil(duty.disposition_act_ref) ->
        {:error, :open_duty_has_disposition_act}

      duty.status == :disposed and is_nil(duty.disposition_act_ref) ->
        {:error, :disposed_duty_missing_disposition_act}

      true ->
        validate_obligation(duty)
    end
  end

  defp validate_obligation(duty) do
    cond do
      not is_list(duty.missing) ->
        {:error, {:invalid_duty_missing, Portable.shape(duty.missing)}}

      not is_list(duty.closing_conditions) ->
        {:error, {:invalid_duty_closing_conditions, Portable.shape(duty.closing_conditions)}}

      not is_integer(duty.opened_at) ->
        {:error, {:invalid_duty_opened_at, duty.opened_at}}

      not is_nil(duty.attempt_ref) and is_nil(duty.act_ref) ->
        {:error, :duty_attempt_without_act}

      duty.accountable not in duty.conflict_refs ->
        {:error, :duty_accountable_conflict_required}

      true ->
        with :ok <- validate_refs(duty), do: validate_class_contract(duty)
    end
  end

  defp validate_refs(duty) do
    with :ok <- Portable.validate_ref(duty.ref, :ref),
         :ok <- validate_cause_key(duty.cause_key),
         :ok <- Portable.validate_optional_ref(duty.act_ref, :act_ref),
         :ok <- Portable.validate_optional_ref(duty.attempt_ref, :attempt_ref),
         :ok <- Portable.validate_optional_ref(duty.mandate_ref, :mandate_ref),
         :ok <- Portable.validate_refs(duty.subjects, :subjects),
         :ok <- Portable.validate_ref(duty.accountable, :accountable),
         :ok <- Portable.validate_refs(duty.evidence_refs, :evidence_refs),
         :ok <-
           Portable.validate_refs(
             duty.disposition_authority_refs,
             :disposition_authority_refs
           ),
         :ok <- Portable.validate_refs(duty.conflict_refs, :conflict_refs) do
      Portable.validate_optional_ref(duty.disposition_act_ref, :disposition_act_ref)
    end
  end

  defp validate_cause_key(nil), do: {:error, :missing_duty_cause_key}
  defp validate_cause_key(value), do: Portable.validate(value)

  defp validate_class_contract(%__MODULE__{}), do: :ok

  defp invalid_class(class), do: {:error, {:invalid_duty_class, class}}
end
