defmodule Spectre.GAM.Scope.Diagnostics do
  @moduledoc """
  Bounded, redacted pages derived from an authenticated Scope view.

  Cursors belong to one Scope, revision and interaction filter. A changed head
  returns `:stale_cursor`; clients restart from the first page. Projection work
  still scans retained history inside the Domain, while mailbox output is bounded.
  No payloads, credentials, authority handles or action arguments are returned.
  """
  alias Spectre.GAM.Scope.View

  @collections [
    decisions: :decision,
    acts: :act,
    attempts: :attempt,
    outcomes: :outcome,
    duties: :duty,
    evidence: :evidence,
    presentations: :presentation,
    erasures: :erasure,
    declassifications: :declassification
  ]
  @fields [
    :ref,
    :act_ref,
    :decision_ref,
    :attempt_ref,
    :presentation_ref,
    :scope_ref,
    :status,
    :outcome,
    :class,
    :candidate_class,
    :decided_at,
    :committed_at,
    :started_at,
    :observed_at,
    :opened_at,
    :disposition_act_ref
  ]
  @invocations [
    :spectre_agent_invocation,
    :spectre_skill_invocation,
    :spectre_external_invocation
  ]

  @doc "Projects a page using the kernel's existing Scope visibility and erasure rules."
  @spec page(map(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def page(projection, scope_ref, opts) do
    with {:ok, limit, interaction, cursor} <- options(opts),
         {:ok, offset} <- offset(cursor, projection.revision, scope_ref, interaction),
         {:ok, view} <- View.from_projection(projection, scope_ref) do
      records = records(view, interaction)
      page = Enum.slice(records, offset, limit)
      next_offset = offset + length(page)

      next =
        if next_offset < length(records),
          do: {1, view.revision, scope_ref, interaction, next_offset},
          else: nil

      counts =
        Map.new(@collections, fn {key, kind} ->
          {key, Enum.count(records, &(&1.kind == kind))}
        end)

      {:ok,
       %{
         version: 1,
         revision: view.revision,
         records: page,
         counts: counts,
         next_cursor: next,
         total: length(records),
         coverage: %{
           source: :gam_scope,
           complete: false,
           missing: [:cognitive_commands, :historical_routing, :model_reasoning],
           correlation: :recorded_invocation_evidence
         }
       }}
    end
  end

  @spec options(term()) :: {:ok, pos_integer(), binary() | nil, term()} | {:error, atom()}
  defp options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- [:limit, :interaction, :cursor] == [] do
      limit = Keyword.get(opts, :limit, 50)
      interaction = Keyword.get(opts, :interaction)

      cond do
        not (is_integer(limit) and limit in 1..100) ->
          {:error, :invalid_diagnostic_limit}

        not (is_nil(interaction) or (is_binary(interaction) and byte_size(interaction) in 1..256)) ->
          {:error, :invalid_interaction_id}

        true ->
          {:ok, limit, interaction, Keyword.get(opts, :cursor)}
      end
    else
      {:error, :invalid_diagnostic_options}
    end
  end

  defp options(_), do: {:error, :invalid_diagnostic_options}

  @spec offset(term(), non_neg_integer(), binary(), binary() | nil) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  defp offset(nil, _, _, _), do: {:ok, 0}

  defp offset({1, revision, scope, interaction, offset}, revision, scope, interaction)
       when is_integer(offset) and offset >= 0, do: {:ok, offset}

  defp offset({1, old, scope, interaction, _}, revision, scope, interaction) when old != revision,
    do: {:error, :stale_cursor}

  defp offset(_, _, _, _), do: {:error, :invalid_cursor}

  @spec records(View.t(), binary() | nil) :: [map()]
  defp records(view, interaction) do
    invocation = Enum.filter(view.evidence, &invocation?/1)

    selected =
      Enum.filter(invocation, &(is_nil(interaction) or &1.payload[:interaction] == interaction))

    lifecycle = Enum.filter(view.evidence, &lifecycle_matches?(&1, interaction))

    evidence_refs = MapSet.new(selected ++ lifecycle, & &1.ref)

    candidate_keys =
      selected
      |> Enum.flat_map(fn evidence ->
        id = evidence.payload.command_id
        ["spectre:managed:" <> id, "spectre:managed:show:" <> id]
      end)
      |> MapSet.new()

    acts =
      Enum.filter(view.acts, fn act ->
        Enum.any?(act.evidence_refs, &MapSet.member?(evidence_refs, &1))
      end)

    act_refs = MapSet.new(acts, & &1.ref)
    decision_refs = MapSet.new(acts, & &1.decision_ref)

    presentation_refs =
      MapSet.new(
        Enum.flat_map(acts, fn act ->
          case Spectre.GAM.Presentation.show_presentation_ref(act.consequence) do
            {:ok, ref} -> [ref, act.presentation_ref]
            _ -> [act.presentation_ref]
          end
        end)
      )

    Enum.flat_map(@collections, fn {key, kind} ->
      view
      |> Map.fetch!(key)
      |> Enum.filter(fn record ->
        is_nil(interaction) or
          linked?(
            kind,
            record,
            evidence_refs,
            candidate_keys,
            act_refs,
            decision_refs,
            presentation_refs
          )
      end)
      |> Enum.map(&display_record(&1, kind))
    end)
    |> Enum.sort_by(&{timestamp(&1), &1.kind, &1.ref})
  end

  defp lifecycle_matches?(
         %{proposition: {:spectre_server_lifecycle, _}, payload: %{event: event}},
         interaction
       )
       when is_map(event),
       do:
         is_nil(interaction) or event[:interaction_id] == interaction or
           event[:origin_id] == interaction

  defp lifecycle_matches?(_, _), do: false

  defp display_record(record, kind) do
    fields =
      record |> Map.take(@fields) |> Map.new(fn {key, value} -> {key, scalar(value)} end)

    fields =
      if kind == :decision do
        codes = record.reasons |> Enum.take(20) |> Enum.map(&reason_code/1)
        Map.put(fields, :reason_codes, codes)
      else
        fields
      end

    fields =
      if kind == :evidence and invocation?(record),
        do:
          Map.merge(fields, %{
            event: elem(record.proposition, 0),
            command_id: scalar(record.payload[:command_id]),
            interaction_id: scalar(record.payload[:interaction]),
            skill: scalar(record.payload[:skill])
          }),
        else: fields

    fields =
      case record do
        %{proposition: {:spectre_server_lifecycle, _}, payload: %{event: event}}
        when is_map(event) ->
          safe =
            Map.take(event, [:phase, :kind, :status, :from_status, :to_status, :reason])
            |> Map.new(&safe_lifecycle_field/1)

          Map.merge(fields, %{event: :spectre_server_lifecycle, lifecycle: safe})

        _ ->
          fields
      end

    Map.put(fields, :kind, kind)
  end

  defp safe_lifecycle_field({key, value}) when is_atom(value), do: {key, value}
  defp safe_lifecycle_field({key, _value}), do: {key, nil}

  @spec linked?(atom(), map(), MapSet.t(), MapSet.t(), MapSet.t(), MapSet.t(), MapSet.t()) ::
          boolean()
  defp linked?(:evidence, record, evidence, _, _, _, _), do: MapSet.member?(evidence, record.ref)
  defp linked?(:act, record, _, _, acts, _, _), do: MapSet.member?(acts, record.ref)

  defp linked?(:decision, record, _, candidate_keys, _, decisions, _) do
    MapSet.member?(decisions, record.ref) or
      MapSet.member?(candidate_keys, record.candidate_identity_key)
  end

  defp linked?(:presentation, record, _, _, _, _, presentations),
    do: MapSet.member?(presentations, record.ref)

  defp linked?(_, record, _, _, acts, _, _), do: MapSet.member?(acts, Map.get(record, :act_ref))

  @spec invocation?(map()) :: boolean()
  defp invocation?(%{proposition: {kind, id}, payload: %{command_id: id}})
       when kind in @invocations,
       do: is_binary(id)

  defp invocation?(_), do: false

  @spec scalar(term()) :: term()
  defp scalar(value) when is_atom(value) or is_integer(value), do: value
  defp scalar(value) when is_binary(value) and byte_size(value) <= 256, do: value
  defp scalar(_), do: nil

  @spec reason_code(term()) :: atom()
  defp reason_code(reason) when is_atom(reason), do: reason

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    if is_atom(elem(reason, 0)), do: elem(reason, 0), else: :redacted
  end

  defp reason_code(_), do: :redacted

  @spec timestamp(map()) :: integer()
  defp timestamp(record) do
    Enum.find_value(
      [:decided_at, :committed_at, :started_at, :observed_at, :opened_at],
      0,
      fn key -> if is_integer(record[key]), do: record[key] end
    )
  end
end
