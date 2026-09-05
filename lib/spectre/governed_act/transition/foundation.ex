defmodule Spectre.GovernedAct.Transition.Foundation do
  @moduledoc """
  Transitions for the governed foundation of a Domain.

  Genesis fixes the initial identities. Principal registration, HostProfile,
  Surface and Definition revisions are then accepted only as consequences of
  matching ledger-internal Acts. The module receives canonical events from the
  fold and stores restored structs in disposable `GovernedAct.State`.
  """

  alias Spectre.{Act, Definition, HostProfile, Principal, Surface}
  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.{Index, State}

  def apply(
        %State{} = projection,
        %Event{type: "genesis_recorded", identity: identity, data: data},
        _revision
      ) do
    cond do
      projection.genesis ->
        {:error, :duplicate_genesis}

      projection.revision != 0 ->
        {:error, :genesis_must_be_first}

      true ->
        with {:ok, genesis} <- Record.decode(Spectre.Genesis, data),
             :ok <- Record.match_identity(identity, genesis),
             true <- Map.get(genesis, :domain_ref) == projection.domain_ref do
          {:ok, %{projection | genesis: genesis}}
        else
          false -> {:error, :genesis_domain_mismatch}
          {:error, _reason} = error -> error
        end
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "principal_recorded", identity: identity, data: data},
        _revision
      ) do
    with :ok <- named_by_genesis(projection, :principal_refs, identity),
         {:ok, principal} <-
           Index.restore_unique(projection.principals, Principal, identity, data, :principal) do
      {:ok, %{projection | principals: Map.put(projection.principals, identity, principal)}}
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "principal_registered", identity: identity, data: data},
        _revision
      ) do
    with {:ok, principal} <-
           Index.restore_unique(
             projection.principals,
             Principal,
             identity,
             data["principal"],
             :principal
           ),
         {:ok, act} <- Index.fetch_act(projection, data["act_ref"]),
         :ok <- validate_principal_registration(act, principal, data) do
      {:ok, %{projection | principals: Map.put(projection.principals, identity, principal)}}
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "host_profile_recorded", identity: identity, data: data},
        _revision
      ) do
    if State.host_profile(projection) do
      {:error, :duplicate_host_profile}
    else
      with :ok <- named_by_genesis(projection, :host_profile_ref, identity),
           {:ok, profile} <-
             Index.restore_unique(
               projection.host_profiles,
               HostProfile,
               identity,
               data,
               :host_profile
             ),
           :ok <- initial_host_profile_revision(profile) do
        {:ok,
         %{
           projection
           | host_profile_ref: identity,
             host_profiles: Map.put(projection.host_profiles, identity, profile)
         }}
      end
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "host_profile_revised", identity: identity, data: data},
        _revision
      ) do
    with %HostProfile{} = current <- State.host_profile(projection),
         {:ok, profile} <-
           Index.restore_unique(
             projection.host_profiles,
             HostProfile,
             identity,
             data["host_profile"],
             :host_profile
           ),
         {:ok, act} <- Index.fetch_act(projection, data["act_ref"]),
         :ok <- validate_host_profile_revision(act, current, profile, data) do
      {:ok,
       %{
         projection
         | host_profile_ref: identity,
           host_profiles: Map.put(projection.host_profiles, identity, profile)
       }}
    else
      nil -> {:error, :host_profile_not_initialized}
      {:error, _reason} = error -> error
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "definition_revised", identity: identity, data: data},
        _revision
      ) do
    with {:ok, definition} <-
           Index.restore_unique(
             projection.definitions,
             Definition,
             identity,
             data["definition"],
             :definition
           ),
         {:ok, act} <- Index.fetch_act(projection, data["act_ref"]),
         :ok <- validate_definition_revision(projection, act, definition, data) do
      key = Definition.key(definition)

      {:ok,
       %{
         projection
         | definitions: Map.put(projection.definitions, identity, definition),
           definition_heads: Map.put(projection.definition_heads, key, identity)
       }}
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "surface_recorded", identity: identity, data: data},
        _revision
      ) do
    if State.surface(projection) do
      {:error, :duplicate_surface}
    else
      with :ok <- named_by_genesis(projection, :surface_ref, identity),
           {:ok, surface} <-
             Index.restore_unique(projection.surfaces, Surface, identity, data, :surface),
           :ok <- initial_surface_revision(projection.genesis, surface) do
        {:ok,
         %{
           projection
           | surface_ref: identity,
             surfaces: Map.put(projection.surfaces, identity, surface)
         }}
      end
    end
  end

  def apply(
        %State{} = projection,
        %Event{type: "surface_revised", identity: identity, data: data},
        _revision
      ) do
    with %Surface{} = current <- State.surface(projection),
         {:ok, surface} <-
           Index.restore_unique(
             projection.surfaces,
             Surface,
             identity,
             data["surface"],
             :surface
           ),
         {:ok, act} <- Index.fetch_act(projection, data["act_ref"]),
         :ok <- validate_surface_revision(act, current, surface, data) do
      {:ok,
       %{
         projection
         | surface_ref: identity,
           surfaces: Map.put(projection.surfaces, identity, surface)
       }}
    else
      nil -> {:error, :surface_not_initialized}
      {:error, _reason} = error -> error
    end
  end

  def apply(%State{}, %Event{type: type}, _revision),
    do: {:error, {:unsupported_foundation_event, type}}

  defp initial_host_profile_revision(%HostProfile{revision: 1}), do: :ok

  defp initial_host_profile_revision(%HostProfile{ref: ref, revision: revision}),
    do: {:error, {:invalid_initial_host_profile_revision, ref, revision}}

  defp initial_surface_revision(genesis, surface) do
    if surface.revision == genesis.surface_revision,
      do: :ok,
      else: {:error, :genesis_surface_revision_mismatch}
  end

  defp validate_definition_revision(projection, act, definition, data) do
    key = Definition.key(definition)
    current_ref = Map.get(projection.definition_heads, key)
    current = if current_ref, do: Map.get(projection.definitions, current_ref)

    expected_consequence = %{
      "definition_revision" => %{
        "previous_ref" => definition.previous_ref,
        "definition" => Definition.canonical(definition)
      }
    }

    cond do
      act.class != "definition.revise" ->
        {:error, {:definition_revision_act_class_mismatch, act.ref, act.class}}

      not Act.row?(act, [:govern]) ->
        {:error, {:definition_revision_act_row_mismatch, act.ref}}

      Act.reservations?(act) ->
        {:error, {:definition_revision_act_has_reservations, act.ref}}

      not Act.targets?(act, Enum.reject([definition.previous_ref, definition.ref], &is_nil/1)) ->
        {:error, {:definition_revision_targets_missing, act.ref}}

      data["previous_ref"] != definition.previous_ref ->
        {:error, {:definition_revision_previous_ref_mismatch, definition.ref}}

      act.consequence != expected_consequence ->
        {:error, {:definition_revision_consequence_mismatch, act.ref}}

      true ->
        validate_definition_lineage(current, definition, act.committed_at)
    end
  end

  defp validate_definition_lineage(nil, definition, committed_at) do
    if definition.revision != 1 or not is_nil(definition.previous_ref),
      do: {:error, {:invalid_initial_definition_revision, definition.ref, definition.revision}},
      else: validate_definition_time(definition, committed_at)
  end

  defp validate_definition_lineage(current, definition, committed_at) do
    cond do
      definition.previous_ref != current.ref ->
        {:error,
         {:definition_revision_not_based_on_current, definition.ref, definition.previous_ref,
          current.ref}}

      definition.revision != current.revision + 1 ->
        {:error,
         {:definition_revision_not_sequential, definition.ref, current.revision,
          definition.revision}}

      definition.declared_at < current.declared_at ->
        {:error, {:definition_revision_time_regressed, definition.ref}}

      true ->
        validate_definition_time(definition, committed_at)
    end
  end

  defp validate_definition_time(definition, committed_at) do
    if definition.declared_at > committed_at,
      do: {:error, {:definition_revision_from_future, definition.ref}},
      else: :ok
  end

  defp validate_principal_registration(act, principal, data) do
    expected_consequence = %{"principal_registration" => Principal.canonical(principal)}

    cond do
      act.class != "principal.register" ->
        {:error, {:principal_registration_act_class_mismatch, act.ref, act.class}}

      not Act.row?(act, [:govern]) ->
        {:error, {:principal_registration_act_row_mismatch, act.ref}}

      Act.reservations?(act) ->
        {:error, {:principal_registration_act_has_reservations, act.ref}}

      not GovernedExecution.ledger_internal?(act) ->
        {:error, {:principal_registration_act_not_ledger_internal, act.ref}}

      principal.ref not in act.target_refs ->
        {:error, {:principal_registration_target_missing, act.ref, principal.ref}}

      data["act_ref"] != act.ref ->
        {:error, {:principal_registration_act_ref_mismatch, principal.ref}}

      act.consequence != expected_consequence ->
        {:error, {:principal_registration_consequence_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp validate_host_profile_revision(act, current, profile, data) do
    expected_consequence = %{
      "host_profile_revision" => %{
        "previous_ref" => current.ref,
        "host_profile" => HostProfile.canonical(profile)
      }
    }

    cond do
      act.class != "host_profile.revise" ->
        {:error, {:host_profile_revision_act_class_mismatch, act.ref, act.class}}

      not Act.row?(act, [:govern]) ->
        {:error, {:host_profile_revision_act_row_mismatch, act.ref}}

      not Act.targets?(act, [current.ref, profile.ref]) ->
        {:error, {:host_profile_revision_targets_missing, act.ref}}

      data["previous_ref"] != current.ref ->
        {:error, {:host_profile_revision_previous_ref_mismatch, profile.ref}}

      true ->
        validate_host_profile_lineage(act, current, profile, expected_consequence)
    end
  end

  defp validate_host_profile_lineage(act, current, profile, expected_consequence) do
    cond do
      profile.revision != current.revision + 1 ->
        {:error,
         {:host_profile_revision_not_sequential, profile.ref, current.revision, profile.revision}}

      profile.declared_at < current.declared_at or profile.declared_at > act.committed_at ->
        {:error, {:invalid_host_profile_revision_time, profile.ref, profile.declared_at}}

      act.host_profile_ref != current.ref ->
        {:error, {:host_profile_revision_act_context_mismatch, act.ref}}

      act.consequence != expected_consequence ->
        {:error, {:host_profile_revision_consequence_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  defp validate_surface_revision(act, current, surface, data) do
    expected_consequence = %{
      "surface_revision" => %{
        "previous_ref" => current.ref,
        "surface" => Surface.canonical(surface)
      }
    }

    cond do
      act.class != "surface.revise" ->
        {:error, {:surface_revision_act_class_mismatch, act.ref, act.class}}

      not Act.row?(act, [:govern]) ->
        {:error, {:surface_revision_act_row_mismatch, act.ref}}

      not Act.targets?(act, [current.ref, surface.ref]) ->
        {:error, {:surface_revision_targets_missing, act.ref}}

      data["previous_ref"] != current.ref ->
        {:error, {:surface_revision_previous_ref_mismatch, surface.ref}}

      surface.revision != current.revision + 1 ->
        {:error,
         {:surface_revision_not_sequential, surface.ref, current.revision, surface.revision}}

      act.surface_revision != current.revision ->
        {:error, {:surface_revision_act_context_mismatch, act.ref}}

      act.consequence != expected_consequence ->
        {:error, {:surface_revision_consequence_mismatch, act.ref}}

      true ->
        :ok
    end
  end

  @doc "Checks that Genesis names a foundation record before it is materialized."
  @spec named_by_genesis(State.t(), atom(), String.t()) :: :ok | {:error, term()}
  def named_by_genesis(%{genesis: nil}, _field, _ref), do: {:error, :genesis_required}

  def named_by_genesis(%{genesis: genesis}, field_name, ref) do
    case Map.fetch!(genesis, field_name) do
      refs when is_list(refs) ->
        if ref in refs,
          do: :ok,
          else: {:error, {:record_not_named_by_genesis, field_name, ref}}

      ^ref ->
        :ok

      _different ->
        {:error, {:record_not_named_by_genesis, field_name, ref}}
    end
  end
end
