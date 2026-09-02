defmodule Spectre.Kernel.Decision do
  @moduledoc """
  Pure admission decision for a classified Candidate.

  This module joins already separated inputs: a Candidate, an authority
  resolution, a Recognition result with its Evidence basis and the current
  Meter view. It performs no I/O, cannot mint a Grant and does not mutate a
  projection. Its result is a portable attribute map accepted by the durable
  `Spectre.Decision` record. The Evidence basis is persisted only when
  evaluation reached the Recognition stage.

  The four outcomes intentionally remain distinct:

    * `:admitted` -- authority, facts and resources cover the Candidate;
    * `:refused` -- a known rule definitively denies it;
    * `:undecidable` -- required or consistent information is unavailable;
    * `:unknown_class` -- the governed surface cannot classify it.
  """

  alias Spectre.Mandate
  alias Spectre.Kernel.{Authority, Meter}

  @pending_issue_source "spectre:pending-mandate-issue-act"

  @row_dimensions [
    :attempt,
    :observe,
    :read,
    :write,
    :disclose,
    :spend,
    :delegate,
    :govern,
    :present
  ]

  @type outcome :: :admitted | :refused | :undecidable | :unknown_class
  @type t :: %{
          required(:outcome) => outcome(),
          required(:reasons) => [term()],
          required(:decided_at) => term(),
          required(:recognition_evidence_refs) => [String.t()],
          required(:reservations) => map(),
          optional(atom()) => term()
        }

  @doc """
  Decides whether `candidate` can be admitted at trusted `time`.

  `mandate` may be the map returned by Authority, `{:ok, mandate}`, `:none`, or
  `{:ambiguous, mandates}`. Accepting the full Authority result helps callers
  preserve ambiguity instead of accidentally choosing the first mandate.
  """
  @spec decide(map(), map() | {:ok, map()} | :none | {:ambiguous, [map()]}, term(), map(), term()) ::
          t()
  def decide(candidate, mandate, recognition, meter_view, time),
    do: decide(candidate, mandate, recognition, [], meter_view, time)

  @doc false
  @spec decide(
          map(),
          map() | {:ok, map()} | :none | {:ambiguous, [map()]},
          term(),
          [String.t()],
          map(),
          term()
        ) :: t()
  def decide(candidate, mandate, recognition, recognition_evidence_refs, meter_view, time)
      when is_map(candidate) and is_list(recognition_evidence_refs) do
    resolution = normalize_mandate(mandate)

    case {unknown_class?(candidate, meter_view), resolution} do
      {true, resolution} ->
        build(
          candidate,
          resolution,
          recognition,
          meter_view,
          time,
          :unknown_class,
          [:candidate_class_not_declared],
          %{},
          []
        )

      {false, :none} ->
        build(
          candidate,
          :none,
          recognition,
          meter_view,
          time,
          :refused,
          [:mandate_absent],
          %{},
          []
        )

      {false, {:ambiguous, mandates}} ->
        refs = Enum.map(mandates, &mandate_ref/1)

        build(
          candidate,
          nil,
          recognition,
          meter_view,
          time,
          :undecidable,
          [{:ambiguous_mandate, refs}],
          %{},
          []
        )

      {false, {:ok, mandate}} ->
        decide_with_mandate(
          candidate,
          mandate,
          recognition,
          recognition_evidence_refs,
          meter_view,
          time
        )

      {false, :invalid} ->
        build(
          candidate,
          nil,
          recognition,
          meter_view,
          time,
          :undecidable,
          [:invalid_authority_resolution],
          %{},
          []
        )
    end
  end

  def decide(_candidate, _mandate, _recognition, _recognition_evidence_refs, _meter_view, time) do
    %{
      outcome: :undecidable,
      reasons: [:invalid_candidate],
      decided_at: time,
      recognition: nil,
      recognition_evidence_refs: [],
      reservations: %{}
    }
  end

  defp decide_with_mandate(
         candidate,
         mandate,
         recognition,
         recognition_evidence_refs,
         meter_view,
         time
       ) do
    with :ok <- mandate_current(mandate, time),
         :ok <- requested_mandate_matches(candidate, mandate),
         :ok <- proposer_matches(candidate, mandate),
         :ok <- scope_covered(candidate, mandate),
         :ok <- values_covered(:subjects, candidate, mandate),
         :ok <- values_covered(:targets, candidate, mandate),
         :ok <- class_covered(candidate, mandate),
         :ok <- row_covered(candidate, mandate),
         :ok <- purpose_covered(candidate, mandate),
         :ok <- accountable_matches(candidate, mandate),
         :ok <- delegation_covered(candidate, mandate, time) do
      decide_after_authority(
        candidate,
        mandate,
        recognition,
        recognition_evidence_refs,
        meter_view,
        time
      )
    else
      result ->
        build_failure(candidate, mandate, recognition, meter_view, time, result, [])
    end
  end

  defp decide_after_authority(
         candidate,
         mandate,
         recognition,
         recognition_evidence_refs,
         meter_view,
         time
       ) do
    with :ok <- recognition_satisfied(recognition, mandate),
         {:ok, reservations} <- reservations(candidate, mandate, meter_view) do
      build(
        candidate,
        mandate,
        recognition,
        meter_view,
        time,
        :admitted,
        [],
        reservations,
        recognition_evidence_refs
      )
    else
      result ->
        build_failure(
          candidate,
          mandate,
          recognition,
          meter_view,
          time,
          result,
          recognition_evidence_refs
        )
    end
  end

  defp build_failure(
         candidate,
         mandate,
         recognition,
         meter_view,
         time,
         {outcome, reason},
         recognition_evidence_refs
       )
       when outcome in [:refused, :undecidable] do
    build(
      candidate,
      mandate,
      recognition,
      meter_view,
      time,
      outcome,
      listify(reason),
      %{},
      recognition_evidence_refs
    )
  end

  defp mandate_current(mandate, time) do
    not_before = get(mandate, [:not_before, :valid_from])
    expires_at = get(mandate, [:expires_at, :valid_until])

    cond do
      present?(not_before) and not at_or_after?(time, not_before) ->
        {:refused, :mandate_not_yet_valid}

      present?(expires_at) and not before?(time, expires_at) ->
        {:refused, :mandate_expired}

      get(mandate, [:status]) in [:inactive, :revoked, :expired] ->
        {:refused, :mandate_inactive}

      true ->
        :ok
    end
  end

  defp class_covered(candidate, mandate) do
    class = get(candidate, [:class, :consequence_class])
    classes = get(mandate, [:classes, :consequence_classes])

    if constraint_covers?(classes, class),
      do: :ok,
      else: {:refused, :class_outside_mandate}
  end

  defp requested_mandate_matches(candidate, mandate) do
    requested = get(candidate, [:requested_mandate_ref, :mandate_ref])

    if not present?(requested) or requested == mandate_ref(mandate),
      do: :ok,
      else: {:refused, :different_mandate_requested}
  end

  defp proposer_matches(candidate, mandate) do
    proposer = get(candidate, [:proposer_ref])
    holder = get(mandate, [:holder_ref, :holder])

    if not present?(proposer) or proposer == holder,
      do: :ok,
      else: {:refused, :proposer_not_mandate_holder}
  end

  defp scope_covered(candidate, mandate) do
    scope = get(candidate, [:scope_ref])
    allowed = get(mandate, [:scope_refs, :scopes, :scope_ref, :scope])

    if not present?(scope) or constraint_covers?(allowed, scope),
      do: :ok,
      else: {:refused, :scope_outside_mandate}
  end

  defp values_covered(kind, candidate, mandate) do
    {candidate_fields, mandate_fields} =
      case kind do
        :subjects -> {[:subject_refs, :subjects], [:subject_refs, :subjects]}
        :targets -> {[:target_refs, :targets], [:target_refs, :targets]}
      end

    values = candidate |> get(candidate_fields, []) |> listify()
    allowed = get(mandate, mandate_fields)

    if Enum.all?(values, &constraint_covers?(allowed, &1)),
      do: :ok,
      else: {:refused, {kind, :outside_mandate}}
  end

  defp row_covered(candidate, mandate) do
    row = get(candidate, [:row])
    ceiling = get(mandate, [:ceiling, :row_ceiling])

    if row_subset?(row, ceiling),
      do: :ok,
      else: {:refused, :row_exceeds_mandate_ceiling}
  end

  defp purpose_covered(candidate, mandate) do
    candidate_ref = get(candidate, [:purpose_ref])
    mandate_ref = get(mandate, [:purpose_ref])
    candidate_params = get(candidate, [:purpose_params], %{})
    mandate_params = get(mandate, [:purpose_params], %{})

    cond do
      candidate_ref != mandate_ref ->
        {:refused, :purpose_outside_mandate}

      candidate_params != mandate_params ->
        {:refused, :purpose_parameters_outside_mandate}

      true ->
        :ok
    end
  end

  defp accountable_matches(candidate, mandate) do
    candidate_ref = get(candidate, [:accountable_ref])
    mandate_ref = get(mandate, [:accountable_ref, :accountable])

    if not present?(candidate_ref) or candidate_ref == mandate_ref,
      do: :ok,
      else: {:refused, :accountable_claim_mismatch}
  end

  defp delegation_covered(candidate, mandate, time) do
    case {row_dimension?(get(candidate, [:row]), :delegate), get(candidate, [:class])} do
      {false, _class} ->
        :ok

      {true, "mandate.delegate"} ->
        candidate |> delegated_mandate() |> verify_delegation(mandate, time)

      {true, "mandate.devolve"} ->
        validate_devolution_consequence(candidate)

      {true, _other_class} ->
        {:refused, :unsupported_delegation_consequence}
    end
  end

  defp validate_devolution_consequence(candidate) do
    consequence = get(candidate, [:consequence], %{})

    case consequence do
      %{
        "mandate_devolve" =>
          %{"child_mandate_ref" => child_mandate_ref, "amounts" => amounts} = command
      }
      when map_size(consequence) == 1 and map_size(command) == 2 and
             is_binary(child_mandate_ref) and child_mandate_ref != "" and is_map(amounts) and
             not is_struct(amounts) and map_size(amounts) > 0 ->
        if Enum.all?(amounts, fn
             {meter_ref, quantity} ->
               is_binary(meter_ref) and meter_ref != "" and is_integer(quantity) and quantity > 0
           end),
           do: :ok,
           else: {:refused, :invalid_meter_devolution}

      _other ->
        {:refused, :invalid_meter_devolution}
    end
  end

  defp delegated_mandate(candidate) do
    consequence = get(candidate, [:consequence], %{})

    case consequence do
      %{"mandate_issue" => draft} when map_size(consequence) == 1 ->
        Mandate.from_issue_draft(draft, @pending_issue_source)

      _other ->
        {:error, :mandate_issue_draft_missing}
    end
  end

  defp verify_delegation({:ok, child}, mandate, time),
    do: verify_delegation(child, mandate, time)

  defp verify_delegation({:error, reason}, _mandate, _time),
    do: {:refused, {:invalid_mandate_issue_draft, reason}}

  defp verify_delegation(child, mandate, time) when is_map(child) do
    case Authority.delegation_within?(mandate, child, time) do
      :ok -> :ok
      {:error, reason} -> {:refused, reason}
    end
  end

  defp verify_delegation(_child, _mandate, _time),
    do: {:undecidable, :delegated_mandate_missing}

  defp recognition_satisfied(recognition, mandate) do
    conditions = get(mandate, [:conditions], [])

    case normalize_recognition(recognition) do
      :satisfied ->
        :ok

      {:unsatisfied, reasons} ->
        {:refused, Enum.map(listify(reasons), &{:evidence_condition_unsatisfied, &1})}

      {:undecidable, reasons} ->
        {:undecidable, Enum.map(listify(reasons), &{:evidence_condition_undecidable, &1})}

      nil when conditions in [nil, []] ->
        :ok

      nil ->
        {:undecidable, :recognition_missing}

      :invalid ->
        {:undecidable, :invalid_recognition_result}
    end
  end

  defp reservations(candidate, mandate, meter_view) do
    requests = get(candidate, [:meter_requests, :requested_resources], %{})
    accounts = meter_accounts_for(meter_view, mandate_ref(mandate))

    with :ok <- meter_row_consistent(candidate, requests),
         :ok <- meters_authorized(requests, mandate),
         {:ok, reservations} <- Meter.plan_reservations(requests, accounts) do
      {:ok, reservation_map(reservations)}
    else
      {:error, {:insufficient_meter_quantity, ref}} ->
        {:refused, {:insufficient_meter_quantity, ref}}

      {:error, {:unknown_meter, ref}} ->
        {:undecidable, {:meter_projection_missing, ref}}

      {:error, reason} ->
        {:undecidable, {:invalid_meter_view_or_request, reason}}

      {:refused, _reason} = refused ->
        refused

      {:undecidable, _reason} = undecidable ->
        undecidable
    end
  end

  defp meter_row_consistent(candidate, requests) do
    spend? = row_dimension?(get(candidate, [:row]), :spend)
    empty? = empty_requests?(requests)

    cond do
      not empty? and not spend? -> {:refused, :meter_request_not_declared_in_row}
      spend? and empty? -> {:undecidable, :spend_row_without_meter_request}
      true -> :ok
    end
  end

  defp meters_authorized(requests, mandate) do
    requested_refs = request_refs(requests)
    authorized_refs = meter_refs(get(mandate, [:meters, :resources]))

    case Enum.find(requested_refs, &(&1 not in authorized_refs)) do
      nil -> :ok
      ref -> {:refused, {:meter_outside_mandate, ref}}
    end
  end

  defp request_refs(nil), do: []

  defp request_refs(requests) when is_map(requests) do
    if request_record?(requests),
      do: [get(requests, [:meter_ref, :ref])],
      else: Map.keys(requests)
  end

  defp request_refs(requests) when is_list(requests) do
    Enum.map(requests, fn
      {ref, _quantity} -> ref
      request when is_map(request) -> get(request, [:meter_ref, :ref])
      _invalid -> nil
    end)
  end

  defp request_refs(_requests), do: [nil]

  defp meter_refs(nil), do: []

  defp meter_refs(meters) when is_map(meters) do
    if meter_record?(meters), do: [get(meters, [:ref, :meter_ref])], else: Map.keys(meters)
  end

  defp meter_refs(meters) when is_list(meters) do
    Enum.map(meters, fn
      {ref, _definition} -> ref
      meter when is_map(meter) -> get(meter, [:ref, :meter_ref])
      ref -> ref
    end)
  end

  defp meter_refs(_meters), do: []

  defp build(
         candidate,
         mandate,
         recognition,
         meter_view,
         time,
         outcome,
         reasons,
         reservations,
         recognition_evidence_refs
       ) do
    mandate = if is_map(mandate), do: mandate, else: %{}

    %{
      candidate_identity_key: get(candidate, [:identity_key]),
      candidate_digest: get(candidate, [:material_digest, :candidate_digest]),
      consent: get(candidate, [:consent]),
      outcome: outcome,
      reasons: reasons,
      decided_at: time,
      mandate_ref: mandate_ref(mandate),
      mandate_revision: get(mandate, [:revision]),
      recognition_refs: recognition_refs(mandate, recognition, meter_view),
      recognition_evidence_refs:
        recognition_evidence_refs
        |> Enum.filter(&present?/1)
        |> Enum.uniq()
        |> Enum.sort(),
      reservations: reservations,
      proposer_ref: get(candidate, [:proposer_ref]),
      executor_ref: get(candidate, [:executor_ref]),
      authorizer_ref: get(mandate, [:grantor_ref, :authorizer_ref]),
      accountable_ref: get(mandate, [:accountable_ref]) || get(candidate, [:accountable_ref]),
      scope_ref: get(candidate, [:scope_ref]),
      host_profile_ref: decision_host_profile_ref(meter_view),
      surface_revision: decision_surface_revision(meter_view),
      authority_revision: get(meter_view, [:authority_revision, :revision])
    }
  end

  defp normalize_mandate({:ok, mandate}) when is_map(mandate), do: {:ok, mandate}
  defp normalize_mandate(mandate) when is_map(mandate), do: {:ok, mandate}
  defp normalize_mandate(mandate) when mandate in [nil, :none], do: :none

  defp normalize_mandate({:ambiguous, mandates}) when is_list(mandates),
    do: {:ambiguous, Enum.filter(mandates, &is_map/1)}

  defp normalize_mandate(_mandate), do: :invalid

  defp normalize_recognition(:satisfied), do: :satisfied
  defp normalize_recognition({:unsatisfied, reason}), do: {:unsatisfied, reason}
  defp normalize_recognition({:undecidable, reason}), do: {:undecidable, reason}
  defp normalize_recognition(nil), do: nil

  defp normalize_recognition(recognition) when is_map(recognition) do
    case get(recognition, [:outcome, :status]) do
      :satisfied -> :satisfied
      :unsatisfied -> {:unsatisfied, get(recognition, [:reasons, :reason], [])}
      :undecidable -> {:undecidable, get(recognition, [:reasons, :reason], [])}
      _other -> :invalid
    end
  end

  defp normalize_recognition(_recognition), do: :invalid

  defp recognition_refs(mandate, recognition, view) do
    supplied = get(view, [:recognition_refs])

    refs =
      cond do
        is_list(supplied) -> supplied
        normalize_recognition(recognition) in [:satisfied, nil] -> condition_refs(mandate)
        true -> condition_refs(mandate)
      end

    refs
    |> Enum.filter(&present?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp condition_refs(mandate) do
    mandate
    |> get([:conditions], [])
    |> listify()
    |> Enum.map(&get(&1, [:ref, :condition_ref]))
  end

  defp reservation_map(reservations) do
    Map.new(reservations, fn reservation ->
      {get(reservation, [:meter_ref, :ref]), get(reservation, [:quantity, :amount])}
    end)
  end

  defp meter_accounts_for(view, mandate_ref) do
    accounts = get(view, [:meter_accounts, :meters, :accounts], view)

    case keyed_value(accounts, mandate_ref) do
      nested when is_map(nested) -> nested
      _other -> accounts
    end
  end

  defp keyed_value(map, key) when is_map(map) do
    Map.get(map, key) || if(is_binary(key), do: Map.get(map, key), else: nil)
  end

  defp keyed_value(_map, _key), do: nil

  defp decision_host_profile_ref(view) do
    get(view, [:host_profile_ref]) || view |> get([:host_profile], %{}) |> get([:ref])
  end

  defp decision_surface_revision(view) do
    get(view, [:surface_revision]) || view |> get([:surface], %{}) |> get([:revision])
  end

  defp unknown_class?(candidate, view) do
    class = get(candidate, [:class, :consequence_class])
    surface = get(view, [:surface])

    cond do
      class in [nil, :unknown, :unknown_class] -> true
      get(candidate, [:known_class], true) == false -> true
      is_map(surface) -> not surface_declares?(surface, class)
      true -> false
    end
  end

  defp surface_declares?(surface, class) do
    declarations = get(surface, [:classes, :declarations], %{})

    cond do
      is_map(declarations) ->
        Map.has_key?(declarations, class) or
          Map.has_key?(declarations, if(is_binary(class), do: class, else: inspect(class)))

      is_list(declarations) ->
        class in declarations or Enum.any?(declarations, &(get(&1, [:class, :name]) == class))

      true ->
        false
    end
  end

  defp row_subset?(nil, _ceiling), do: true
  defp row_subset?(row, ceiling) when ceiling in [:any, :*], do: is_map(row) or is_list(row)
  defp row_subset?(_row, nil), do: false

  defp row_subset?(row, ceiling) when is_map(row) and is_map(ceiling) do
    Enum.all?(@row_dimensions, fn dimension ->
      not row_dimension?(row, dimension) or row_dimension?(ceiling, dimension)
    end)
  end

  defp row_subset?(row, ceiling) when is_list(row) and is_list(ceiling),
    do: MapSet.subset?(MapSet.new(row), MapSet.new(ceiling))

  defp row_subset?(row, ceiling), do: row == ceiling

  defp row_dimension?(row, dimension) when is_map(row), do: get(row, [dimension], false) == true
  defp row_dimension?(row, dimension) when is_list(row), do: dimension in row
  defp row_dimension?(_row, _dimension), do: false

  defp constraint_covers?(allowed, _value) when allowed in [:any, :*], do: true
  defp constraint_covers?(%MapSet{} = allowed, value), do: MapSet.member?(allowed, value)
  defp constraint_covers?(allowed, value) when is_list(allowed), do: value in allowed
  defp constraint_covers?(allowed, value), do: present?(allowed) and allowed == value

  defp empty_requests?(nil), do: true
  defp empty_requests?(requests) when is_map(requests), do: map_size(requests) == 0
  defp empty_requests?(requests) when is_list(requests), do: requests == []
  defp empty_requests?(_requests), do: false

  defp request_record?(request),
    do: is_map(request) and (has_key?(request, :meter_ref) or has_key?(request, :quantity))

  defp meter_record?(meter),
    do:
      is_map(meter) and has_key?(meter, :ceiling) and
        (has_key?(meter, :ref) or has_key?(meter, :meter_ref))

  defp mandate_ref(mandate), do: get(mandate, [:ref, :mandate_ref, :id])

  defp at_or_after?(left, right) do
    case {timestamp(left), timestamp(right)} do
      {{:ok, left}, {:ok, right}} -> left >= right
      _other -> false
    end
  end

  defp before?(left, right) do
    case {timestamp(left), timestamp(right)} do
      {{:ok, left}, {:ok, right}} -> left < right
      _other -> false
    end
  end

  defp timestamp(value) when is_integer(value), do: {:ok, value}
  defp timestamp(%DateTime{} = value), do: {:ok, DateTime.to_unix(value, :millisecond)}

  defp timestamp(%NaiveDateTime{} = value) do
    value
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
    |> then(&{:ok, &1})
  end

  defp timestamp(_value), do: :error

  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp has_key?(map, key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp get(map, fields, default \\ nil)

  defp get(map, fields, default) when is_map(map) do
    Enum.find_value(fields, default, fn field ->
      case fetch(map, field) do
        {:ok, nil} -> nil
        {:ok, value} -> {:found, value}
        :error -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      value -> value
    end
  end

  defp get(_other, _fields, default), do: default

  defp fetch(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(field))
    end
  end
end
