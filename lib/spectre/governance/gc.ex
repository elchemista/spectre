defmodule Spectre.Governance.GC do
  @moduledoc """
  Conservative administered GC planner for immutable governance artifacts.

  Hosts may provide a partial Candidate/Definition inventory for a conservative
  retain-only plan, or explicitly mark it complete after including all live
  activation, Run, checkpoint, state-binding, and lineage references. Anything
  not explicitly marked `gc_eligible` remains retained. The result is a
  content-addressed `Plan`; deletion belongs to a backend transaction that can
  revalidate the inventory under its own fence.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Manifest
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Store
  alias Spectre.Governance.Data
  alias Spectre.Governance.GC.InventoryProvider
  alias Spectre.Governance.GC.Plan
  alias Spectre.Instance.Activation

  @doc "Builds a conservative GC decision from an explicit inventory."
  @spec plan(Store.config(), [CandidateRef.t() | String.t()], keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def plan(store, candidate_refs, opts \\ [])

  def plan(store, candidate_refs, opts) when is_list(candidate_refs) and is_list(opts) do
    complete? = Keyword.get(opts, :inventory_complete?, false) == true

    with {:ok, inventory_snapshot} <- inventory_snapshot(store, complete?, opts),
         {:ok, candidate_inventory} <- candidate_refs(candidate_refs),
         :ok <-
           snapshot_inventory(
             candidate_inventory,
             inventory_snapshot,
             "candidate_refs",
             :candidate
           ),
         {:ok, candidates} <- fetch_candidates(store, candidate_inventory, opts),
         {:ok, definition_inventory} <- definition_inventory(candidates, opts),
         :ok <-
           snapshot_inventory(
             definition_inventory,
             inventory_snapshot,
             "definition_refs",
             :definition
           ),
         {:ok, definitions} <- fetch_definitions(store, definition_inventory, opts),
         {:ok, store_identity} <- Store.identity(store),
         {:ok, store_identity} <- Data.quote(store_identity),
         {:ok, protected_candidates} <- protected_candidates(opts, inventory_snapshot),
         {:ok, protected_definitions} <- protected_definitions(opts, inventory_snapshot),
         {:ok, requested_candidates} <-
           candidate_refs(Keyword.get(opts, :gc_eligible_candidate_refs, [])),
         {:ok, requested_definitions} <-
           definition_refs(Keyword.get(opts, :gc_eligible_definition_refs, [])),
         :ok <- inventory_contains(candidate_inventory, requested_candidates, :candidate),
         :ok <- inventory_contains(definition_inventory, requested_definitions, :definition) do
      with :ok <-
             complete_inventory(
               complete?,
               candidate_inventory,
               candidates,
               definition_inventory,
               definitions,
               protected_candidates,
               protected_definitions
             ) do
        candidate_lineage_refs =
          candidates
          |> candidate_lineage_refs()
          |> inventory_lineage_refs(candidate_inventory, complete?)

        definition_lineage_refs =
          definitions
          |> definition_lineage_refs()
          |> inventory_lineage_refs(definition_inventory, complete?)

        candidate_decisions =
          decide_candidates(
            candidates,
            complete?,
            MapSet.new(protected_candidates),
            MapSet.new(requested_candidates)
          )

        retained_candidate_definitions =
          candidate_decisions
          |> Enum.filter(&(&1["decision"] == "retained"))
          |> Enum.map(& &1["definition_ref"])
          |> MapSet.new()

        definition_decisions =
          decide_definitions(
            definitions,
            complete?,
            MapSet.new(protected_definitions),
            MapSet.new(requested_definitions),
            retained_candidate_definitions
          )

        evidence = %{
          "candidates" => candidate_inventory,
          "definitions" => definition_inventory,
          "candidate_digests" => Enum.map(candidates, & &1.digest),
          "definition_manifest_digests" => Enum.map(definitions, & &1.manifest_digest),
          "candidate_lineage_refs" => candidate_lineage_refs,
          "definition_lineage_refs" => definition_lineage_refs,
          "inventory_snapshot_digest" => snapshot_digest(inventory_snapshot)
        }

        Plan.build(%{
          store_identity: store_identity,
          inventory_complete: complete?,
          candidate_inventory: candidate_inventory,
          definition_inventory: definition_inventory,
          candidate_decisions: candidate_decisions,
          definition_decisions: definition_decisions,
          protected_candidate_refs: protected_candidates,
          protected_definition_refs: protected_definitions,
          candidate_lineage_refs: candidate_lineage_refs,
          definition_lineage_refs: definition_lineage_refs,
          requested_candidate_refs: requested_candidates,
          requested_definition_refs: requested_definitions,
          inventory_snapshot_digest: snapshot_digest(inventory_snapshot),
          evidence_digest: Value.digest!(evidence)
        })
      end
    end
  end

  def plan(_store, candidate_refs, opts),
    do: {:error, {:invalid_governance_gc_input, shape(candidate_refs), shape(opts)}}

  defp fetch_candidates(store, refs, opts) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, candidates} ->
      case Store.fetch_candidate(store, ref, store_opts(opts)) do
        {:ok, candidate} ->
          entry = %{
            ref: ref,
            digest: Candidate.digest(candidate),
            definition_ref: to_string(candidate.definition_ref),
            parent_ref: candidate.parent_ref && to_string(candidate.parent_ref),
            lineage_refs: (candidate.governance && candidate.governance.lineage_refs) || []
          }

          {:cont, {:ok, [entry | candidates]}}

        :not_found ->
          {:halt, {:error, {:gc_candidate_not_found, ref}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> reverse()
  end

  defp definition_inventory(candidates, opts) do
    explicit = Keyword.get(opts, :definition_refs, [])

    with {:ok, explicit} <- definition_refs(explicit) do
      {:ok, (explicit ++ Enum.map(candidates, & &1.definition_ref)) |> Enum.uniq() |> Enum.sort()}
    end
  end

  defp fetch_definitions(store, refs, opts) do
    Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, definitions} ->
      case Store.fetch(store, ref, store_opts(opts)) do
        {:ok, artifact} ->
          entry = %{
            ref: ref,
            manifest_digest: Manifest.digest(artifact.manifest),
            parent_refs: Enum.map(artifact.manifest.parent_refs, &to_string/1)
          }

          {:cont, {:ok, [entry | definitions]}}

        :not_found ->
          {:halt, {:error, {:gc_definition_not_found, ref}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> reverse()
  end

  defp protected_candidates(opts, inventory_snapshot) do
    fields = [
      :protected_candidate_refs,
      :run_candidate_refs,
      :checkpoint_candidate_refs,
      :state_binding_candidate_refs,
      :lineage_candidate_refs
    ]

    configured = Enum.map(fields, &Keyword.get(opts, &1, []))
    activation = Keyword.get(opts, :activation)

    activation_ref =
      if match?(%Activation{}, activation), do: [to_string(activation.candidate_ref)], else: []

    snapshot_refs = snapshot_refs(inventory_snapshot, "protected_candidate_refs")

    if Enum.all?(configured, &is_list/1),
      do: candidate_refs(List.flatten(configured) ++ activation_ref ++ snapshot_refs),
      else: {:error, {:invalid_gc_candidate_refs, :other}}
  end

  defp protected_definitions(opts, inventory_snapshot) do
    fields = [
      :protected_definition_refs,
      :run_definition_refs,
      :checkpoint_definition_refs,
      :state_binding_definition_refs,
      :lineage_definition_refs
    ]

    configured = Enum.map(fields, &Keyword.get(opts, &1, []))
    activation = Keyword.get(opts, :activation)

    activation_ref =
      if match?(%Activation{}, activation), do: [to_string(activation.definition_ref)], else: []

    snapshot_refs = snapshot_refs(inventory_snapshot, "protected_definition_refs")

    if Enum.all?(configured, &is_list/1),
      do: definition_refs(List.flatten(configured) ++ activation_ref ++ snapshot_refs),
      else: {:error, {:invalid_gc_definition_refs, :other}}
  end

  defp inventory_snapshot(_store, false, _opts), do: {:ok, nil}

  defp inventory_snapshot(store, true, opts) do
    InventoryProvider.load(Keyword.get(opts, :inventory_provider), store, store_opts(opts))
  end

  defp snapshot_inventory(_inventory, nil, _field, _kind), do: :ok

  defp snapshot_inventory(inventory, snapshot, field, kind) do
    if inventory == Map.fetch!(snapshot, field),
      do: :ok,
      else: {:error, {:governance_gc_inventory_attestation_mismatch, kind}}
  end

  defp snapshot_refs(nil, _field), do: []
  defp snapshot_refs(snapshot, field), do: Map.fetch!(snapshot, field)

  defp snapshot_digest(nil), do: nil
  defp snapshot_digest(snapshot), do: Map.fetch!(snapshot, "digest")

  defp complete_inventory(
         false,
         _candidate_refs,
         _candidates,
         _definition_refs,
         _definitions,
         _protected_candidates,
         _protected_definitions
       ),
       do: :ok

  defp complete_inventory(
         true,
         candidate_refs,
         candidates,
         definition_refs,
         definitions,
         protected_candidates,
         protected_definitions
       ) do
    candidate_references =
      candidates
      |> Enum.flat_map(&[&1.parent_ref | &1.lineage_refs])
      |> Enum.reject(&is_nil/1)

    definition_references = Enum.flat_map(definitions, & &1.parent_refs)

    with :ok <-
           reference_closure(
             candidate_refs,
             candidate_references ++ protected_candidates,
             :candidate
           ) do
      reference_closure(
        definition_refs,
        definition_references ++ protected_definitions,
        :definition
      )
    end
  end

  defp reference_closure(inventory, references, kind) do
    case Enum.uniq(references) -- inventory do
      [] -> :ok
      missing -> {:error, {:incomplete_gc_inventory, kind, Enum.sort(missing)}}
    end
  end

  # A partial inventory cannot attest to artifacts it did not inspect. Those
  # missing ancestors already force every decision to remain retained through
  # `inventory_not_complete`; only in-inventory lineage belongs in the Plan's
  # evidence. Complete inventories retain the full, closure-checked lineage.
  defp inventory_lineage_refs(refs, _inventory, true), do: refs

  defp inventory_lineage_refs(refs, inventory, false) do
    inventory = MapSet.new(inventory)
    Enum.filter(refs, &MapSet.member?(inventory, &1))
  end

  defp decide_candidates(candidates, complete?, protected, requested) do
    referenced =
      candidates
      |> Enum.flat_map(&[&1.parent_ref | &1.lineage_refs])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.map(candidates, fn candidate ->
      reasons =
        []
        |> add_reason(not complete?, "inventory_not_complete")
        |> add_reason(not MapSet.member?(requested, candidate.ref), "retention_not_gc_eligible")
        |> add_reason(MapSet.member?(protected, candidate.ref), "live_reference")
        |> add_reason(MapSet.member?(referenced, candidate.ref), "candidate_lineage_reference")

      %{
        "ref" => candidate.ref,
        "definition_ref" => candidate.definition_ref,
        "decision" => if(reasons == [], do: "eligible", else: "retained"),
        "reasons" => Enum.reverse(reasons)
      }
    end)
  end

  defp decide_definitions(definitions, complete?, protected, requested, retained_candidates) do
    referenced_as_parent =
      definitions
      |> Enum.flat_map(& &1.parent_refs)
      |> MapSet.new()

    Enum.map(definitions, fn definition ->
      reasons =
        []
        |> add_reason(not complete?, "inventory_not_complete")
        |> add_reason(not MapSet.member?(requested, definition.ref), "retention_not_gc_eligible")
        |> add_reason(MapSet.member?(protected, definition.ref), "live_reference")
        |> add_reason(
          MapSet.member?(retained_candidates, definition.ref),
          "retained_candidate_reference"
        )
        |> add_reason(
          MapSet.member?(referenced_as_parent, definition.ref),
          "definition_lineage_reference"
        )

      %{
        "ref" => definition.ref,
        "decision" => if(reasons == [], do: "eligible", else: "retained"),
        "reasons" => Enum.reverse(reasons)
      }
    end)
  end

  defp candidate_lineage_refs(candidates) do
    candidates
    |> Enum.flat_map(&[&1.parent_ref | &1.lineage_refs])
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp definition_lineage_refs(definitions) do
    definitions
    |> Enum.flat_map(& &1.parent_refs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp add_reason(reasons, true, reason), do: [reason | reasons]
  defp add_reason(reasons, false, _reason), do: reasons

  defp inventory_contains(inventory, requested, kind) do
    case requested -- inventory do
      [] -> :ok
      missing -> {:error, {:gc_eligible_artifact_not_in_inventory, kind, missing}}
    end
  end

  defp candidate_refs(values) when is_list(values),
    do: normalize_refs(values, "candidate:sha256:", &CandidateRef.parse/1, :candidate)

  defp candidate_refs(value), do: {:error, {:invalid_gc_candidate_refs, shape(value)}}

  defp definition_refs(values) when is_list(values),
    do: normalize_refs(values, "sha256:", &Ref.parse/1, :definition)

  defp definition_refs(value), do: {:error, {:invalid_gc_definition_refs, shape(value)}}

  defp normalize_refs(values, prefix, parser, kind) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, refs} ->
      string = ref_string(value)

      case parser.(string) do
        {:ok, _ref} -> {:cont, {:ok, [string | refs]}}
        {:error, _reason} -> {:halt, {:error, {:invalid_gc_ref, kind, prefix, value}}}
      end
    end)
    |> then(fn
      {:ok, refs} -> {:ok, refs |> Enum.uniq() |> Enum.sort()}
      {:error, _reason} = error -> error
    end)
  end

  defp ref_string(%CandidateRef{} = ref), do: CandidateRef.to_string(ref)
  defp ref_string(%Ref{} = ref), do: Ref.to_string(ref)
  defp ref_string(value), do: value

  defp reverse({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse({:error, _reason} = error), do: error

  defp store_opts(opts),
    do: Keyword.take(opts, [:checkpoint_store, :component_registry, :now])

  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
