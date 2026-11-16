defmodule Spectre.GAM.Domain.Projection.WorkingSet do
  @moduledoc false

  alias Spectre.GAM.Domain.Projection.{IndexRows, Live, Rows, Store}
  alias Spectre.GAM.GovernedAct.Reads, as: Selection

  # Authority declarations are selected independently of Evidence. Historical
  # execution and information records enter only through the dependency closure.
  @authority ~w(principals mandates mandate_successors revocations meters
    meter_owner_aliases definition_heads)a
  @active ~w(pending_causes open_duty_causes blocked_effects owner_debts debt_owners)a
  # Only fields in the GAM contracts participate in historical reads. Application
  # payloads, arguments, purpose parameters and arbitrary assigns are opaque.
  @reference_fields ~w(ref identity identity_key candidate_identity_key decision_ref act_ref
    attempt_ref outcome_ref contradicts_outcome_ref evidence_ref evidence_refs parent_ref parent_refs
    source_ref source_act_ref source_evidence_refs scope_ref scope_refs requested_mandate_ref mandate_ref root_mandate_refs
    grantor_ref holder_ref proposer_ref authorizer_ref accountable_ref authenticated_principal_ref
    principal_refs opened_by_ref disposition_authority_refs conflict_refs executor_ref executor_refs
    host_profile_ref surface_ref previous_ref predecessor_ref successor_ref presentation_ref
    show_ref show_act_ref presentation_show_ref candidate_binding_ref recognition_refs recognition_evidence_refs
    approval_source_refs recipient_refs destination_refs removed_owner_refs owner_ref target_refs subject_refs)a
  @structured_fields ~w(consequence consent disclosure bindings conditions promise_condition
    label_refs labels revocation provenance scope opening principal host_profile surface definition
    successor mandate_issue mandate_restrict mandate_revoke mandate_devolve principal_registration
    scope_open host_profile_revision surface_revision definition_revision evidence_declassification
    principal_register host_profile_revise
    surface_revise definition_revise data_erase data_declassify evidence presentation_show
    presentation_approve duty_dispose disposition erasure erasure_request declassification candidate context data)a

  @reference_names Enum.map(@reference_fields, &Atom.to_string/1)
  @structured_names Enum.map(@structured_fields, &Atom.to_string/1)
  @node_kinds %{
    evidence: :evidence,
    presentations: :presentation,
    acts: :act,
    attempts: :attempt,
    outcomes: :outcome
  }

  def load(%{projection_store: nil} = state, _intent), do: {:ok, state}

  def load(state, intent) do
    with {:ok, now} <- Spectre.GAM.Domain.Transaction.trusted_recorded_at(state),
         {:ok, projection} <- extend(state, intent, now) do
      {:ok, %{state | projection: projection, working_time: now, working_intent: intent}}
    end
  end

  def include_batch(%{projection: projection} = state, batch_id) do
    with {:ok, rows} <-
           Store.fetch(state.projection_store, state.projection_handle, Rows.cursor(projection), [
             {:batches, batch_id}
           ]) do
      projection = Selection.read(projection, {:row, :batches, batch_id})

      {:ok,
       if(map_size(rows) > 0,
         do: update_in(projection.read_index.batches, &MapSet.put(&1, batch_id)),
         else: projection
       )}
    end
  end

  def extend(state, intent, now) do
    started = System.monotonic_time()
    {:reductions, initial_reductions} = Process.info(self(), :reductions)
    projection = state.projection
    all? = full?(intent)
    global? = global?(intent)

    queries =
      if all? do
        Enum.map(
          Rows.collections() -- [:domain, :record_refs, :act_declassifications],
          &{:page, &1, []}
        )
      else
        Enum.map(if(global?, do: @authority ++ @active, else: @active), &{:page, &1, []}) ++
          [
            row(:host_profiles, projection.catalog.host_profile_ref),
            row(:surfaces, projection.catalog.surface_ref)
          ] ++
          deadlines(now) ++
          [group(:scope_deadlines, now)] ++
          active(projection) ++
          contextual(state, intent) ++
          if(global?, do: seeds(projection.catalog.genesis), else: []) ++
          seeds(intent, true) ++ extra(intent) ++ control(intent)
      end

    context = %{
      projection: projection,
      store: state.projection_store,
      handle: state.projection_handle,
      cursor: Rows.cursor(projection),
      seen: projection.read_index.selection || MapSet.new(),
      all?: all?,
      global?: global?,
      erasure?: erasure?(intent)
    }

    case drain(context, queries) do
      {:ok, context} ->
        {:memory, memory} = Process.info(self(), :memory)
        {:reductions, reductions} = Process.info(self(), :reductions)

        Spectre.Telemetry.emit(
          [:gam, :projection, :load],
          %{
            duration: System.monotonic_time() - started,
            memory: memory,
            reductions: reductions - initial_reductions,
            selections: MapSet.size(context.seen),
            records: Enum.count(context.seen, &match?({:loaded, _}, &1))
          },
          %{full: all?}
        )

        with :ok <- validate_owners(context.projection),
             do:
               {:ok,
                if(all?,
                  do: IndexRows.restore_counts(context.projection),
                  else: Selection.mark(context.projection, context.seen)
                )}

      {:error, _} = error ->
        error
    end
  end

  defp validate_owners(projection) do
    case Enum.find(projection.mandates, fn {ref, _} ->
           owner = Map.get(projection.meter_owner_aliases, ref, ref)

           not Map.has_key?(projection.mandates, owner) or
             not Map.has_key?(projection.meters, owner)
         end) do
      nil -> :ok
      {ref, _} -> {:error, {:domain_projection_record_missing, {:meter_owner, ref}}}
    end
  end

  def release(%{projection_store: nil} = state), do: state

  def release(state),
    do: %{
      state
      | projection: Live.retain(state.projection),
        working_time: nil,
        working_intent: nil
    }

  defp full?(:projection), do: true
  defp full?({:query, _, :view}), do: true
  defp full?({:query, _, {:diagnostics, _}}), do: true
  defp full?(_), do: false

  defp global?(:foundation), do: true
  defp global?({:query, _, :authority}), do: true

  defp global?(%{"type" => type, "data" => data}) do
    not Spectre.GAM.GovernedAct.Completeness.local_event_type?(type) or global?(data)
  end

  defp global?(value) when is_map(value) do
    class = field(value, :class)

    (is_binary(class) and Spectre.GAM.GovernedAct.Class.intrinsic?(class)) or
      field(value, :executor_ref) ==
        Spectre.GAM.GovernedAct.Execution.kernel_executor_ref() or
      Enum.any?([:candidate, "candidate", :consequence, "consequence"], fn key ->
        global?(Map.get(value, key))
      end)
  end

  defp global?([]), do: false
  defp global?([head | tail]), do: global?(head) or global?(tail)
  defp global?(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.any?(&global?/1)
  defp global?(_), do: false

  defp contextual(%{context_limits: %{max_events: count}, projection: projection}, intent)
       when is_tuple(intent) and elem(intent, 0) in [:begin_turn, :ingress_result, :continue_turn] do
    [{:page, :evidence_revisions, [from: max(projection.revision - count + 1, 1)]}]
  end

  defp contextual(_, _), do: []

  defp deadlines(now) do
    for collection <- [:dispatch_deadlines, :duty_deadlines],
        opts <- [[through: now], [from: now + 1, nearest: true]],
        do: {:page, collection, opts}
  end

  defp active(projection) do
    authority = projection.read_index.authority

    Enum.map(authority.open_duty_causes, &row(:duties, &1)) ++
      Enum.map(authority.debt_owners, fn {ref, _} -> row(:meter_recontainments, ref) end) ++
      seeds(Map.values(projection.read_index.duties.pending))
  end

  defp extra({:query, _, {:records, collection}}), do: [{:page, collection, []}]

  defp extra({:query, _, {:surface, _}}), do: [{:page, :surfaces, []}]

  defp extra({:query, _, {:evidence_proposition, proposition}}),
    do: [group(:evidence_propositions, proposition)]

  defp extra({:query, _, {:selected_view, refs}}), do: seeds(refs)
  defp extra(_), do: []

  defp control(value) when is_map(value) do
    if field(value, :class) in ["mandate.revoke", "mandate.restrict"] or
         Map.get(value, "type") in ["mandate_revoked", "mandate_restricted"],
       do: [{:page, :pending_dispatches, []}],
       else: value |> Map.delete(:__struct__) |> Map.values() |> Enum.flat_map(&control/1)
  end

  defp control([]), do: []
  defp control([head | tail]), do: control(head) ++ control(tail)

  defp control(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&control/1)

  defp control(_), do: []

  defp drain(context, []), do: {:ok, context}
  defp drain(context, [nil | rest]), do: drain(context, rest)

  defp drain(context, [query | rest]) do
    if MapSet.member?(context.seen, query) do
      drain(context, rest)
    else
      context = %{context | seen: MapSet.put(context.seen, query)}

      with {:ok, rows} <- read(context, query),
           {:ok, context, dependencies} <- absorb(context, rows) do
        drain(context, dependencies ++ rest)
      end
    end
  end

  defp read(context, {:row, collection, key}) do
    Store.fetch(context.store, context.handle, context.cursor, [{collection, key}])
  end

  defp read(context, {:required, collection, key}) do
    with {:ok, rows} <- read(context, {:row, collection, key}) do
      if Map.has_key?(rows, {collection, key}),
        do: {:ok, rows},
        else: {:error, {:domain_projection_record_missing, {collection, key}}}
    end
  end

  defp read(context, {:ref, ref}) do
    with {:ok, memberships} <- pages(context, :record_refs, group: ref),
         keys =
           Enum.map(memberships, fn {{:record_refs, {^ref, collection}}, _} ->
             {collection, ref}
           end),
         {:ok, rows} <- fetch(context, keys),
         do: complete_rows(keys, rows)
  end

  defp read(context, {:page, collection, opts}), do: pages(context, collection, opts)

  defp complete_rows(keys, rows) do
    case keys -- Enum.map(rows, &elem(&1, 0)) do
      [] -> {:ok, rows}
      [missing | _] -> {:error, {:domain_projection_record_missing, missing}}
    end
  end

  defp fetch(context, keys) do
    keys
    |> Enum.chunk_every(100)
    |> Enum.reduce_while({:ok, []}, fn chunk, {:ok, found} ->
      case Store.fetch(context.store, context.handle, context.cursor, chunk) do
        {:ok, values} -> {:cont, {:ok, Map.to_list(values) ++ found}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp pages(context, collection, opts, acc \\ []) do
    case Store.page(context.store, context.handle, context.cursor, collection, opts) do
      {:ok, rows, nil} ->
        {:ok, Enum.reverse(acc, rows)}

      {:ok, rows, next} ->
        pages(context, collection, Keyword.put(opts, :after, next), Enum.reverse(rows, acc))

      {:error, _} = error ->
        error
    end
  end

  defp absorb(context, rows) do
    Enum.reduce_while(rows, {:ok, context, []}, &absorb_row/2)
  end

  defp absorb_row({key, bytes}, {:ok, current, dependencies}) do
    case Rows.decode(bytes) do
      {:ok, value} -> absorb_value(current, key, value, dependencies)
      {:error, _} = error -> {:halt, error}
    end
  end

  defp absorb_value(current, key, value, dependencies) do
    if MapSet.member?(current.seen, {:loaded, key}) do
      {:cont, {:ok, current, dependencies}}
    else
      next = %{
        current
        | projection: Rows.put(current.projection, key, value),
          seen: MapSet.put(current.seen, {:loaded, key})
      }

      more = if current.all?, do: [], else: dependencies(key, value, current)
      {:cont, {:ok, next, more ++ dependencies}}
    end
  end

  defp dependencies({:event_metadata, ref}, value, _),
    do: [row(:evidence_revisions, value.revision), {:ref, ref}]

  defp dependencies({:evidence_revisions, _}, ref, _), do: [required(:evidence, ref)]
  defp dependencies({:dispatch_deadlines, {_time, ref}}, _, _), do: [row(:acts, ref)]

  defp dependencies({:duty_deadlines, {_time, kind, ref}}, _, _),
    do: [row(%{attempt: :attempts, evidence: :evidence, scope: :scopes}[kind], ref)]

  defp dependencies({:consumed_nonces, _}, _, _), do: []
  defp dependencies({:batches, _}, _, _), do: []
  defp dependencies({:payload_refs, _}, _, _), do: []
  defp dependencies({:pending_dispatches, ref}, _, _), do: [row(:acts, ref)]
  defp dependencies({:open_duty_causes, cause}, _, _), do: [required(:duties, cause)]
  defp dependencies({:act_duties, {ref, cause}}, _, _), do: [row(:acts, ref), row(:duties, cause)]
  defp dependencies({:duty_refs, _}, cause, _), do: [row(:duties, cause)]
  defp dependencies({:pending_causes, cause}, value, _), do: [row(:duties, cause) | seeds(value)]
  defp dependencies({:blocked_effects, {_, cause}}, _, _), do: [row(:duties, cause)]

  defp dependencies({collection, {_, {kind, ref} = node}}, _, _)
       when collection in [:erasure_roots, :erasure_reached, :erasure_children] do
    [
      row(
        %{
          evidence: :evidence,
          presentation: :presentations,
          act: :acts,
          attempt: :attempts,
          outcome: :outcomes
        }[kind],
        ref
      ),
      group(:erasure_children, node),
      group(:erasure_sources, node)
    ]
  end

  defp dependencies({:erasure_sources, {_node, target}}, _, _),
    do: [group(:erasure_targets, target), row(:erasure_states, target)]

  defp dependencies({:erasure_targets, {_, ref}}, _, _), do: [row(:erasures, ref)]
  defp dependencies({:erasure_states, _}, _, _), do: []

  defp dependencies({collection, key}, value, context) do
    common =
      if collection == :mandates,
        do: seeds(Map.drop(Map.from_struct(value), [:source_ref])),
        else: seeds(value)

    specific = record_dependencies(collection, key, value, context)

    metadata =
      if collection in Rows.map_collections() and is_map(value) and Map.has_key?(value, :ref),
        do: [row(:event_metadata, value.ref)],
        else: []

    erasure =
      case Map.fetch(@node_kinds, collection) do
        {:ok, kind} ->
          node = {kind, key}

          [group(:erasure_sources, node)] ++
            if(context.erasure?, do: [group(:erasure_children, node)], else: [])

        :error ->
          []
      end

    common ++ specific ++ metadata ++ erasure
  end

  defp record_dependencies(:evidence, key, value, _context) do
    [
      row(:declassifications_by_evidence, key),
      row(:unavailable_evidence, key),
      group(:evidence_subscriptions, value.proposition)
    ] ++
      Enum.map(value.assumptions, &group(:evidence_propositions, &1))
  end

  defp record_dependencies(:presentations, key, _value, _context) do
    [group(:approval_propositions, key), group(:presentation_shows, key)]
  end

  defp record_dependencies(:acts, key, value, _context) do
    Enum.map([:act_outcomes, :act_duties, :act_erasures], &group(&1, key)) ++
      Enum.map(
        [
          :pending_dispatches,
          :terminal_dispatches,
          :meter_reservations,
          :meter_recontainments,
          :duty_meter_resolutions,
          :meter_devolutions
        ],
        &row(&1, key)
      ) ++
      if(value.class == "data.declassify",
        do: [group(:act_declassifications, key)],
        else: []
      )
  end

  defp record_dependencies(:act_declassifications, key, _value, _context),
    do: [row(:declassifications, elem(key, 1))]

  defp record_dependencies(:erasures, _key, value, _context) do
    target_closure(value.target_ref)
  end

  defp record_dependencies(:meter_recontainments, _key, value, _context) do
    [row(:duties, value.cause_key)]
  end

  defp record_dependencies(:attempts, key, value, _context) do
    [
      group(:attempt_outcomes, key),
      group(:attempt_evidence, {value.act_ref, key}),
      row(:consumed_nonces, value.grant_nonce_digest)
    ]
  end

  defp record_dependencies(:decisions, _key, value, _context) do
    [row(:admissions, value.candidate_identity_key)]
  end

  defp record_dependencies(:duties, _key, value, _context) do
    [row(:duty_refs, value.ref)] ++
      Enum.flat_map(value.closing_conditions, fn condition ->
        case Spectre.GAM.Condition.new(condition) do
          {:ok, condition} -> [group(:evidence_propositions, condition.proposition)]
          _ -> []
        end
      end)
  end

  defp record_dependencies(:mandates, key, value, _context) do
    [
      row(:revocations, key),
      row(:mandate_successors, key),
      row(:meters, key),
      row(:meter_owner_aliases, key)
      | Enum.map(value.conditions, &group(:evidence_propositions, &1.proposition))
    ]
  end

  defp record_dependencies(:meter_owner_aliases, _key, value, context) do
    if(context.global?, do: [group(:owner_aliases, value)], else: [row(:meters, value)])
  end

  defp record_dependencies(:holder_mandates, {_, ref}, _value, _context),
    do: [required(:mandates, ref)]

  defp record_dependencies(:owner_aliases, {_, ref}, _value, _context),
    do: [row(:meter_owner_aliases, ref), row(:mandates, ref)]

  defp record_dependencies(:scopes, _key, value, _context) do
    case value.promise_condition do
      nil -> []
      condition -> [group(:evidence_propositions, condition.proposition)]
    end
  end

  defp record_dependencies(collection, {_, ref}, _value, _context)
       when collection in [:evidence_propositions, :attempt_evidence],
       do: [required(:evidence, ref)]

  defp record_dependencies(:approval_propositions, {_, proposition}, _value, _context),
    do: [group(:evidence_propositions, proposition)]

  defp record_dependencies(collection, {_, ref}, _value, _context)
       when collection in [:presentation_shows, :evidence_subscriptions],
       do: [required(:acts, ref)]

  defp record_dependencies(collection, {_, ref}, _value, _context)
       when collection in [:act_outcomes, :attempt_outcomes],
       do: [required(:outcomes, ref)]

  defp record_dependencies(:scope_deadlines, {_, ref}, _value, _context),
    do: [row(:scopes, ref)]

  defp record_dependencies(:act_erasures, {_, ref}, _value, _context),
    do: [required(:erasures, ref)]

  defp record_dependencies(:owner_debts, {_, ref}, _value, _context),
    do: [row(:meter_recontainments, ref)]

  defp record_dependencies(_, _key, _value, _context) do
    []
  end

  # Payloads are application material, not references to the governed graph.
  # The fields that carry governed identifiers, including consequence bindings,
  # remain traversed. Nonexistent identifiers are resolved once per working set.
  defp seeds(value, observations? \\ false)

  defp seeds(%{candidate: candidate} = request, observations?) do
    input =
      case Spectre.GAM.Candidate.new(candidate) do
        {:ok, candidate} -> candidate
        _ -> candidate
      end

    seeds(input, observations?) ++ seeds(Map.delete(request, :candidate), observations?)
  end

  defp seeds(%{"type" => "outcome_recorded", "data" => data}, observations?),
    do:
      Enum.map(data["evidence_refs"] || [], &group(:erasure_children, {:evidence, &1})) ++
        seeds(data, observations?)

  defp seeds(%{"type" => "attempt_started", "identity" => ref, "data" => data}, observations?),
    do: [
      group(:attempt_outcomes, ref),
      group(:attempt_evidence, {data["act_ref"], ref}) | seeds(data, observations?)
    ]

  defp seeds(%{"type" => "act_committed", "identity" => ref, "data" => data}, observations?),
    do:
      Enum.map(
        [:act_outcomes, :act_duties, :act_erasures, :act_declassifications],
        &group(&1, ref)
      ) ++ seeds(data, observations?)

  defp seeds(%{"type" => "evidence_recorded", "identity" => ref, "data" => data}, observations?),
    do: [
      row(:unavailable_evidence, ref),
      group(:erasure_sources, {:evidence, ref}) | seeds(data, observations?)
    ]

  defp seeds(%Spectre.GAM.Evidence{ref: ref} = value, observations?),
    do: [
      row(:unavailable_evidence, ref),
      group(:erasure_sources, {:evidence, ref}) | seeds(Map.from_struct(value), observations?)
    ]

  defp seeds(value, _) when is_binary(value) and byte_size(value) > 0, do: [{:ref, value}]

  defp seeds(value, observations?) when is_map(value) do
    fields = value |> Map.delete(:__struct__) |> Enum.flat_map(&field_seeds(&1, observations?))
    fields ++ binding_seeds(value, observations?)
  end

  defp seeds([], _), do: []

  defp seeds([head | tail], observations?),
    do: seeds(head, observations?) ++ seeds(tail, observations?)

  defp seeds(value, observations?) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.flat_map(&seeds(&1, observations?))

  defp seeds(_, _), do: []

  defp field_seeds({key, item}, observations?) do
    name = if is_atom(key), do: Atom.to_string(key), else: key
    field_seeds(name, item, observations?)
  end

  defp field_seeds(name, item, _)
       when name in ["payload_ref", "rendered_payload_ref", "erasure_target"] and is_binary(item),
       do: target(item)

  defp field_seeds("target_ref", item, _) when is_binary(item), do: target_closure(item)

  defp field_seeds("cause_key", item, observations?),
    do: [row(:duties, item) | seeds(item, observations?)]

  defp field_seeds("duty_ref", item, observations?),
    do: [row(:duty_refs, item) | seeds(item, observations?)]

  defp field_seeds(name, item, observations?)
       when name in @reference_names or name in @structured_names, do: seeds(item, observations?)

  defp field_seeds(_, _, _), do: []

  defp binding_seeds(value, observations?) do
    proposition = field(value, :proposition)
    nonce = field(value, :grant_nonce_digest)
    identity = field(value, :candidate_identity_key) || field(value, :identity_key)

    holder_seeds(value) ++
      proposition_seeds(value, proposition, observations?) ++
      optional_row(:consumed_nonces, nonce) ++ optional_row(:admissions, identity)
  end

  defp holder_seeds(value) do
    if field(value, :identity_key) && is_nil(field(value, :requested_mandate_ref)) &&
         field(value, :proposer_ref),
       do: [group(:holder_mandates, field(value, :proposer_ref))],
       else: []
  end

  defp proposition_seeds(value, proposition, observations?) do
    subscriptions =
      if observations? and not is_nil(proposition),
        do: [group(:evidence_subscriptions, proposition)],
        else: []

    conditions =
      if is_struct(value, Spectre.GAM.Condition),
        do: [group(:evidence_propositions, proposition)],
        else: []

    subscriptions ++ conditions
  end

  defp optional_row(collection, value) when is_binary(value), do: [row(collection, value)]
  defp optional_row(_, _), do: []
  defp field(value, key), do: Map.get(value, key, Map.get(value, Atom.to_string(key)))

  defp erasure?(%{class: "data.erase"}), do: true
  defp erasure?(%{"class" => "data.erase"}), do: true
  defp erasure?(%{"type" => "erasure_requested"}), do: true
  defp erasure?(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.any?(&erasure?/1)
  defp erasure?([]), do: false
  defp erasure?([head | tail]), do: erasure?(head) or erasure?(tail)
  defp erasure?(_), do: false
  defp target(ref), do: [group(:erasure_targets, ref), row(:erasure_states, ref)]

  defp target_closure(ref),
    do: target(ref) ++ [group(:erasure_roots, ref), group(:erasure_reached, ref)]

  defp required(collection, key), do: {:required, collection, key}

  defp row(_, nil), do: nil
  defp row(collection, key), do: {:row, collection, key}
  defp group(collection, key), do: {:page, collection, [group: key]}
end
