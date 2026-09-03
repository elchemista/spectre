defmodule Spectre.Scope.Opening do
  @moduledoc """
  Durable description of a Scope occurrence and any explicit promise it owns.

  A Scope is still only a ledger projection: opening or copying one creates no
  Mandate and no Meter allocation.  `:work` and `:vigil` openings must name a
  finite due time, a decidable closing Condition, an accountable Principal and
  an independent disposition path so unfinished work can be derived as Duty.
  """

  alias Spectre.Condition
  alias Spectre.Portable

  @schema_version 1
  @kinds [:session, :child, :work, :vigil]
  @fields [
    :schema_version,
    :ref,
    :domain_ref,
    :parent_ref,
    :kind,
    :opened_by_ref,
    :submission_context_ref,
    :authentication_ref,
    :ingress_ref,
    :channel_ref,
    :session_ref,
    :host_generation,
    :promise_condition,
    :accountable_ref,
    :disposition_authority_refs,
    :source_act_ref,
    :opened_at,
    :due_at
  ]
  @governed_draft_fields @fields -- [:source_act_ref, :opened_at]
  @pending_source_act_ref "spectre:scope:pending-source-act"

  @enforce_keys [
    :schema_version,
    :ref,
    :domain_ref,
    :kind,
    :opened_by_ref,
    :submission_context_ref,
    :authentication_ref,
    :ingress_ref,
    :host_generation,
    :disposition_authority_refs,
    :opened_at
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            domain_ref: nil,
            parent_ref: nil,
            kind: :session,
            opened_by_ref: nil,
            submission_context_ref: nil,
            authentication_ref: nil,
            ingress_ref: nil,
            channel_ref: nil,
            session_ref: nil,
            host_generation: nil,
            promise_condition: nil,
            accountable_ref: nil,
            disposition_authority_refs: [],
            source_act_ref: nil,
            opened_at: nil,
            due_at: nil

  @type kind :: :session | :child | :work | :vigil
  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          domain_ref: String.t(),
          parent_ref: String.t() | nil,
          kind: kind(),
          opened_by_ref: String.t(),
          submission_context_ref: String.t(),
          authentication_ref: String.t(),
          ingress_ref: String.t(),
          channel_ref: String.t() | nil,
          session_ref: String.t() | nil,
          host_generation: non_neg_integer(),
          promise_condition: Condition.t() | nil,
          accountable_ref: String.t() | nil,
          disposition_authority_refs: [String.t()],
          source_act_ref: String.t() | nil,
          opened_at: integer(),
          due_at: integer() | nil
        }

  @doc "Builds and validates a Scope opening."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = opening), do: opening |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :scope_opening),
         attrs <- defaults(attrs),
         {:ok, condition} <- normalize_condition(Map.get(attrs, :promise_condition)),
         {:ok, authorities} <-
           Portable.normalize_refs(
             Map.fetch!(attrs, :disposition_authority_refs),
             :disposition_authority_refs
           ),
         attrs =
           attrs
           |> Map.put(:promise_condition, condition)
           |> Map.put(:disposition_authority_refs, authorities),
         opening = struct(__MODULE__, attrs),
         :ok <- validate_record(opening),
         :ok <- Portable.validate(canonical(opening)) do
      {:ok, opening}
    end
  end

  @doc "Returns whether this Scope declares a finite promise."
  @spec promised?(t()) :: boolean()
  def promised?(%__MODULE__{promise_condition: %Condition{}}), do: true
  def promised?(%__MODULE__{}), do: false

  @doc "Returns whether the opening must be authorized by a durable Act."
  @spec governed?(t()) :: boolean()
  def governed?(%__MODULE__{kind: kind}), do: kind in [:work, :vigil]

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = opening) do
    %{
      "schema_version" => opening.schema_version,
      "ref" => opening.ref,
      "domain_ref" => opening.domain_ref,
      "parent_ref" => opening.parent_ref,
      "kind" => opening.kind,
      "opened_by_ref" => opening.opened_by_ref,
      "submission_context_ref" => opening.submission_context_ref,
      "authentication_ref" => opening.authentication_ref,
      "ingress_ref" => opening.ingress_ref,
      "channel_ref" => opening.channel_ref,
      "session_ref" => opening.session_ref,
      "host_generation" => opening.host_generation,
      "promise_condition" => canonical_condition(opening.promise_condition),
      "accountable_ref" => opening.accountable_ref,
      "disposition_authority_refs" => opening.disposition_authority_refs,
      "source_act_ref" => opening.source_act_ref,
      "opened_at" => opening.opened_at,
      "due_at" => opening.due_at
    }
  end

  @doc "Restores a Scope opening from canonical data."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :scope_opening)

  @doc "Returns the stable digest of the complete opening."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = opening), do: opening |> canonical() |> Portable.digest!()

  @doc "Builds the exact Scope body frozen by a governed opening Candidate."
  @spec governed_draft(map() | keyword() | t()) :: {:ok, map()} | {:error, term()}
  def governed_draft(%__MODULE__{} = opening) do
    with {:ok, opening} <- new(opening),
         true <- governed?(opening) do
      {:ok, opening |> canonical() |> Map.drop(["source_act_ref", "opened_at"])}
    else
      false -> {:error, :governed_scope_kind_required}
      {:error, _reason} = error -> error
    end
  end

  def governed_draft(attrs) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(attrs, @governed_draft_fields, :governed_scope_opening),
         {:ok, due_at} <- governed_due_at(attrs),
         {:ok, opening} <-
           attrs
           |> Map.put(:source_act_ref, @pending_source_act_ref)
           |> Map.put(:opened_at, due_at - 1)
           |> new() do
      governed_draft(opening)
    end
  end

  @doc "Materializes a canonical governed draft under its authorizing Act."
  @spec from_governed_draft(map(), String.t(), integer()) :: {:ok, t()} | {:error, term()}
  def from_governed_draft(draft, source_act_ref, opened_at)
      when is_map(draft) and not is_struct(draft) and is_integer(opened_at) do
    with {:ok, normalized} <- governed_draft(draft),
         true <- draft == normalized,
         :ok <- Portable.validate_ref(source_act_ref, :source_act_ref) do
      normalized
      |> Map.put("source_act_ref", source_act_ref)
      |> Map.put("opened_at", opened_at)
      |> new()
    else
      false -> {:error, :noncanonical_governed_scope_draft}
      {:error, _reason} = error -> error
    end
  end

  def from_governed_draft(_draft, _source_act_ref, _opened_at),
    do: {:error, :invalid_governed_scope_draft}

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:parent_ref, nil)
    |> Map.put_new(:kind, :session)
    |> Map.put_new(:channel_ref, nil)
    |> Map.put_new(:session_ref, nil)
    |> Map.put_new(:promise_condition, nil)
    |> Map.put_new(:accountable_ref, nil)
    |> Map.put_new(:disposition_authority_refs, [])
    |> Map.put_new(:source_act_ref, nil)
    |> Map.put_new(:due_at, nil)
  end

  defp normalize_condition(nil), do: {:ok, nil}
  defp normalize_condition(value), do: Condition.new(value)

  defp governed_due_at(attrs) do
    case Map.fetch(attrs, :due_at) do
      {:ok, due_at} when is_integer(due_at) -> {:ok, due_at}
      {:ok, _invalid} -> {:error, :invalid_governed_scope_due_at}
      :error -> {:error, :governed_scope_due_at_required}
    end
  end

  defp canonical_condition(nil), do: nil
  defp canonical_condition(%Condition{} = condition), do: Condition.canonical(condition)

  defp validate_record(%__MODULE__{} = opening) do
    cond do
      opening.schema_version != @schema_version ->
        {:error, {:unsupported_scope_opening_schema_version, opening.schema_version}}

      opening.kind not in @kinds ->
        {:error, {:invalid_scope_kind, opening.kind}}

      opening.kind == :session and not is_nil(opening.parent_ref) ->
        {:error, :session_scope_may_not_have_parent}

      opening.kind != :session and is_nil(opening.parent_ref) ->
        {:error, {:scope_parent_required, opening.kind}}

      opening.kind in [:work, :vigil] and not promised?(opening) ->
        {:error, {:scope_promise_required, opening.kind}}

      opening.kind in [:session, :child] and promised?(opening) ->
        {:error, {:scope_promise_not_allowed, opening.kind}}

      governed?(opening) and is_nil(opening.source_act_ref) ->
        {:error, {:scope_source_act_required, opening.kind}}

      not governed?(opening) and not is_nil(opening.source_act_ref) ->
        {:error, {:scope_source_act_not_allowed, opening.kind}}

      not promised?(opening) and
          (not is_nil(opening.accountable_ref) or
             opening.disposition_authority_refs != [] or not is_nil(opening.due_at)) ->
        {:error, :scope_promise_fields_without_condition}

      promised?(opening) and not valid_promise?(opening) ->
        {:error, :invalid_scope_promise}

      promised?(opening) and not promise_bound_to_scope?(opening) ->
        {:error, :scope_promise_condition_not_bound_to_scope}

      not is_integer(opening.opened_at) ->
        {:error, {:invalid_scope_opened_at, opening.opened_at}}

      not (is_integer(opening.host_generation) and opening.host_generation >= 0) ->
        {:error, {:invalid_scope_host_generation, opening.host_generation}}

      true ->
        validate_refs(opening)
    end
  end

  defp valid_promise?(opening) do
    is_integer(opening.due_at) and is_integer(opening.opened_at) and
      opening.due_at > opening.opened_at and is_binary(opening.accountable_ref) and
      opening.accountable_ref != "" and opening.disposition_authority_refs != [] and
      Enum.any?(opening.disposition_authority_refs, &(&1 != opening.accountable_ref))
  end

  defp promise_bound_to_scope?(opening) do
    condition = opening.promise_condition
    minimum = Map.fetch!(condition.cardinality, "min")

    minimum > 0 and
      field(condition.bindings, :scope_ref) == opening.ref
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp validate_refs(opening) do
    with :ok <- Portable.validate_ref(opening.ref, :ref),
         :ok <- Portable.validate_ref(opening.domain_ref, :domain_ref),
         :ok <- validate_optional_ref(opening.parent_ref, :parent_ref),
         :ok <- Portable.validate_ref(opening.opened_by_ref, :opened_by_ref),
         :ok <- Portable.validate_ref(opening.submission_context_ref, :submission_context_ref),
         :ok <- Portable.validate_ref(opening.authentication_ref, :authentication_ref),
         :ok <- Portable.validate_ref(opening.ingress_ref, :ingress_ref),
         :ok <- validate_optional_ref(opening.channel_ref, :channel_ref),
         :ok <- validate_optional_ref(opening.session_ref, :session_ref),
         :ok <- validate_optional_ref(opening.accountable_ref, :accountable_ref),
         :ok <- validate_optional_ref(opening.source_act_ref, :source_act_ref),
         :ok <-
           Portable.validate_refs(
             opening.disposition_authority_refs,
             :disposition_authority_refs
           ) do
      :ok
    end
  end

  defp validate_optional_ref(nil, _field), do: :ok
  defp validate_optional_ref(value, field), do: Portable.validate_ref(value, field)
end
