defmodule Spectre.Agent.Runtime do
  @moduledoc false

  # This is data and functions used by Instance's existing temporary worker,
  # not another process, scheduler, supervisor or admission implementation.
  alias Spectre.{Adapter, Candidate, Id, Portable}

  alias Spectre.Agent.{
    Classification,
    Collection,
    Context,
    Flow,
    Learning,
    Observer,
    Prompt,
    Publication,
    RequestBuilder,
    Result,
    Turn,
    Wiring
  }

  alias Spectre.Canonical.Value
  alias Spectre.Instance.{Operation, Request}
  alias Spectre.Router.{Rule, Selection}

  @doc false
  def new(
        module,
        definition,
        adapters,
        bindings,
        value,
        component_states \\ %{},
        restored? \\ false
      ) do
    with {:ok, plan, children} <- Publication.verify(module, definition),
         {:ok, wiring} <- Wiring.resolve(module, adapters),
         true <- is_map(bindings) and not is_struct(bindings),
         {:ok, owners} <- owners(module, definition.ref, plan, children, "", %{}),
         {:ok, flows} <- flows(owners, wiring),
         {:ok, value} <- initialize(module, value, restored?),
         {:ok, components} <- initial_components(owners, component_states, restored?) do
      {:ok,
       %{
         module: module,
         definition: definition,
         wiring: wiring,
         bindings: bindings,
         owners: owners,
         flows: flows,
         components: components,
         current: nil,
         routing_input: nil,
         learned?: false,
         surface: nil
       }, value}
    else
      false -> {:error, :invalid_request_bindings}
      error -> error
    end
  end

  @doc false
  def turn(input, opts, snapshot) do
    runtime = snapshot.authoring

    with {:ok, _plan, _children} <- Publication.verify(runtime.module, runtime.definition),
         {:ok, opts} <-
           Portable.normalize_attrs(
             opts,
             [:flow, :ingress_opts, :sequencer_opts, :context_evidence_refs],
             :handler_turn
           ),
         {:ok, owner, routing} <- select_flow(runtime, opts[:flow]),
         :ok <- Value.validate(input, max_bytes: 65_536),
         {:ok, surface} <- Spectre.surface(snapshot.scope),
         {:ok, context} <- Context.load(owner, runtime.wiring, input),
         {:ok, refs} <- Context.evidence_refs(context),
         {:ok, explicit_refs} <-
           Portable.normalize_refs(
             Map.get(opts, :context_evidence_refs, []),
             :context_evidence_refs
           ),
         opts = Map.put(opts, :context_evidence_refs, Enum.uniq(explicit_refs ++ refs)),
         {:ok, mind_turn} <-
           Spectre.open_turn(snapshot.scope, input, Map.to_list(Map.delete(opts, :flow))),
         :ok <- Context.validate_sources(context, mind_turn) do
      turn = %Turn{
        ref: mind_turn.ref,
        input: input,
        flow: local_flow(routing),
        owner: owner.prefix,
        definition_ref: owner.definition_ref,
        mind_turn: mind_turn,
        context: context,
        routing: if(routing, do: Map.take(routing, [:name, :declaration]))
      }

      {message, turn, normalized} = message(turn, routing, input)

      runtime = %{
        runtime
        | current: turn,
          surface: surface,
          routing_input: normalized,
          learned?: false
      }

      callback =
        case owner.plan.kind do
          :worker -> :handle_work
          :vigil -> :handle_vigil
          _agent -> :handle_turn
        end

      input = if callback == :handle_turn, do: message, else: input
      value = value(runtime, owner, snapshot.value)

      case record_selection(turn, snapshot.scope) do
        {:ok, turn} ->
          apply_callback(
            owner,
            callback,
            [input, turn, value],
            %{runtime | current: turn},
            snapshot
          )

        {:error, _} = error ->
          {:authoring, error, snapshot.value, runtime}
      end
    else
      {:error, _} = error -> {:reply, error}
    end
  end

  @doc false
  def advance(%Request{} = request, opts, snapshot) do
    runtime = snapshot.authoring
    # The owner reserved and compared the exact ticket before dispatch. Recheck
    # loaded code before submission and again after a potentially slow effect.
    with true <- bound_request?(runtime, request, snapshot.instance_ref, snapshot.revision),
         {:ok, _plan, _children} <- Publication.verify(runtime.module, runtime.definition),
         {:ok, proposal} <-
           Observer.span(runtime, :submission, request_metadata(request, runtime), fn ->
             Spectre.propose(snapshot.scope, request.candidate, opts)
           end) do
      finish_request(request, proposal, snapshot)
    else
      # A queued turn may have replaced the request's originating state since
      # the owner accepted it. Never submit it using another turn's context.
      false -> {:reply, {:error, :stale_instance_request}}
      {:error, _} = error -> {:reply, error}
    end
  end

  @doc false
  def recover(request, proposal, snapshot) do
    # Recovery only rereads this durable occurrence; it never calls propose.
    # There is no polling loop or sleeping worker holding the mutation slot.
    case Spectre.recover_proposal(snapshot.scope, proposal) do
      {:ok, proposal} -> finish_request(request, proposal, snapshot)
      {:error, _} = error -> {:reply, error}
    end
  end

  defp finish_request(request, proposal, snapshot) do
    case Result.from_proposal(proposal, snapshot.scope) do
      {:ok, %{status: :pending}} ->
        {:deferred, request, proposal}

      {:ok, result} ->
        result =
          Map.merge(result, %{
            operation: request.operation,
            request_ref: request.ref,
            turn_ref: request.turn_ref
          })

        if bound_request?(snapshot.authoring, request, snapshot.instance_ref, snapshot.revision) do
          continue_result(request, result, snapshot)
        else
          # The effect remains a fact, but its old handler must not overwrite a
          # newer turn's state. Return the facts with the explicit local fence.
          {:reply, {:error, {:instance_continuation_superseded, result}}}
        end

      {:error, _} = error ->
        {:reply, error}
    end
  end

  defp continue_result(request, result, snapshot) do
    runtime = snapshot.authoring

    with {:ok, _scope} <- Operation.current_scope(snapshot.scope),
         {:ok, _plan, _children} <- Publication.verify(runtime.module, runtime.definition),
         refs = result_evidence_refs(result.details),
         {:ok, continued} <-
           Spectre.continue_turn(snapshot.scope, runtime.current.mind_turn, refs) do
      turn = %{runtime.current | requests: [], result: result, mind_turn: continued}
      owner = Map.fetch!(runtime.owners, turn.owner)
      turn = classified_turn(turn, result)
      runtime = %{runtime | current: turn}
      {learning, runtime} = Learning.observe(runtime, owner, request, result)
      result = Map.put(result, :learning, learning)
      primary = result.details.primary

      metadata =
        Map.merge(request_metadata(request, runtime), %{
          status: result.status,
          decision_ref: primary.decision.ref,
          act_ref: if(primary.act, do: primary.act.ref),
          attempt_ref: if(primary.attempt, do: primary.attempt.ref),
          outcome_ref: if(primary.outcome, do: primary.outcome.ref)
        })

      Observer.emit(runtime, [:result], %{}, metadata)
      turn = %{turn | result: result}
      runtime = %{runtime | current: turn}

      args = [request.operation, result, turn, value(runtime, owner, snapshot.value)]
      apply_callback(owner, :handle_result, args, runtime, snapshot)
    else
      # No exception or failed callback re-submits this occurrence. The original
      # result remains durable even if code or Scope changed while awaiting it.
      {:error, _} = error -> {:reply, error}
    end
  end

  defp result_evidence_refs(proposal) do
    fallback =
      case proposal.fallback do
        %{result: result} -> result.evidence
        _not_executed -> []
      end

    Enum.map(proposal.primary.evidence ++ fallback, & &1.ref) |> Enum.uniq()
  end

  @doc false
  def ready?(runtime, request, instance_ref, revision),
    do:
      bound_request?(runtime, request, instance_ref, revision) and
        Enum.any?(runtime.current.requests, &(&1 === request))

  @doc false
  def discard_requests(runtime),
    do: %{runtime | current: %{runtime.current | requests: []}}

  defp bound_request?(%{current: %Turn{} = turn} = runtime, %Request{} = request, ref, revision),
    do:
      request.instance_ref === ref and request.revision === revision and
        request.definition_ref === runtime.definition.ref and request.turn_ref === turn.ref

  defp bound_request?(_runtime, _request, _ref, _revision), do: false

  defp apply_callback(owner, callback, args, runtime, snapshot) do
    with :ok <- Adapter.validate(owner.module, [{callback, length(args)}]),
         {:ok, reply} <-
           Observer.span(
             runtime,
             callback,
             %{
               definition_ref: owner.definition_ref,
               turn_ref: runtime.current.ref,
               flow: runtime.current.flow,
               owner: owner.prefix
             },
             fn -> Adapter.invoke(owner.module, callback, args) end
           ) do
      finish(reply, owner, runtime, snapshot)
    else
      {:error, _} = error -> {:authoring, error, snapshot.value, runtime}
    end
  end

  defp request_metadata(request, runtime),
    do: %{
      instance_ref: request.instance_ref,
      definition_ref: request.definition_ref,
      request_ref: request.ref,
      turn_ref: request.turn_ref,
      operation: request.operation,
      flow: runtime.current.flow,
      owner: runtime.current.owner
    }

  defp finish({:ok, value}, owner, runtime, snapshot),
    do: publish(value, owner, runtime, snapshot, [])

  defp finish({:error, reason, value}, owner, runtime, snapshot) do
    case publish(value, owner, runtime, snapshot, []) do
      {:authoring, {:ok, _turn}, value, runtime} -> {:authoring, {:error, reason}, value, runtime}
      fenced -> fenced
    end
  end

  defp finish({kind, name, data, value}, owner, runtime, snapshot)
       when kind in [:request, :ask, :classify] do
    with {:ok, data} <- prepare_data(kind, name, data, owner, runtime.current),
         ref = Id.generate(),
         {:ok, candidate} <-
           RequestBuilder.build({kind, name}, data, runtime.current, owner, runtime, ref) do
      request = ticket(ref, {kind, name}, candidate, runtime, snapshot)
      publish(value, owner, runtime, snapshot, [request])
    else
      {:error, _} = error -> {:authoring, error, snapshot.value, runtime}
    end
  end

  defp finish({:request, candidates, value}, owner, runtime, snapshot) do
    candidates = List.wrap(candidates)

    with true <- length(candidates) <= 32,
         {:ok, requests} <- alternatives(candidates, runtime, snapshot) do
      publish(value, owner, runtime, snapshot, requests)
    else
      false -> {:authoring, {:error, :too_many_request_alternatives}, snapshot.value, runtime}
      {:error, _} = error -> {:authoring, error, snapshot.value, runtime}
    end
  end

  defp finish(_reply, _owner, runtime, snapshot),
    do: {:authoring, {:error, :invalid_agent_handler_reply}, snapshot.value, runtime}

  defp publish(value, owner, runtime, snapshot, requests) do
    with :ok <-
           Value.validate(
             Enum.map(requests, &Candidate.canonical(&1.candidate)),
             max_bytes: 262_144
           ),
         {:ok, _scope} <- Operation.current_scope(snapshot.scope) do
      turn = %{runtime.current | requests: requests}
      # At most 32 alternatives: this list is both the public view and the
      # owner's exact-ticket check, not a second mutable readiness registry.
      runtime = %{runtime | current: turn}

      if owner.prefix == "" do
        {:authoring, {:ok, turn}, value, runtime}
      else
        revision = runtime.components[owner.prefix].revision + 1

        runtime = %{
          runtime
          | components:
              Map.put(runtime.components, owner.prefix, %{revision: revision, value: value})
        }

        {:authoring, {:ok, turn}, snapshot.value, runtime}
      end
    else
      {:error, _} = error -> {:authoring, error, snapshot.value, discard_requests(runtime)}
    end
  end

  defp alternatives(candidates, runtime, snapshot) do
    Collection.map(candidates, fn value ->
      with {:ok, candidate} <- RequestBuilder.low_level(value, runtime.current) do
        {:ok, ticket(Id.generate(), {:request, candidate.class}, candidate, runtime, snapshot)}
      end
    end)
  end

  defp ticket(ref, operation, candidate, runtime, snapshot),
    do: %Request{
      ref: ref,
      operation: operation,
      candidate: candidate,
      instance_ref: snapshot.instance_ref,
      definition_ref: runtime.definition.ref,
      turn_ref: runtime.current.ref,
      revision: snapshot.revision + 1
    }

  defp prepare_data(:ask, name, assigns, owner, turn),
    do: Prompt.render(owner, turn, name, assigns)

  defp prepare_data(:classify, name, input, owner, turn),
    do: Classification.prepare(owner, turn, name, input)

  defp prepare_data(:request, _name, data, _owner, _turn), do: {:ok, data}

  defp message(turn, nil, input), do: {input, turn, input}

  defp message(turn, routing, input) do
    {normalized, result} = Flow.route_with_input(routing.prepared, input)

    {message, turn} =
      case result do
        {:ok, selection} ->
          local = routing.declaration.routes[selection.candidate].local

          {{turn.flow, local, selection.matched || %{}},
           %{turn | branch: local, selection: selection}}

        :no_match ->
          {{turn.flow, :no_match, input}, turn}

        {:ambiguous, refs} ->
          {{turn.flow, :ambiguous, refs}, turn}

        {:halt, input} ->
          {{turn.flow, :halted, input}, turn}

        {:unrouted, input} ->
          {{turn.flow, :unrouted, input}, turn}

        {:error, reason} ->
          {{turn.flow, :error, reason}, turn}
      end

    {message, turn, normalized}
  end

  defp record_selection(%{selection: nil} = turn, _scope), do: {:ok, turn}

  defp record_selection(turn, scope) do
    with {:ok, evidence} <-
           Selection.evidence(
             turn.selection,
             turn.mind_turn,
             turn.mind_turn.opened_at
           ),
         {:ok, evidence} <- Spectre.record_derivation(scope, turn.mind_turn, evidence),
         {:ok, continued} <- Spectre.continue_turn(scope, turn.mind_turn, [evidence.ref]) do
      {:ok, %{turn | mind_turn: continued}}
    end
  end

  defp classified_turn(turn, %{operation: {:classify, _}, status: :done} = result) do
    case Classification.select(turn, result) do
      {:ok, selection} ->
        branch = turn.routing.declaration.routes[selection.candidate].local
        %{turn | branch: branch, selection: selection}

      _not_selected ->
        turn
    end
  end

  defp classified_turn(turn, _result), do: turn
  defp local_flow(nil), do: nil
  defp local_flow(routing), do: routing.declaration.local

  defp select_flow(runtime, nil) do
    owner = runtime.owners[""]

    # An agent without routes is an ordinary input handler. Once flows exist,
    # selecting one remains the host's decision; do not invent a default.
    if owner.plan.kind in [:worker, :vigil] or map_size(runtime.flows) == 0,
      do: {:ok, owner, nil},
      else: {:error, :agent_flow_required}
  end

  defp select_flow(runtime, name) when is_atom(name) or is_binary(name) do
    case Map.fetch(runtime.flows, to_string(name)) do
      {:ok, routing} -> {:ok, runtime.owners[routing.owner], routing}
      :error -> {:error, {:unknown_agent_flow, name}}
    end
  end

  defp select_flow(_runtime, _name), do: {:error, :invalid_agent_flow}

  defp owners(module, definition_ref, plan, children, prefix, found) do
    # Retain only the execution plan and reference for each owner. The root
    # publication already contains every child Definition; copying those full
    # publications here would repeat them in every temporary worker snapshot.
    found =
      Map.put(found, prefix, %{
        module: module,
        definition_ref: definition_ref,
        plan: operational_plan(plan),
        prefix: prefix
      })

    Enum.reduce_while(plan.components, {:ok, found}, fn {name, child}, {:ok, found} ->
      definition = children[name]

      with {:ok, children} <- Publication.children(definition),
           {:ok, found} <-
             owners(
               child.module,
               definition.ref,
               child.plan,
               children,
               prefix <> name <> "/",
               found
             ) do
        {:cont, {:ok, found}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp operational_plan(plan) do
    plan
    |> Map.drop([:components, :extensions, :ports, :identity])
    |> Map.update!(:jobs, fn jobs ->
      Map.new(jobs, fn {name, job} -> {name, Map.take(job, [:kind, :module])} end)
    end)
  end

  defp flows(owners, wiring) do
    declarations =
      for {prefix, owner} <- owners,
          {name, entry} <- owner.plan.flows,
          do: {prefix <> name, owner, entry}

    with {:ok, flows} <- Collection.map(declarations, &prepare_flow(&1, wiring)) do
      {:ok, Map.new(flows)}
    end
  end

  defp prepare_flow({name, owner, entry}, wiring) do
    with {:ok, prepared} <- Wiring.flow(entry, owner.definition_ref, name, wiring, owner.prefix) do
      {:ok,
       {name,
        %{
          name: name,
          owner: owner.prefix,
          declaration: entry,
          prepared: prepared
        }}}
    end
  end

  defp initialize(_module, value, true), do: {:ok, value}

  defp initialize(module, value, false) do
    case Adapter.invoke(module, :init, [value]) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, _} = error} -> error
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_agent_init_reply}
    end
  end

  defp initial_components(owners, states, restored?) when is_map(states) do
    # Checkpoint names carry a trailing slash; normalize it once, without
    # accepting arbitrary String.Chars implementations or collapsing aliases.
    with {:ok, states} <- component_names(states) do
      initialize_components(owners, states, restored?)
    end
  end

  defp initial_components(_owners, _states, _restored?), do: {:error, :invalid_component_states}

  defp component_names(states) do
    Enum.reduce_while(states, {:ok, %{}}, fn
      {name, value}, {:ok, found} when is_binary(name) or is_atom(name) ->
        name = String.trim_trailing(to_string(name), "/")

        with :ok <- Rule.path(name),
             false <- Map.has_key?(found, name <> "/") do
          {:cont, {:ok, Map.put(found, name <> "/", value)}}
        else
          _invalid -> {:halt, {:error, :invalid_component_state_name}}
        end

      _invalid, _found ->
        {:halt, {:error, :invalid_component_state_name}}
    end)
  end

  defp initialize_components(owners, states, restored?) do
    expected = Map.keys(Map.delete(owners, ""))

    if Map.keys(states) -- expected == [] and
         (not restored? or Enum.sort(Map.keys(states)) == Enum.sort(expected)) do
      with {:ok, components} <-
             Collection.map(Map.delete(owners, ""), &initialize_component(&1, states, restored?)),
           do: {:ok, Map.new(components)}
    else
      {:error, :component_state_names_mismatch}
    end
  end

  defp initialize_component({name, owner}, states, restored?) do
    with {:ok, value} <- initialize(owner.module, Map.get(states, name, %{}), restored?) do
      state = if restored?, do: value, else: %{revision: 0, value: value}
      {:ok, {name, state}}
    end
  end

  defp value(_runtime, %{prefix: ""}, root), do: root
  defp value(runtime, owner, _root), do: Map.fetch!(runtime.components, owner.prefix).value
end
