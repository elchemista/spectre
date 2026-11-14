defmodule Spectre.Server.Checkpoint do
  @moduledoc """
  Explicit durable projection of Server coordination state.

  Configure `checkpoint: {store, key}` with a `Spectre.Server.Store.Disk`
  owner, or `checkpoint: {module, store_ref, key}` for an implementation of
  `Spectre.Server.Store`. The checkpoint, inbox and command outbox share one CAS revision.
  Runtime references and capabilities are never serialized. The default
  codec accepts the listed portable records; custom application structs must
  be projected into plain data by the application before acquisition.

  Consent waits are restored suspended and require a fresh presentation.
  Pending governed commands keep their referenced wait uncertain until recovery
  finishes, so a concurrent resume cannot start another resolution.
  Unacknowledged governed commands require host reconciliation; they are never
  retried automatically merely because a worker result was lost.

  `checkpoint_migrator: {module, function}` receives the saved projection and
  fingerprint metadata. It returns `{:ok, projection}` or
  `{:ok, projection, %{old_dispatch_key => new_dispatch_key}}`. Reconciliation
  facts must remain unchanged; the runtime applies explicit mappings only to
  routing hints after validating each target against the current Definition.

  After an explicit migration, changed tool contracts are marked without
  rewriting their original commands or provenance. Cognitive requests complete
  with a contract-change error (or uncertainty for nonrepeatable requests).
  Known unstarted governed requests are rejected; already-started governed
  requests reconcile their original journal through GAM.
  """
  alias Spectre.GAM.Canonical.Value
  alias Spectre.Server.Store.Disk
  alias Spectre.{Definition, Route}
  alias Spectre.Server.Router

  @max_bytes 16 * 1_024 * 1_024 - 16_384

  @records [
    Spectre.Input,
    Spectre.Input.Source,
    Spectre.Route,
    Spectre.Rule,
    Spectre.Flow.Constraint,
    Spectre.Server.Command,
    Spectre.GAM.Candidate,
    Spectre.GAM.Row,
    Spectre.GAM.Presentation,
    Spectre.GAM.Act,
    Spectre.GAM.Attempt,
    Spectre.GAM.Outcome,
    Spectre.GAM.Decision,
    Spectre.GAM.Evidence,
    Spectre.GAM.Label,
    Spectre.GAM.Condition,
    Spectre.GAM.Disclosure,
    Spectre.GAM.Duty,
    Spectre.GAM.Proposal.Result,
    Spectre.GAM.Attempt.Runner.Result
  ]

  def load(%{opts: opts} = state) do
    state = cache_fingerprint(state)

    case Keyword.get(opts, :checkpoint) do
      nil -> state
      {store, key} -> load_entry(Disk.fetch(store, key), state)
      {module, store, key} -> load_entry(module.fetch(store, key), state)
    end
  end

  defp load_entry(:not_found, state), do: state

  defp load_entry({:ok, %{revision: revision, value: binary}}, state) do
    with {:ok, saved} <- Value.decode(binary, allowed_structs: @records),
         {:ok, projection} <- migrate_if_needed(saved, state),
         :ok <- validate(projection, state) do
      projection = restore_projection(state.agent, projection)

      migrated? =
        Map.get(saved, :definition_fingerprint) != Map.get(projection, :definition_fingerprint)

      state |> restore_state(projection, revision) |> Map.put(:checkpoint_migrated, migrated?)
    else
      {:error, reason} -> raise ArgumentError, "invalid Server checkpoint: #{inspect(reason)}"
    end
  end

  defp restore_state(state, projection, revision) do
    recovering = recovering_pending_ids(projection.outbox, projection.pending)

    pending =
      Map.new(projection.pending, fn {id, pending} ->
        status = if MapSet.member?(recovering, id), do: :uncertain, else: :suspended
        {id, Map.put(pending, :status, status)}
      end)

    state =
      state
      |> Map.put(:dead_letters, Map.get(projection, :dead_letters, %{}))
      |> Map.put(:operations, Map.get(projection, :operations, %{}))
      |> Map.put(:external_submissions, Map.get(projection, :external_submissions, %{}))
      |> Map.put(
        :seen_event_order,
        Map.get(projection, :seen_event_order, Map.keys(projection.seen_events))
      )

    %{
      state
      | assigns: projection.assigns,
        pending: pending,
        outbox: projection.outbox,
        inbox: projection.inbox,
        seen_events: projection.seen_events,
        checkpoint_revision: revision,
        sequence: projection.sequence,
        history: projection.history,
        current_flow: projection.current_flow,
        current_scope: projection.current_scope,
        foreground: nil,
        current: projection.current,
        queue: :queue.from_list(projection.queue)
    }
  end

  defp recovering_pending_ids(outbox, pending) do
    Enum.reduce(outbox, MapSet.new(), fn {_command_id, entry}, ids ->
      case recovering_pending_id(entry, pending) do
        nil -> ids
        id -> MapSet.put(ids, id)
      end
    end)
  end

  defp recovering_pending_id(%{lifecycle: _}, _pending), do: nil
  defp recovering_pending_id(%{blocked_by: _}, _pending), do: nil
  defp recovering_pending_id(%{execution_started: false}, _pending), do: nil

  defp recovering_pending_id(%{command: %{kind: kind, args: [id]}}, pending)
       when kind in [:confirm_pending, :reject_pending, :explain_pending, :resume_pending] do
    case Map.get(pending, id) do
      %{kind: :consent} -> id
      _ -> nil
    end
  end

  defp recovering_pending_id(_entry, _pending), do: nil

  def save(%{opts: opts} = state) do
    state = cache_fingerprint(state)

    case Keyword.get(opts, :checkpoint) do
      nil ->
        state

      configuration ->
        {module, store, key} = storage(configuration)
        projection = projection(state)

        with {:ok, bytes} <- Value.encode(projection, allowed_structs: @records),
             {:ok, revision} <- commit(module, store, key, state.checkpoint_revision, bytes) do
          %{state | checkpoint_revision: revision}
        else
          {:error, reason} ->
            raise ArgumentError, "Server checkpoint not acquired: #{inspect(reason)}"
        end
    end
  end

  @doc "Encodes a portable Server coordination value with the checkpoint record allowlist."
  def encode_value(value), do: Value.encode(value, allowed_structs: @records)

  @doc """
  Decodes a portable value without loading or executing an Agent.

  This checks the codec and record allowlist only. Snapshot identity, definition
  compatibility and checkpoint structure are validated separately during load.
  """
  def decode_snapshot(binary), do: Value.decode(binary, allowed_structs: @records)

  @doc "Validates portable callback data using the checkpoint codec and record allowlist."
  def validate_value(value, opts \\ []) do
    Value.validate(value, Keyword.put(opts, :allowed_structs, @records))
  end

  @doc "Maximum coordination payload size, reserving space for Store envelopes."
  def max_bytes, do: @max_bytes

  @doc false
  def tool_reference(%{opts: opts}) do
    case Keyword.get(opts, :checkpoint) do
      nil ->
        nil

      configuration ->
        {adapter, store, key} = storage(configuration)
        %{adapter: adapter, store: store, key: key}
    end
  end

  @doc false
  def validate_state(%{opts: opts} = state, codec_opts \\ []) do
    if Keyword.get(opts, :checkpoint),
      do: validate_value(projection(state), Keyword.put_new(codec_opts, :max_bytes, @max_bytes)),
      else: :ok
  end

  defp projection(state) do
    %{
      version: 1,
      agent: state.agent,
      server: state.server,
      identity: state.identity,
      definition_fingerprint: cached_fingerprint(state),
      assigns: state.assigns,
      pending: project_pending(state.pending),
      outbox: project_entries(state.outbox),
      inbox: project_inbox(state.inbox),
      seen_events: state.seen_events,
      external_submissions: Map.get(state, :external_submissions, %{}),
      dead_letters: Map.get(state, :dead_letters, %{}),
      operations: project_entries(Map.get(state, :operations, %{})),
      seen_event_order: Map.get(state, :seen_event_order, Map.keys(state.seen_events)),
      sequence: state.sequence,
      history: state.history,
      current_flow: state.current_flow,
      current_scope: state.current_scope,
      current: project_event(state.current),
      queue: Enum.map(:queue.to_list(state.queue), &project_event/1)
    }
  end

  defp storage({store, key}), do: {Disk, store, key}
  defp storage({module, store, key}) when is_atom(module), do: {module, store, key}

  defp commit(module, store, key, nil, bytes), do: module.put_new(store, key, bytes)

  defp commit(module, store, key, revision, bytes),
    do: module.compare_and_swap(store, key, revision, bytes)

  # Raw transport data and executable legacy route definitions are deliberately
  # excluded. Durable callbacks retain the canonical input and dispatch key.
  def project_event(nil), do: nil

  def project_event(event) do
    input = %{event.input | raw: nil}
    routing = project_routing(event.routing)
    # A recovered consent must be re-presented. Transport receipts are one-use
    # runtime credentials, never part of the durable conversation snapshot.
    event |> Map.delete(:consent_proof) |> Map.merge(%{input: input, routing: routing})
  end

  defp project_pending(pending),
    do:
      Map.new(pending, fn {id, value} ->
        {id, Map.update(value, :origin, nil, &project_event/1)}
      end)

  defp project_entries(entries),
    do:
      Map.new(entries, fn {id, value} ->
        {id, Map.update(value, :event, nil, &project_event/1)}
      end)

  defp project_inbox(inbox) do
    Map.new(inbox, fn {id, value} ->
      value =
        Map.update(value, :worker, nil, fn worker ->
          Map.update(worker, :event, nil, &project_event/1)
        end)

      value =
        case {value.worker.kind, value.result} do
          {:route, {:ok, key, routing}} ->
            %{value | result: {:ok, key, project_routing(Map.put(routing, :route_key, key))}}

          {:interrupt, {:interrupt, key, routing}} ->
            %{
              value
              | result: {:interrupt, key, project_routing(Map.put(routing, :route_key, key))}
            }

          {:route, {:unmatched, routing}} ->
            %{value | result: {:unmatched, project_routing(routing)}}

          {:prepare_input, {:ok, input, memory}} ->
            %{value | result: {:ok, %{input | raw: nil}, memory}}

          {:generate, {:generated, generated}} ->
            # Model selection objects may contain live bindings. Telemetry is
            # separate from the portable, consolidated application result.
            %{value | result: {:generated, Map.drop(generated, [:inference])}}

          _ ->
            value
        end

      {id, value}
    end)
  end

  defp project_routing(routing) do
    snapshot = route_snapshot(Map.get(routing, :route), Map.get(routing, :route_key))

    routing =
      Map.take(routing, [:route_key, :protected, :reason, :scope, :input, :previous_route_keys])

    routing = if snapshot, do: Map.put(routing, :checkpoint_route, snapshot), else: routing

    case Map.fetch(routing, :input) do
      {:ok, %Spectre.Input{} = input} -> Map.put(routing, :input, %{input | raw: nil})
      {:ok, nil} -> Map.delete(routing, :input)
      :error -> routing
    end
  end

  # The selected rule is resolved by its immutable dispatch identity, never by
  # classifying the input again. Full mount ownership, prompt injections and
  # inference constraints come from the fenced compiled Definition.
  @doc "Restores an exact selected route without invoking any routing strategy."
  def restore_routing(agent, routing) when is_map(routing) do
    restore_route_snapshot(agent, routing, Map.get(routing, :checkpoint_route))
  rescue
    error -> {:error, {:checkpoint_route_restore_failed, error.__struct__}}
  end

  defp restore_route_snapshot(agent, routing, %{
         kind: :definition_rule,
         key: key,
         attributes: attributes
       }) do
    case matching_rules(agent, key) do
      [rule] ->
        route = rule |> Route.from_rule(:checkpoint, nil) |> struct(attributes)
        {:ok, routing |> Map.delete(:checkpoint_route) |> Map.put(:route, route)}

      [] ->
        {:error, {:checkpoint_route_not_found, key}}

      _ ->
        {:error, {:checkpoint_route_ambiguous, key}}
    end
  end

  defp restore_route_snapshot(_agent, routing, %{kind: :portable, value: %Route{} = route}),
    do: {:ok, routing |> Map.delete(:checkpoint_route) |> Map.put(:route, route)}

  defp restore_route_snapshot(_agent, routing, nil) do
    if Map.get(routing, :route_key),
      do: {:error, :checkpoint_route_metadata_missing},
      else: {:ok, routing}
  end

  defp restore_route_snapshot(_agent, _routing, _snapshot),
    do: {:error, :invalid_checkpoint_route}

  defp matching_rules(agent, key) do
    if definition_module?(agent) do
      agent
      |> Definition.rules()
      |> Enum.map(&Spectre.Rule.new/1)
      |> Enum.filter(fn rule ->
        Router.dispatch_key(Route.from_rule(rule, :checkpoint, nil)) == key
      end)
    else
      []
    end
  end

  defp route_snapshot(%Route{rule: %{}} = route, key) do
    %{
      kind: :definition_rule,
      key: key || Router.dispatch_key(route),
      attributes:
        Map.take(Map.from_struct(route), [
          :strategy,
          :confidence,
          :margin,
          :accepted?,
          :scores,
          :labels,
          :terminal?,
          :escalation_reason
        ])
    }
  end

  defp route_snapshot(%Route{} = route, _key), do: %{kind: :portable, value: %{route | raw: nil}}
  defp route_snapshot(nil, _key), do: nil

  defp restore_projection(agent, projection) do
    operations =
      Map.new(Map.get(projection, :operations, %{}), fn {id, entry} ->
        {id, Map.update(entry, :event, nil, &restore_event(agent, &1))}
      end)

    projection = Map.put(projection, :operations, operations)

    %{
      projection
      | current: restore_event(agent, projection.current),
        queue: Enum.map(projection.queue, &restore_event(agent, &1)),
        pending:
          Map.new(projection.pending, fn {id, pending} ->
            {id, Map.update(pending, :origin, nil, &restore_event(agent, &1))}
          end),
        outbox:
          Map.new(projection.outbox, fn {id, entry} ->
            {id, Map.update(entry, :event, nil, &restore_event(agent, &1))}
          end),
        inbox:
          Map.new(projection.inbox, fn {id, entry} ->
            worker = Map.update(entry.worker, :event, nil, &restore_event(agent, &1))

            result =
              case {worker.kind, entry.result} do
                {:route, {:ok, key, routing}} ->
                  {:ok, key, restore_routing!(agent, routing)}

                {:interrupt, {:interrupt, key, routing}} ->
                  {:interrupt, key, restore_routing!(agent, routing)}

                {:route, {:unmatched, routing}} ->
                  {:unmatched, restore_routing!(agent, routing)}

                _ ->
                  entry.result
              end

            {id, %{entry | worker: worker, result: result}}
          end)
    }
  end

  defp restore_event(_agent, nil), do: nil
  defp restore_event(agent, event), do: %{event | routing: restore_routing!(agent, event.routing)}

  defp restore_routing!(agent, routing) do
    case restore_routing(agent, routing) do
      {:ok, routing} ->
        routing

      {:error, reason} ->
        raise ArgumentError, "cannot restore checkpoint routing: #{inspect(reason)}"
    end
  end

  defp definition_module?(agent) do
    Code.ensure_loaded?(agent) and
      (function_exported?(agent, :__spectre_definition__, 0) or
         function_exported?(agent, :__spectre_rules__, 0))
  end

  defp definition_fingerprint(state) do
    modules =
      if definition_module?(state.agent) do
        definition_modules(state.agent, MapSet.new())
      else
        MapSet.new([state.agent])
      end

    modules =
      modules
      |> MapSet.put(state.server)
      |> MapSet.union(MapSet.new(Spectre.Server.Tool.adapter_modules(state.server)))
      |> Enum.sort()
      |> Enum.map(fn module ->
        Code.ensure_loaded!(module)
        {module, module.__info__(:md5)}
      end)

    canonical =
      if definition_module?(state.agent) do
        case Definition.canonical(state.agent) do
          {:ok, value} -> value |> Definition.Canonical.ref() |> Definition.Ref.to_string()
          # Compiled modules without portable prompt assets still have a strict
          # code fence, including mounted Skill and extension code identities.
          {:error, _} -> :compiled_code_identity
        end
      else
        :compiled_code_identity
      end

    %{
      version: 1,
      canonical: canonical,
      modules: modules,
      checkpoint_version: Keyword.get(state.opts, :checkpoint_version, 1)
    }
  end

  @doc false
  def refresh_fingerprint(state),
    do: Map.put(state, :definition_fingerprint_cache, definition_fingerprint(state))

  defp cache_fingerprint(state) do
    if Map.has_key?(state, :definition_fingerprint_cache),
      do: state,
      else: refresh_fingerprint(state)
  end

  defp cached_fingerprint(state),
    do:
      Map.get_lazy(state, :definition_fingerprint_cache, fn -> definition_fingerprint(state) end)

  # A code change requires an explicit host migration. Its callback may evolve
  # application assigns, but must preserve exact governed commands, pending
  # proofs and already-acquired inbox facts for subsequent reconciliation.
  defp migrate_if_needed(projection, state) do
    if Map.get(projection, :definition_fingerprint) == cached_fingerprint(state) do
      {:ok, projection}
    else
      migrate_projection(Keyword.get(state.opts, :checkpoint_migrator), projection, state)
    end
  end

  defp migrate_projection(nil, projection, _state), do: {:ok, projection}

  defp migrate_projection({module, function}, projection, state) do
    metadata = %{
      agent: state.agent,
      server: state.server,
      schema_version: 1,
      from: Map.get(projection, :definition_fingerprint),
      to: cached_fingerprint(state)
    }

    with {:ok, migrated, mappings} <-
           migration_result(apply(module, function, [projection, metadata])),
         :ok <- preserve_reconciliation(projection, migrated),
         {:ok, targets} <- migration_targets(state.agent, mappings) do
      migrated = remap_projection(migrated, targets)
      {:ok, Map.put(migrated, :definition_fingerprint, cached_fingerprint(state))}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_checkpoint_migration}
    end
  end

  defp migrate_projection(_, _, _), do: {:error, :invalid_checkpoint_migrator}

  defp migration_result({:ok, projection}) when is_map(projection),
    do: {:ok, projection, %{}}

  defp migration_result({:ok, projection, mappings})
       when is_map(projection) and is_map(mappings) and not is_struct(mappings),
       do: {:ok, projection, mappings}

  defp migration_result({:error, _} = error), do: error
  defp migration_result(_), do: {:error, :invalid_checkpoint_migration}

  defp migration_targets(agent, mappings) do
    Enum.reduce_while(mappings, {:ok, %{}}, fn {old_key, new_key}, {:ok, targets} ->
      case matching_rules(agent, new_key) do
        [rule] -> {:cont, {:ok, Map.put(targets, old_key, {new_key, rule})}}
        [] -> {:halt, {:error, {:checkpoint_route_not_found, new_key}}}
        _ -> {:halt, {:error, {:checkpoint_route_ambiguous, new_key}}}
      end
    end)
  end

  defp remap_projection(projection, targets) when map_size(targets) == 0, do: projection

  defp remap_projection(projection, targets) do
    %{
      projection
      | current: remap_event(projection.current, targets),
        queue: Enum.map(projection.queue, &remap_event(&1, targets)),
        pending: remap_entries(projection.pending, :origin, targets),
        outbox: remap_entries(projection.outbox, :event, targets),
        inbox: remap_inbox(projection.inbox, targets)
    }
    |> Map.update(:operations, %{}, &remap_entries(&1, :event, targets))
  end

  defp remap_entries(entries, field, targets) do
    Map.new(entries, fn {id, entry} ->
      {id, Map.update!(entry, field, &remap_event(&1, targets))}
    end)
  end

  defp remap_inbox(inbox, targets) do
    Map.new(inbox, fn {id, entry} ->
      worker = Map.update!(entry.worker, :event, &remap_event(&1, targets))
      result = remap_result(worker.kind, entry.result, targets)
      {id, %{entry | worker: worker, result: result}}
    end)
  end

  defp remap_result(:route, {:ok, key, routing}, targets),
    do: {:ok, remap_key(key, targets), remap_routing(routing, targets)}

  defp remap_result(:interrupt, {:interrupt, key, routing}, targets),
    do: {:interrupt, remap_key(key, targets), remap_routing(routing, targets)}

  defp remap_result(:route, {:unmatched, routing}, targets),
    do: {:unmatched, remap_routing(routing, targets)}

  defp remap_result(_kind, result, _targets), do: result

  defp remap_key(key, targets) do
    case Map.fetch(targets, key) do
      {:ok, {new_key, _rule}} -> new_key
      :error -> key
    end
  end

  defp remap_event(nil, _targets), do: nil
  defp remap_event(event, targets), do: %{event | routing: remap_routing(event.routing, targets)}

  defp remap_routing(
         %{checkpoint_route: %{kind: :definition_rule, key: key} = snapshot} = routing,
         targets
       ) do
    case Map.fetch(targets, key) do
      {:ok, {new_key, rule}} ->
        routing
        |> Map.put(:route_key, new_key)
        |> Map.put(:checkpoint_route, %{snapshot | key: new_key})
        |> Map.put(:scope, rule.scope)
        |> Map.put(:protected, Keyword.get(rule.opts, :protected, false))
        |> Map.update(:previous_route_keys, [key], &Enum.uniq(&1 ++ [key]))

      :error ->
        routing
    end
  end

  defp remap_routing(routing, _targets), do: routing

  defp preserve_reconciliation(saved, migrated) do
    immutable = [
      :version,
      :agent,
      :server,
      :identity,
      :sequence,
      :current,
      :queue,
      :outbox,
      :inbox,
      :pending,
      :seen_events,
      :external_submissions,
      :seen_event_order,
      :operations,
      :dead_letters
    ]

    if Enum.all?(immutable, &(Map.get(saved, &1) == Map.get(migrated, &1))),
      do: :ok,
      else: {:error, :checkpoint_migration_changed_reconciliation}
  end

  defp definition_modules(module, seen) do
    if MapSet.member?(seen, module) do
      seen
    else
      definition = Definition.fetch!(module)
      seen = MapSet.put(seen, module)

      seen =
        Enum.reduce(definition.extensions, seen, fn extension, seen ->
          MapSet.put(seen, extension.module)
        end)

      seen = if definition.stack, do: MapSet.put(seen, definition.stack), else: seen

      Enum.reduce(definition.skills, seen, fn mount, seen ->
        definition_modules(mount.module, seen)
      end)
    end
  end

  defp validate(%{version: 1, agent: agent, server: server, identity: identity} = value, state) do
    cond do
      agent != state.agent or server != state.server ->
        {:error, :checkpoint_definition_mismatch}

      identity != state.identity ->
        {:error, :checkpoint_identity_mismatch}

      Map.get(value, :definition_fingerprint) != cached_fingerprint(state) ->
        {:error, :checkpoint_definition_fingerprint_mismatch}

      not Enum.all?(
        [:assigns, :pending, :outbox, :inbox, :seen_events],
        &is_map(Map.get(value, &1))
      ) ->
        {:error, :invalid_checkpoint_shape}

      not is_integer(value.sequence) ->
        {:error, :invalid_checkpoint_sequence}

      not valid_submission_keys?(Map.get(value, :external_submissions, %{})) ->
        {:error, :invalid_checkpoint_submissions}

      true ->
        :ok
    end
  end

  defp validate(_, _), do: {:error, :unsupported_checkpoint_version}

  @spec valid_submission_keys?(term()) :: boolean()
  defp valid_submission_keys?(entries) when is_map(entries) and map_size(entries) <= 4096 do
    Enum.all?(entries, fn
      {key, %{id: id, fingerprint: fingerprint}} ->
        is_binary(key) and byte_size(key) in 1..256 and is_binary(id) and id != "" and
          is_binary(fingerprint) and byte_size(fingerprint) == 64

      _ ->
        false
    end)
  end

  defp valid_submission_keys?(_), do: false
end
