defmodule Spectre.Kernel.Decision do
  @moduledoc """
  Pure admission decision for one classified Candidate.

  This module joins four already-separated inputs: a typed Candidate, the
  result of authority resolution, Recognition's factual result and a typed
  snapshot of Meter/foundation state. It performs no I/O, mints no Grant and
  mutates no projection. Its output is the portable attribute map accepted by
  the durable `Spectre.Decision` record.

  Authority narrowing is represented by `Spectre.Kernel.Authority.Effective`;
  it is never guessed from a generic map. Likewise environmental fields live
  in `Spectre.Kernel.Decision.Context`. These two containers keep the decision
  boundary explicit without turning it into another stateful subsystem.

  The four outcomes intentionally remain distinct:

    * `:admitted` -- authority, facts and resources cover the Candidate;
    * `:refused` -- a known rule definitively denies it;
    * `:undecidable` -- required or consistent information is unavailable;
    * `:unknown_class` -- the governed Surface cannot classify it.
  """

  alias Spectre.{Candidate, Mandate, Row}
  alias Spectre.Kernel.{Authority, Meter}
  alias Spectre.Kernel.Authority.Effective
  alias Spectre.Kernel.Decision.Context

  @pending_issue_source "spectre:pending-mandate-issue-act"

  @type recognition ::
          :satisfied | {:unsatisfied, [term()]} | {:undecidable, [term()]} | nil

  @type outcome :: :admitted | :refused | :undecidable | :unknown_class
  @type t :: %{
          required(:outcome) => outcome(),
          required(:reasons) => [term()],
          required(:decided_at) => integer(),
          required(:recognition_evidence_refs) => [String.t()],
          required(:reservations) => map(),
          optional(atom()) => term()
        }

  @doc """
  Decides whether `candidate` can be admitted at trusted `time`.

  The full authority resolution is accepted so ambiguity cannot be collapsed
  by accidentally selecting the first eligible Mandate.
  """
  @spec decide(Candidate.t(), Authority.resolution(), recognition(), Context.t(), integer()) ::
          t()
  def decide(candidate, resolution, recognition, context, time),
    do: decide(candidate, resolution, recognition, [], context, time)

  @doc false
  @spec decide(
          Candidate.t(),
          Authority.resolution(),
          recognition(),
          [String.t()],
          Context.t(),
          integer()
        ) :: t()
  def decide(
        %Candidate{} = candidate,
        resolution,
        recognition,
        recognition_evidence_refs,
        %Context{} = context,
        time
      )
      when is_list(recognition_evidence_refs) and is_integer(time) do
    case resolution do
      :none ->
        build(candidate, nil, context, time, :refused, [:mandate_absent], %{}, [])

      {:ambiguous, mandates} when is_list(mandates) ->
        refs = mandates |> Enum.map(&Effective.ref/1) |> Enum.sort()

        build(
          candidate,
          nil,
          context,
          time,
          :undecidable,
          [{:ambiguous_mandate, refs}],
          %{},
          []
        )

      {:ok, %Effective{} = authority} ->
        case Effective.snapshot(authority, candidate) do
          {:ok, snapshot} ->
            decide_with_authority(
              candidate,
              snapshot,
              recognition,
              recognition_evidence_refs,
              context,
              time
            )

          {:error, reason} ->
            build(candidate, nil, context, time, :undecidable, [reason], %{}, [])
        end

      _invalid_resolution ->
        build(
          candidate,
          nil,
          context,
          time,
          :undecidable,
          [:invalid_authority_resolution],
          %{},
          []
        )
    end
  end

  def decide(_candidate, _resolution, _recognition, _basis, _context, time) do
    %{
      outcome: :undecidable,
      reasons: [:invalid_candidate],
      decided_at: time,
      recognition_refs: [],
      recognition_evidence_refs: [],
      reservations: %{}
    }
  end

  defp decide_with_authority(candidate, authority, recognition, basis_refs, context, time) do
    with :ok <- authority_covers(candidate, authority, time),
         :ok <- recognition_satisfied(recognition, authority),
         {:ok, reservations} <- reservations(candidate, authority, context) do
      build(
        candidate,
        authority,
        context,
        time,
        :admitted,
        [],
        reservations,
        basis_refs
      )
    else
      {outcome, reason} when outcome in [:refused, :undecidable] ->
        build(
          candidate,
          authority,
          context,
          time,
          outcome,
          List.wrap(reason),
          %{},
          basis_refs
        )
    end
  end

  # Authority performs the full resolution. These inexpensive checks bind the
  # supplied Effective snapshot to this exact Candidate before it is recorded.
  defp authority_covers(candidate, authority, time) do
    with :ok <- current_at(authority, time),
         :ok <- requested_mandate_matches(candidate, authority),
         :ok <- proposer_matches(candidate, authority),
         :ok <- member(authority.scope_refs, candidate.scope_ref, :scope_outside_mandate),
         :ok <-
           subset(candidate.subject_refs, authority.subject_refs, {:subjects, :outside_mandate}),
         :ok <- subset(candidate.target_refs, authority.target_refs, {:targets, :outside_mandate}),
         :ok <- member(authority.classes, candidate.class, :class_outside_mandate),
         :ok <- row_covered(candidate, authority),
         :ok <- purpose_covered(candidate, authority),
         :ok <- accountable_matches(candidate, authority) do
      delegation_covered(candidate, authority, time)
    end
  end

  defp current_at(authority, time) do
    cond do
      time < authority.not_before -> {:refused, :mandate_not_yet_valid}
      time >= authority.expires_at -> {:refused, :mandate_expired}
      true -> :ok
    end
  end

  defp requested_mandate_matches(candidate, authority) do
    if is_nil(candidate.requested_mandate_ref) or
         candidate.requested_mandate_ref == authority.ref,
       do: :ok,
       else: {:refused, :different_mandate_requested}
  end

  defp proposer_matches(candidate, authority) do
    if candidate.proposer_ref == authority.holder_ref,
      do: :ok,
      else: {:refused, :proposer_not_mandate_holder}
  end

  defp member(allowed, value, reason) do
    if value in allowed, do: :ok, else: {:refused, reason}
  end

  defp subset(values, allowed, reason) do
    allowed = MapSet.new(allowed)
    if Enum.all?(values, &MapSet.member?(allowed, &1)), do: :ok, else: {:refused, reason}
  end

  defp row_covered(candidate, authority) do
    if Row.subset?(candidate.row, authority.ceiling),
      do: :ok,
      else: {:refused, :row_exceeds_mandate_ceiling}
  end

  defp purpose_covered(candidate, authority) do
    cond do
      candidate.purpose_ref != authority.purpose_ref ->
        {:refused, :purpose_outside_mandate}

      candidate.purpose_params != authority.purpose_params ->
        {:refused, :purpose_parameters_outside_mandate}

      true ->
        :ok
    end
  end

  defp accountable_matches(candidate, authority) do
    if candidate.accountable_ref == authority.accountable_ref,
      do: :ok,
      else: {:refused, :accountable_claim_mismatch}
  end

  defp delegation_covered(%Candidate{row: %{delegate: false}}, _authority, _time), do: :ok

  defp delegation_covered(%Candidate{class: "mandate.delegate"} = candidate, authority, time) do
    candidate
    |> delegated_mandate()
    |> verify_delegation(source_mandate(authority), time)
  end

  defp delegation_covered(%Candidate{class: "mandate.devolve"} = candidate, _authority, _time),
    do: validate_devolution_consequence(candidate)

  defp delegation_covered(_candidate, _authority, _time),
    do: {:refused, :unsupported_delegation_consequence}

  defp validate_devolution_consequence(candidate) do
    case candidate.consequence do
      %{
        "mandate_devolve" =>
          %{"child_mandate_ref" => child_mandate_ref, "amounts" => amounts} = command
      } = consequence
      when map_size(consequence) == 1 and map_size(command) == 2 and
             is_binary(child_mandate_ref) and child_mandate_ref != "" and is_map(amounts) and
             not is_struct(amounts) and map_size(amounts) > 0 ->
        if Enum.all?(amounts, fn
             {meter_ref, quantity} ->
               is_binary(meter_ref) and meter_ref != "" and is_integer(quantity) and quantity > 0
           end),
           do: :ok,
           else: {:refused, :invalid_meter_devolution}

      _invalid ->
        {:refused, :invalid_meter_devolution}
    end
  end

  defp delegated_mandate(candidate) do
    case candidate.consequence do
      %{"mandate_issue" => draft} = consequence when map_size(consequence) == 1 ->
        Mandate.from_issue_draft(draft, @pending_issue_source)

      _invalid ->
        {:error, :mandate_issue_draft_missing}
    end
  end

  defp verify_delegation({:ok, child}, parent, time) do
    case Authority.delegation_within?(parent, child, time) do
      :ok -> :ok
      {:error, reason} -> {:refused, reason}
    end
  end

  defp verify_delegation({:error, reason}, _parent, _time),
    do: {:refused, {:invalid_mandate_issue_draft, reason}}

  defp recognition_satisfied(:satisfied, _authority), do: :ok

  defp recognition_satisfied({:unsatisfied, reasons}, _authority) when is_list(reasons),
    do: {:refused, Enum.map(reasons, &{:evidence_condition_unsatisfied, &1})}

  defp recognition_satisfied({:undecidable, reasons}, _authority) when is_list(reasons),
    do: {:undecidable, Enum.map(reasons, &{:evidence_condition_undecidable, &1})}

  defp recognition_satisfied(nil, %{conditions: []}), do: :ok
  defp recognition_satisfied(nil, _authority), do: {:undecidable, :recognition_missing}

  defp recognition_satisfied(_invalid, _authority),
    do: {:undecidable, :invalid_recognition_result}

  defp reservations(candidate, authority, context) do
    requests = candidate.meter_requests

    with :ok <- meter_row_consistent(candidate),
         :ok <- meters_authorized(requests, authority),
         {:ok, reservations} <- Meter.plan_reservations(requests, context.meter_accounts) do
      {:ok, reservations}
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

  defp meter_row_consistent(candidate) do
    empty? = map_size(candidate.meter_requests) == 0

    cond do
      not empty? and not candidate.row.spend -> {:refused, :meter_request_not_declared_in_row}
      candidate.row.spend and empty? -> {:undecidable, :spend_row_without_meter_request}
      true -> :ok
    end
  end

  defp meters_authorized(requests, authority) do
    authorized = authority.meters |> Map.keys() |> MapSet.new()

    case Enum.find(Map.keys(requests), &(not MapSet.member?(authorized, &1))) do
      nil -> :ok
      ref -> {:refused, {:meter_outside_mandate, ref}}
    end
  end

  defp build(candidate, authority, context, time, outcome, reasons, reservations, basis_refs) do
    %{
      candidate_identity_key: candidate.identity_key,
      candidate_digest: candidate.material_digest,
      consent: candidate.consent,
      outcome: outcome,
      reasons: reasons,
      decided_at: time,
      mandate_ref: authority_field(authority, :ref),
      mandate_revision: authority_field(authority, :revision),
      recognition_refs: condition_refs(authority),
      recognition_evidence_refs: normalize_refs(basis_refs),
      reservations: reservations,
      proposer_ref: candidate.proposer_ref,
      executor_ref: candidate.executor_ref,
      authorizer_ref: authority_field(authority, :grantor_ref),
      accountable_ref: authority_field(authority, :accountable_ref, candidate.accountable_ref),
      scope_ref: candidate.scope_ref,
      host_profile_ref: context.host_profile_ref,
      surface_revision: context.surface_revision,
      authority_revision: context.authority_revision
    }
  end

  defp authority_field(authority, field, default \\ nil)

  defp authority_field(authority, field, _default) when is_map(authority),
    do: Map.fetch!(authority, field)

  defp authority_field(nil, _field, default), do: default

  defp condition_refs(nil), do: []

  defp condition_refs(authority) when is_map(authority),
    do: Enum.map(authority.conditions, & &1.ref)

  defp source_mandate(%Mandate{} = mandate), do: mandate

  defp normalize_refs(refs) do
    refs
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end
end
