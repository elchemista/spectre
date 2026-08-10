defmodule Spectre.Governance.GC.Plan do
  @moduledoc """
  Content-addressed conservative garbage-collection decision.

  A plan is evidence, not a delete command. Backends may execute eligible
  entries only while holding a transaction/lease that revalidates the same
  reference inventory; core never promises safe deletion from a stale scan.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Governance.Data

  @schema_version 1
  @candidate_reason_order ~w(inventory_not_complete retention_not_gc_eligible live_reference candidate_lineage_reference)
  @definition_reason_order ~w(inventory_not_complete retention_not_gc_eligible live_reference retained_candidate_reference definition_lineage_reference)
  @fields [
    :schema_version,
    :store_identity,
    :inventory_complete,
    :candidate_inventory,
    :definition_inventory,
    :candidate_decisions,
    :definition_decisions,
    :protected_candidate_refs,
    :protected_definition_refs,
    :requested_candidate_refs,
    :requested_definition_refs,
    :evidence_digest,
    :digest
  ]
  @enforce_keys [
    :schema_version,
    :store_identity,
    :inventory_complete,
    :candidate_inventory,
    :definition_inventory,
    :candidate_decisions,
    :definition_decisions,
    :protected_candidate_refs,
    :protected_definition_refs,
    :requested_candidate_refs,
    :requested_definition_refs,
    :evidence_digest,
    :digest
  ]
  defstruct schema_version: @schema_version,
            store_identity: nil,
            inventory_complete: false,
            candidate_inventory: [],
            definition_inventory: [],
            candidate_decisions: [],
            definition_decisions: [],
            protected_candidate_refs: [],
            protected_definition_refs: [],
            requested_candidate_refs: [],
            requested_definition_refs: [],
            evidence_digest: nil,
            digest: nil

  @type t :: %__MODULE__{}

  @doc false
  @spec build(map()) :: {:ok, t()} | {:error, term()}
  def build(attrs) when is_map(attrs) do
    base = Map.put(attrs, :schema_version, @schema_version)
    data = data_without_digest(base)

    with {:ok, ^data} <- Data.normalize(data),
         :ok <- validate_data(data) do
      digest = Value.digest!(data)
      {:ok, struct!(__MODULE__, Map.put(base, :digest, digest))}
    else
      {:ok, _normalized} -> {:error, :nonportable_governance_gc_plan}
      {:error, _reason} = error -> error
    end
  rescue
    KeyError -> {:error, :incomplete_governance_gc_plan}
    ArgumentError -> {:error, :invalid_governance_gc_plan}
  end

  @doc "Returns portable GC-plan evidence."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = plan),
    do: Map.put(data_without_digest(Map.from_struct(plan)), "digest", plan.digest)

  @doc "Restores and verifies portable GC-plan evidence."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) when is_map(data) and not is_struct(data) do
    expected_fields = Enum.map(@fields, &Atom.to_string/1)

    with [] <- Map.keys(data) -- expected_fields,
         [] <- expected_fields -- Map.keys(data),
         @schema_version <- Map.get(data, "schema_version"),
         attrs =
           @fields
           |> List.delete(:digest)
           |> Map.new(&{&1, Map.get(data, Atom.to_string(&1))}),
         {:ok, plan} <- build(attrs),
         true <- plan.digest == Map.get(data, "digest"),
         true <- to_data(plan) == data do
      {:ok, plan}
    else
      [_first | _rest] = fields ->
        {:error, {:invalid_governance_gc_plan_fields, fields}}

      version when is_integer(version) ->
        {:error, {:unsupported_governance_gc_plan_schema, version}}

      false ->
        {:error, :governance_gc_plan_integrity_mismatch}

      {:error, _reason} = error ->
        error

      _value ->
        {:error, :invalid_governance_gc_plan_data}
    end
  end

  def from_data(value), do: {:error, {:invalid_governance_gc_plan_data, shape(value)}}

  @doc "Encodes a GC plan with the production canonical codec."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = plan), do: plan |> to_data() |> Value.encode()

  @doc "Decodes and verifies canonical GC-plan evidence."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_governance_gc_plan_binary, shape(value)}}

  @doc "Verifies plan structure, conservative decisions, and content identity."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = plan) do
    data = plan |> Map.from_struct() |> data_without_digest()

    case Value.digest(data) do
      {:ok, expected} when plan.digest != expected ->
        {:error, {:governance_gc_plan_digest_mismatch, plan.digest, expected}}

      {:ok, _expected} ->
        case from_data(to_data(plan)) do
          {:ok, ^plan} -> :ok
          {:ok, _restored} -> {:error, :governance_gc_plan_integrity_mismatch}
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, {:invalid_governance_gc_plan, reason}}
    end
  end

  defp validate_data(data) do
    with true <- is_boolean(data["inventory_complete"]),
         :ok <- valid_digest(data["evidence_digest"]),
         {:ok, candidate_inventory} <-
           ref_list(data["candidate_inventory"], "candidate:sha256:"),
         {:ok, definition_inventory} <- ref_list(data["definition_inventory"], "sha256:"),
         {:ok, protected_candidates} <-
           ref_list(data["protected_candidate_refs"], "candidate:sha256:"),
         {:ok, protected_definitions} <-
           ref_list(data["protected_definition_refs"], "sha256:"),
         {:ok, requested_candidates} <-
           ref_list(data["requested_candidate_refs"], "candidate:sha256:"),
         {:ok, requested_definitions} <-
           ref_list(data["requested_definition_refs"], "sha256:"),
         :ok <- subset(protected_candidates, candidate_inventory, :protected_candidates),
         :ok <- subset(protected_definitions, definition_inventory, :protected_definitions),
         :ok <- subset(requested_candidates, candidate_inventory, :requested_candidates),
         :ok <- subset(requested_definitions, definition_inventory, :requested_definitions),
         {:ok, candidate_decisions} <-
           candidate_decisions(
             data["candidate_decisions"],
             candidate_inventory,
             definition_inventory,
             data["inventory_complete"],
             protected_candidates,
             requested_candidates
           ),
         {:ok, definition_decisions} <-
           definition_decisions(
             data["definition_decisions"],
             definition_inventory,
             data["inventory_complete"],
             protected_definitions,
             requested_definitions
           ),
         :ok <- retained_candidate_definitions(candidate_decisions, definition_decisions) do
      :ok
    else
      false -> {:error, :invalid_governance_gc_plan_shape}
      {:error, _reason} = error -> error
    end
  end

  defp candidate_decisions(
         decisions,
         inventory,
         definition_inventory,
         complete?,
         protected,
         requested
       )
       when is_list(decisions) do
    with {:ok, normalized} <-
           normalize_decisions(decisions, :candidate, @candidate_reason_order),
         true <- Enum.map(normalized, & &1["ref"]) == inventory,
         true <-
           Enum.all?(normalized, &(&1["definition_ref"] in definition_inventory)),
         :ok <-
           conservative_decisions(normalized, complete?, protected, requested) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_governance_gc_candidate_decisions}
      {:error, _reason} = error -> error
    end
  end

  defp candidate_decisions(_value, _inventory, _definitions, _complete, _protected, _requested),
    do: {:error, :invalid_governance_gc_candidate_decisions}

  defp definition_decisions(decisions, inventory, complete?, protected, requested)
       when is_list(decisions) do
    with {:ok, normalized} <-
           normalize_decisions(decisions, :definition, @definition_reason_order),
         true <- Enum.map(normalized, & &1["ref"]) == inventory,
         :ok <- conservative_decisions(normalized, complete?, protected, requested) do
      {:ok, normalized}
    else
      false -> {:error, :invalid_governance_gc_definition_decisions}
      {:error, _reason} = error -> error
    end
  end

  defp definition_decisions(_value, _inventory, _complete, _protected, _requested),
    do: {:error, :invalid_governance_gc_definition_decisions}

  defp normalize_decisions(decisions, kind, reason_order) do
    decisions
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {decision, index}, {:ok, normalized} ->
      case normalize_decision(decision, kind, reason_order) do
        {:ok, decision} ->
          {:cont, {:ok, [decision | normalized]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_governance_gc_decision, kind, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end)
  end

  defp normalize_decision(decision, :candidate, reason_order)
       when is_map(decision) and not is_struct(decision) do
    with [] <- Map.keys(decision) -- ~w(ref definition_ref decision reasons),
         [] <- ~w(ref definition_ref decision reasons) -- Map.keys(decision),
         true <- valid_ref?(decision["ref"], "candidate:sha256:"),
         true <- valid_ref?(decision["definition_ref"], "sha256:"),
         :ok <- decision_and_reasons(decision, reason_order) do
      {:ok, decision}
    else
      _value -> {:error, :invalid_candidate_decision}
    end
  end

  defp normalize_decision(decision, :definition, reason_order)
       when is_map(decision) and not is_struct(decision) do
    with [] <- Map.keys(decision) -- ~w(ref decision reasons),
         [] <- ~w(ref decision reasons) -- Map.keys(decision),
         true <- valid_ref?(decision["ref"], "sha256:"),
         :ok <- decision_and_reasons(decision, reason_order) do
      {:ok, decision}
    else
      _value -> {:error, :invalid_definition_decision}
    end
  end

  defp normalize_decision(_value, _kind, _reason_order),
    do: {:error, :invalid_decision_shape}

  defp decision_and_reasons(decision, reason_order) do
    reasons = decision["reasons"]

    with :ok <- validate_decision(decision["decision"]),
         :ok <- validate_reasons(reasons, reason_order),
         :ok <- validate_reason_order(reasons, reason_order) do
      validate_reason_presence(decision["decision"], reasons)
    end
  end

  defp validate_decision(decision) when decision in ["eligible", "retained"], do: :ok
  defp validate_decision(_decision), do: {:error, :invalid_decision}

  defp validate_reasons(reasons, reason_order) when is_list(reasons) do
    if Enum.all?(reasons, &(is_binary(&1) and &1 in reason_order)),
      do: :ok,
      else: {:error, :invalid_decision_reasons}
  end

  defp validate_reasons(_reasons, _reason_order), do: {:error, :invalid_decision_reasons}

  defp validate_reason_order(reasons, reason_order) do
    ordered = Enum.sort_by(reasons, &reason_index(&1, reason_order))

    if reasons == Enum.uniq(reasons) and reasons == ordered,
      do: :ok,
      else: {:error, :noncanonical_decision_reasons}
  end

  defp reason_index(reason, reason_order), do: Enum.find_index(reason_order, &(&1 == reason))

  defp validate_reason_presence("eligible", []), do: :ok

  defp validate_reason_presence("eligible", _reasons),
    do: {:error, :eligible_decision_has_reasons}

  defp validate_reason_presence("retained", [_first | _rest]), do: :ok
  defp validate_reason_presence("retained", []), do: {:error, :retained_decision_requires_reason}

  defp conservative_decisions(decisions, complete?, protected, requested) do
    protected = MapSet.new(protected)
    requested = MapSet.new(requested)

    Enum.reduce_while(decisions, :ok, fn decision, :ok ->
      ref = decision["ref"]
      reasons = decision["reasons"]

      required =
        []
        |> maybe_reason(not complete?, "inventory_not_complete")
        |> maybe_reason(not MapSet.member?(requested, ref), "retention_not_gc_eligible")
        |> maybe_reason(MapSet.member?(protected, ref), "live_reference")

      cond do
        not Enum.all?(required, &(&1 in reasons)) ->
          {:halt, {:error, {:unsafe_governance_gc_decision, ref}}}

        decision["decision"] == "eligible" and
            (not complete? or not MapSet.member?(requested, ref) or
               MapSet.member?(protected, ref)) ->
          {:halt, {:error, {:unsafe_governance_gc_eligibility, ref}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp retained_candidate_definitions(candidate_decisions, definition_decisions) do
    retained_definitions =
      definition_decisions
      |> Enum.filter(&(&1["decision"] == "retained"))
      |> MapSet.new(& &1["ref"])

    case Enum.find(candidate_decisions, fn decision ->
           decision["decision"] == "retained" and
             not MapSet.member?(retained_definitions, decision["definition_ref"])
         end) do
      nil -> :ok
      decision -> {:error, {:retained_candidate_definition_not_retained, decision["ref"]}}
    end
  end

  defp ref_list(values, prefix) when is_list(values) do
    if Enum.all?(values, &valid_ref?(&1, prefix)) and values == Enum.uniq(values) and
         values == Enum.sort(values),
       do: {:ok, values},
       else: {:error, {:invalid_governance_gc_ref_list, prefix}}
  end

  defp ref_list(_value, prefix), do: {:error, {:invalid_governance_gc_ref_list, prefix}}

  defp valid_ref?(value, prefix) when is_binary(value) do
    case String.split_at(value, byte_size(prefix)) do
      {^prefix, digest} -> match?({:ok, <<_::256>>}, Base.decode16(digest, case: :mixed))
      _other -> false
    end
  end

  defp valid_ref?(_value, _prefix), do: false

  defp valid_digest(value) when is_binary(value) and byte_size(value) == 64 do
    if match?({:ok, <<_::256>>}, Base.decode16(value, case: :mixed)),
      do: :ok,
      else: {:error, :invalid_governance_gc_evidence_digest}
  end

  defp valid_digest(_value), do: {:error, :invalid_governance_gc_evidence_digest}

  defp subset(values, inventory, field) do
    case values -- inventory do
      [] -> :ok
      missing -> {:error, {:governance_gc_refs_outside_inventory, field, missing}}
    end
  end

  defp maybe_reason(reasons, true, reason), do: reasons ++ [reason]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp data_without_digest(attrs) do
    %{
      "schema_version" => Map.fetch!(attrs, :schema_version),
      "store_identity" => Map.fetch!(attrs, :store_identity),
      "inventory_complete" => Map.fetch!(attrs, :inventory_complete),
      "candidate_inventory" => Map.fetch!(attrs, :candidate_inventory),
      "definition_inventory" => Map.fetch!(attrs, :definition_inventory),
      "candidate_decisions" => Map.fetch!(attrs, :candidate_decisions),
      "definition_decisions" => Map.fetch!(attrs, :definition_decisions),
      "protected_candidate_refs" => Map.fetch!(attrs, :protected_candidate_refs),
      "protected_definition_refs" => Map.fetch!(attrs, :protected_definition_refs),
      "requested_candidate_refs" => Map.fetch!(attrs, :requested_candidate_refs),
      "requested_definition_refs" => Map.fetch!(attrs, :requested_definition_refs),
      "evidence_digest" => Map.fetch!(attrs, :evidence_digest)
    }
  end

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
