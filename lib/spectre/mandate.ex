defmodule Spectre.Mandate do
  @moduledoc """
  Portable, decidable boundary of delegated authority.

  A mandate states who may propose, which executors and executor contracts may
  carry an admitted Act, what may be touched, and for which closed purpose,
  Evidence, time, resource, delegation and revocation constraints. Possessing a
  mandate reference is not an execution capability.
  """

  alias Spectre.{Condition, Evidence, Label, Portable, Row}

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :revision,
    :grantor_ref,
    :holder_ref,
    :accountable_ref,
    :executor_refs,
    :executor_contract_refs,
    :scope_refs,
    :subject_refs,
    :target_refs,
    :disclosable_labels,
    :classes,
    :ceiling,
    :purpose_ref,
    :purpose_params,
    :conditions,
    :not_before,
    :expires_at,
    :meters,
    :delegation,
    :revocation,
    :parent_ref,
    :source_ref
  ]
  @issue_draft_fields @fields -- [:ref, :source_ref]
  @draft_source_ref "spectre:pending-mandate-issue-act"

  @enforce_keys [
    :schema_version,
    :ref,
    :revision,
    :grantor_ref,
    :holder_ref,
    :accountable_ref,
    :executor_refs,
    :executor_contract_refs,
    :scope_refs,
    :subject_refs,
    :target_refs,
    :disclosable_labels,
    :classes,
    :ceiling,
    :purpose_ref,
    :purpose_params,
    :conditions,
    :not_before,
    :expires_at,
    :meters,
    :delegation,
    :revocation,
    :source_ref
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            revision: 1,
            grantor_ref: nil,
            holder_ref: nil,
            accountable_ref: nil,
            executor_refs: [],
            executor_contract_refs: [],
            scope_refs: [],
            subject_refs: [],
            target_refs: [],
            disclosable_labels: [],
            classes: [],
            ceiling: nil,
            purpose_ref: nil,
            purpose_params: %{},
            conditions: [],
            not_before: nil,
            expires_at: nil,
            meters: %{},
            delegation: %{"allowed" => false, "max_depth" => 0},
            revocation: %{"mode" => :cascade, "controller_refs" => []},
            parent_ref: nil,
            source_ref: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          revision: pos_integer(),
          grantor_ref: String.t(),
          holder_ref: String.t(),
          accountable_ref: String.t(),
          executor_refs: [String.t()],
          executor_contract_refs: [String.t()],
          scope_refs: [String.t()],
          subject_refs: [String.t()],
          target_refs: [String.t()],
          disclosable_labels: [Label.t()],
          classes: [String.t()],
          ceiling: Row.t(),
          purpose_ref: String.t(),
          purpose_params: map(),
          conditions: [Condition.t()],
          not_before: integer(),
          expires_at: integer(),
          meters: %{optional(String.t()) => non_neg_integer()},
          delegation: delegation_policy(),
          revocation: revocation_policy(),
          parent_ref: String.t() | nil,
          source_ref: String.t()
        }

  @type delegation_policy :: %{
          required(String.t()) => boolean() | non_neg_integer()
        }
  @type revocation_mode :: :cascade | :retained_controller
  @type revocation_policy :: %{
          required(String.t()) => revocation_mode() | [String.t()]
        }

  @doc "Builds and validates a mandate."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = mandate), do: mandate |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :mandate),
         attrs <- defaults(attrs),
         {:ok, ceiling} <- Row.new(Map.get(attrs, :ceiling, %{})),
         {:ok, conditions} <- normalize_conditions(Map.fetch!(attrs, :conditions)),
         {:ok, classes} <- normalize_classes(Map.fetch!(attrs, :classes)),
         {:ok, executor_refs} <-
           normalize_non_empty_refs(Map.fetch!(attrs, :executor_refs), :executor_refs),
         {:ok, executor_contract_refs} <-
           normalize_non_empty_refs(
             Map.fetch!(attrs, :executor_contract_refs),
             :executor_contract_refs
           ),
         {:ok, scope_refs} <- Portable.normalize_refs(Map.fetch!(attrs, :scope_refs), :scope_refs),
         {:ok, subject_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :subject_refs), :subject_refs),
         {:ok, target_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :target_refs), :target_refs),
         {:ok, disclosable_labels} <-
           Evidence.normalize_labels(Map.fetch!(attrs, :disclosable_labels)),
         {:ok, delegation} <- normalize_delegation(Map.fetch!(attrs, :delegation)),
         {:ok, revocation} <-
           normalize_revocation(Map.fetch!(attrs, :revocation), Map.get(attrs, :grantor_ref)),
         attrs =
           attrs
           |> Map.put(:ceiling, ceiling)
           |> Map.put(:conditions, conditions)
           |> Map.put(:classes, classes)
           |> Map.put(:executor_refs, executor_refs)
           |> Map.put(:executor_contract_refs, executor_contract_refs)
           |> Map.put(:scope_refs, scope_refs)
           |> Map.put(:subject_refs, subject_refs)
           |> Map.put(:target_refs, target_refs)
           |> Map.put(:disclosable_labels, disclosable_labels)
           |> Map.put(:delegation, delegation)
           |> Map.put(:revocation, revocation),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         mandate = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(mandate),
         :ok <- Portable.validate(canonical(mandate)) do
      {:ok, mandate}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = mandate) do
    %{
      "schema_version" => mandate.schema_version,
      "ref" => mandate.ref,
      "revision" => mandate.revision,
      "grantor_ref" => mandate.grantor_ref,
      "holder_ref" => mandate.holder_ref,
      "accountable_ref" => mandate.accountable_ref,
      "executor_refs" => mandate.executor_refs,
      "executor_contract_refs" => mandate.executor_contract_refs,
      "scope_refs" => mandate.scope_refs,
      "subject_refs" => mandate.subject_refs,
      "target_refs" => mandate.target_refs,
      "disclosable_labels" => Enum.map(mandate.disclosable_labels, &Label.canonical/1),
      "classes" => mandate.classes,
      "ceiling" => Row.canonical(mandate.ceiling),
      "purpose_ref" => mandate.purpose_ref,
      "purpose_params" => mandate.purpose_params,
      "conditions" => Enum.map(mandate.conditions, &Condition.canonical/1),
      "not_before" => mandate.not_before,
      "expires_at" => mandate.expires_at,
      "meters" => mandate.meters,
      "delegation" => mandate.delegation,
      "revocation" => mandate.revocation,
      "parent_ref" => mandate.parent_ref,
      "source_ref" => mandate.source_ref
    }
  end

  @doc "Restores a mandate from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :mandate)

  @doc "Returns the stable digest of the complete mandate."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = mandate), do: mandate |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = mandate), do: Portable.content_ref!(:mandate, content(mandate))

  @doc "Returns whether the mandate has no parent mandate."
  @spec root?(t()) :: boolean()
  def root?(%__MODULE__{parent_ref: nil}), do: true
  def root?(%__MODULE__{}), do: false

  @doc "Builds the canonical, validated body frozen by a mandate-issuance Candidate."
  @spec issue_draft(map() | keyword() | t()) :: {:ok, map()} | {:error, term()}
  def issue_draft(%__MODULE__{} = mandate) do
    with {:ok, mandate} <- new(mandate) do
      {:ok, mandate |> canonical() |> Map.drop(["ref", "source_ref"])}
    end
  end

  def issue_draft(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @issue_draft_fields, :mandate_issue),
         {:ok, mandate} <- new(Map.put(attrs, :source_ref, @draft_source_ref)) do
      issue_draft(mandate)
    end
  end

  @doc "Materializes an exact canonical issue draft under the Act that authorized it."
  @spec from_issue_draft(map(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_issue_draft(draft, source_ref) when is_map(draft) and not is_struct(draft) do
    with {:ok, normalized} <- issue_draft(draft),
         true <- draft == normalized,
         :ok <- Portable.validate_ref(source_ref, :source_ref) do
      normalized
      |> Map.put("source_ref", source_ref)
      |> new()
    else
      false -> {:error, :noncanonical_mandate_issue_draft}
      {:error, _reason} = error -> error
    end
  end

  def from_issue_draft(_draft, _source_ref), do: {:error, :invalid_mandate_issue_draft}

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:revision, 1)
    |> Map.put_new(:executor_refs, [])
    |> Map.put_new(:executor_contract_refs, [])
    |> Map.put_new(:scope_refs, [])
    |> Map.put_new(:subject_refs, [])
    |> Map.put_new(:target_refs, [])
    |> Map.put_new(:disclosable_labels, [])
    |> Map.put_new(:classes, [])
    |> Map.put_new(:purpose_params, %{})
    |> Map.put_new(:conditions, [])
    |> Map.put_new(:meters, %{})
    |> Map.put_new(:delegation, %{"allowed" => false, "max_depth" => 0})
    |> Map.put_new(:revocation, %{"mode" => :cascade})
    |> Map.put_new(:parent_ref, nil)
  end

  defp normalize_conditions(conditions) do
    with {:ok, conditions} <- normalize_condition_list(conditions, []) do
      normalize_condition_identities(conditions)
    end
  end

  defp normalize_condition_list([], normalized), do: {:ok, Enum.reverse(normalized)}

  defp normalize_condition_list([condition | rest], normalized) do
    with {:ok, condition} <- Condition.new(condition),
         do: normalize_condition_list(rest, [condition | normalized])
  end

  defp normalize_condition_list(value, _normalized),
    do: {:error, {:invalid_mandate_conditions, Portable.shape(value)}}

  defp normalize_condition_identities(conditions) do
    conditions
    |> Enum.group_by(& &1.ref)
    |> Enum.reduce_while({:ok, []}, fn {ref, same_ref}, {:ok, normalized} ->
      canonical = same_ref |> Enum.map(&Condition.canonical/1) |> Enum.uniq()

      case canonical do
        [_one] -> {:cont, {:ok, [hd(same_ref) | normalized]}}
        _conflicting -> {:halt, {:error, {:conflicting_mandate_condition_ref, ref}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, & &1.ref)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_classes(classes) do
    case Portable.normalize_refs(classes, :classes) do
      {:ok, []} -> {:error, {:invalid_mandate_classes, []}}
      {:ok, classes} -> {:ok, classes}
      {:error, _reason} -> {:error, {:invalid_mandate_classes, classes}}
    end
  end

  defp normalize_non_empty_refs(values, field) do
    case Portable.normalize_refs(values, field) do
      {:ok, []} -> {:error, {:empty_mandate_constraint, field}}
      {:ok, refs} -> {:ok, refs}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_delegation(value) when is_map(value) and not is_struct(value) do
    with {:ok, attrs} <- Portable.normalize_attrs(value, [:allowed, :max_depth], :delegation) do
      {:ok,
       %{
         "allowed" => Map.get(attrs, :allowed, false),
         "max_depth" => Map.get(attrs, :max_depth, 0)
       }}
    end
  end

  defp normalize_delegation(value),
    do: {:error, {:invalid_mandate_delegation, Portable.shape(value)}}

  defp normalize_revocation(value, grantor_ref)
       when is_map(value) and not is_struct(value) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(value, [:mode, :controller_refs], :revocation),
         {:ok, controllers} <-
           Portable.normalize_refs(
             Map.get(attrs, :controller_refs, if(grantor_ref, do: [grantor_ref], else: [])),
             :controller_refs
           ) do
      {:ok,
       %{
         "mode" => Map.get(attrs, :mode, :cascade),
         "controller_refs" => controllers
       }}
    end
  end

  defp normalize_revocation(value, _grantor_ref),
    do: {:error, {:invalid_mandate_revocation, Portable.shape(value)}}

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:mandate, ref, content(attrs))

  defp content(%__MODULE__{} = mandate), do: mandate |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    %{
      "schema_version" => Map.fetch!(attrs, :schema_version),
      "revision" => Map.fetch!(attrs, :revision),
      "grantor_ref" => Map.get(attrs, :grantor_ref),
      "holder_ref" => Map.get(attrs, :holder_ref),
      "accountable_ref" => Map.get(attrs, :accountable_ref),
      "executor_refs" => Map.fetch!(attrs, :executor_refs),
      "executor_contract_refs" => Map.fetch!(attrs, :executor_contract_refs),
      "scope_refs" => Map.fetch!(attrs, :scope_refs),
      "subject_refs" => Map.fetch!(attrs, :subject_refs),
      "target_refs" => Map.fetch!(attrs, :target_refs),
      "disclosable_labels" =>
        Enum.map(Map.fetch!(attrs, :disclosable_labels), &Label.canonical/1),
      "classes" => Map.fetch!(attrs, :classes),
      "ceiling" => Row.canonical(Map.fetch!(attrs, :ceiling)),
      "purpose_ref" => Map.get(attrs, :purpose_ref),
      "purpose_params" => Map.fetch!(attrs, :purpose_params),
      "conditions" => Enum.map(Map.fetch!(attrs, :conditions), &Condition.canonical/1),
      "not_before" => Map.get(attrs, :not_before),
      "expires_at" => Map.get(attrs, :expires_at),
      "meters" => Map.fetch!(attrs, :meters),
      "delegation" => Map.fetch!(attrs, :delegation),
      "revocation" => Map.fetch!(attrs, :revocation),
      "parent_ref" => Map.fetch!(attrs, :parent_ref),
      "source_ref" => Map.get(attrs, :source_ref)
    }
  end

  defp validate_record(%__MODULE__{} = mandate) do
    with :ok <- validate_header(mandate),
         :ok <- validate_executor_and_purpose(mandate),
         :ok <- validate_limits(mandate),
         :ok <- validate_policies(mandate),
         :ok <- validate_lineage(mandate) do
      validate_refs(mandate)
    end
  end

  defp validate_header(mandate) do
    cond do
      mandate.schema_version != @schema_version ->
        {:error, {:unsupported_mandate_schema_version, mandate.schema_version}}

      not (is_integer(mandate.revision) and mandate.revision > 0) ->
        {:error, {:invalid_mandate_revision, mandate.revision}}

      not valid_classes?(mandate.classes) ->
        {:error, {:invalid_mandate_classes, mandate.classes}}

      true ->
        :ok
    end
  end

  defp validate_executor_and_purpose(mandate) do
    cond do
      mandate.executor_refs == [] ->
        {:error, {:empty_mandate_constraint, :executor_refs}}

      mandate.executor_contract_refs == [] ->
        {:error, {:empty_mandate_constraint, :executor_contract_refs}}

      not is_map(mandate.purpose_params) or is_struct(mandate.purpose_params) ->
        {:error, {:invalid_mandate_purpose_params, Portable.shape(mandate.purpose_params)}}

      true ->
        :ok
    end
  end

  defp validate_limits(mandate) do
    cond do
      not is_integer(mandate.not_before) or not is_integer(mandate.expires_at) or
          mandate.not_before >= mandate.expires_at ->
        {:error, {:invalid_mandate_time_window, mandate.not_before, mandate.expires_at}}

      not valid_meters?(mandate.meters) ->
        {:error, {:invalid_mandate_meters, mandate.meters}}

      true ->
        :ok
    end
  end

  defp validate_policies(mandate) do
    cond do
      not valid_delegation?(mandate.delegation) ->
        {:error, {:invalid_mandate_delegation, mandate.delegation}}

      not valid_revocation?(mandate.revocation) ->
        {:error, {:invalid_mandate_revocation, mandate.revocation}}

      true ->
        :ok
    end
  end

  defp validate_lineage(%{parent_ref: ref, ref: ref}), do: {:error, :mandate_cannot_parent_itself}
  defp validate_lineage(_mandate), do: :ok

  defp validate_refs(mandate) do
    with :ok <- Portable.validate_ref(mandate.ref, :ref),
         :ok <- Portable.validate_ref(mandate.grantor_ref, :grantor_ref),
         :ok <- Portable.validate_ref(mandate.holder_ref, :holder_ref),
         :ok <- Portable.validate_ref(mandate.accountable_ref, :accountable_ref),
         :ok <- Portable.validate_refs(mandate.executor_refs, :executor_refs),
         :ok <-
           Portable.validate_refs(mandate.executor_contract_refs, :executor_contract_refs),
         :ok <- Portable.validate_refs(mandate.scope_refs, :scope_refs),
         :ok <- Portable.validate_refs(mandate.subject_refs, :subject_refs),
         :ok <- Portable.validate_refs(mandate.target_refs, :target_refs),
         :ok <- Portable.validate_ref(mandate.purpose_ref, :purpose_ref),
         :ok <- validate_optional_ref(mandate.parent_ref, :parent_ref) do
      Portable.validate_ref(mandate.source_ref, :source_ref)
    end
  end

  defp valid_meters?(meters) when is_map(meters) and not is_struct(meters) do
    Enum.all?(meters, fn {ref, ceiling} ->
      is_binary(ref) and ref != "" and is_integer(ceiling) and ceiling >= 0
    end)
  end

  defp valid_meters?(_meters), do: false

  defp valid_classes?([]), do: false

  defp valid_classes?([class | rest]) when is_binary(class) and class != "",
    do: valid_class_tail?(rest)

  defp valid_classes?(_classes), do: false

  defp valid_class_tail?([]), do: true

  defp valid_class_tail?([class | rest]) when is_binary(class) and class != "",
    do: valid_class_tail?(rest)

  defp valid_class_tail?(_classes), do: false

  defp valid_delegation?(%{"allowed" => allowed, "max_depth" => max_depth}) do
    is_boolean(allowed) and is_integer(max_depth) and max_depth >= 0 and
      ((allowed and max_depth > 0) or (not allowed and max_depth == 0))
  end

  defp valid_delegation?(_delegation), do: false

  defp valid_revocation?(%{"mode" => mode, "controller_refs" => refs}) do
    mode in [:cascade, :retained_controller] and
      match?(:ok, Portable.validate_refs(refs, :controller_refs)) and refs != []
  end

  defp valid_revocation?(_revocation), do: false

  defp validate_optional_ref(nil, _field), do: :ok
  defp validate_optional_ref(value, field), do: Portable.validate_ref(value, field)
end
