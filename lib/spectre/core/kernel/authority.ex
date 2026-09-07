defmodule Spectre.Kernel.Authority do
  @moduledoc """
  Pure resolution of the authority that may cover a candidate.

  Authority is resolved exclusively from the candidate, the authenticated
  `SubmissionContext`, the current authority view and trusted time. Evidence is
  deliberately absent from this API: facts may satisfy a mandate's conditions,
  but they cannot create or select the mandate itself.

  Every ledger record is decoded before it reaches this module. The resolver
  therefore consumes typed Candidates and Mandates plus the closed
  `Spectre.Kernel.Authority.Facts` container; accepting alternate storage
  shapes here would make authority semantics depend on map-key guesses.
  """

  alias Spectre.{Act, Candidate, Mandate}

  alias Spectre.Kernel.Authority.{
    Attenuation,
    Coverage,
    Effective,
    Facts,
    RetainedRevocation,
    Status
  }

  @required_context_fields [
    :domain_ref,
    :scope_ref,
    :authenticated_principal_ref,
    :authentication_ref,
    :ingress_ref,
    :host_generation
  ]

  @typedoc "The authority-relevant subset shared by a live or replayed submission context."
  @type context :: %{
          required(:domain_ref) => String.t(),
          required(:scope_ref) => String.t(),
          required(:authenticated_principal_ref) => String.t(),
          required(:authentication_ref) => String.t(),
          required(:ingress_ref) => String.t(),
          required(:host_generation) => non_neg_integer(),
          optional(atom()) => term()
        }

  @type effective :: Effective.t()

  @type resolution ::
          {:ok, effective()}
          | :none
          | {:ambiguous, [effective()]}

  @doc """
  Resolves the one current mandate which covers `candidate`.

  `:none` includes an unauthenticated or self-contradicting submission context.
  Multiple independently eligible mandates are returned explicitly instead of
  being selected by order, evidence, or caller preference.
  """
  @spec resolve(Candidate.t(), context(), Facts.t(), integer()) :: resolution()
  def resolve(%Candidate{} = candidate, context, %Facts{} = view, time)
      when is_map(context) and is_integer(time) do
    eligible =
      candidate_mandates(candidate, view)
      |> Enum.flat_map(fn mandate ->
        case authorize(candidate, context, mandate, view, time) do
          {:ok, effective_mandate} -> [effective_mandate]
          {:error, _reason} -> []
        end
      end)
      |> Enum.sort_by(&mandate_sort_key/1)

    case eligible do
      [] -> :none
      [mandate] -> {:ok, mandate}
      mandates -> {:ambiguous, mandates}
    end
  end

  def resolve(_candidate, _context, _view, _time), do: :none

  @doc """
  Explains whether one mandate is eligible without consulting Evidence.

  This function is useful to auditors and to tests which need a stable reason
  for exclusion. It does not check whether mandate Evidence conditions are met
  or whether a Meter currently has sufficient available quantity.
  """
  @spec eligible?(Candidate.t(), context(), Mandate.t(), Facts.t(), integer()) ::
          :ok | {:error, term()}
  def eligible?(%Candidate{} = candidate, context, %Mandate{} = mandate, %Facts{} = view, time)
      when is_map(context) and is_integer(time) do
    case authorize(candidate, context, mandate, view, time) do
      {:ok, _effective_mandate} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def eligible?(_candidate, _context, _mandate, _view, _time),
    do: {:error, :invalid_authority_input}

  @doc """
  Validates one durable Mandate and returns the exact authority used by Decision.

  Usually that is the Mandate itself. A `retained_controller` revocation is the
  one narrow exception recorded by the Mandate: while it is current, a named
  controller may revoke that exact Mandate through the ledger kernel. The
  returned map narrows every field to that single consequence; it is not a new
  durable Mandate and cannot authorize any other Candidate.
  """
  @spec authorize(Candidate.t(), context(), Mandate.t(), Facts.t(), integer()) ::
          {:ok, effective()} | {:error, term()}
  def authorize(%Candidate{} = candidate, context, %Mandate{} = mandate, %Facts{} = view, time)
      when is_map(context) and is_integer(time) do
    with :ok <- authenticated_context(context),
         :ok <- Status.exact_snapshot(mandate, view),
         :ok <- matching_scope_context(candidate, context) do
      if RetainedRevocation.request?(candidate, mandate) do
        RetainedRevocation.authorize(candidate, context, mandate, view, time)
      else
        ordinary_authority(candidate, context, mandate, view, time)
      end
    end
  end

  def authorize(_candidate, _context, _mandate, _view, _time),
    do: {:error, :invalid_authority_input}

  defp ordinary_authority(candidate, context, mandate, view, time) do
    with :ok <- Status.standing(mandate, view),
         :ok <- containment_status(candidate, view),
         :ok <- Coverage.matching_principal(candidate, context, mandate),
         :ok <- Coverage.covered_executor(candidate, mandate),
         :ok <- Coverage.requested_mandate(candidate, mandate),
         :ok <- Status.current_at(mandate, time),
         :ok <- Status.not_revoked(mandate, view, time),
         :ok <- Coverage.matching_scope(candidate, mandate),
         :ok <- Coverage.covered_values(:subjects, candidate, mandate),
         :ok <- Coverage.covered_values(:targets, candidate, mandate),
         :ok <- Coverage.covered_class(candidate, mandate),
         :ok <- Coverage.declassification_owners(candidate, mandate, view),
         :ok <- Coverage.covered_row(candidate, mandate),
         :ok <- Coverage.covered_disclosure(candidate, mandate),
         :ok <- Coverage.covered_purpose(candidate, mandate),
         :ok <- Coverage.matching_accountable(candidate, mandate) do
      {:ok, Effective.from_mandate(mandate, candidate)}
    end
  end

  @doc "Returns whether a Mandate branch is blocked by an unresolved Meter debt."
  @spec meter_debt_status(Mandate.t(), Facts.t()) ::
          :ok | {:error, term()}
  def meter_debt_status(%Mandate{} = mandate, %Facts{} = view),
    do: Status.meter_debt(mandate, view)

  def meter_debt_status(_mandate, _view), do: {:error, :invalid_authority_input}

  @doc "Returns whether a Mandate or one of its authority ancestors has been superseded."
  @spec restriction_status(Mandate.t(), Facts.t()) ::
          :ok | {:error, term()}
  def restriction_status(%Mandate{} = mandate, %Facts{} = view),
    do: Status.restriction(mandate, view)

  def restriction_status(_mandate, _view), do: {:error, :invalid_authority_input}

  @doc false
  @spec containment_status(Candidate.t() | Act.t(), Facts.t()) ::
          :ok | {:error, term()}
  def containment_status(candidate, %Facts{} = view)
      when is_struct(candidate, Candidate) or is_struct(candidate, Act) do
    with {:ok, digest} <- Candidate.effect_digest(candidate) do
      if MapSet.member?(view.blocked_effect_digests, digest),
        do: {:error, :consequence_retry_contained},
        else: :ok
    end
  end

  def containment_status(_candidate, _view), do: {:error, :invalid_authority_input}

  @doc "Rechecks mutable authority facts before an admitted Act may start execution."
  @spec dispatchable?(Act.t(), Mandate.t(), Facts.t(), integer()) :: :ok | {:error, term()}
  def dispatchable?(%Act{} = act, %Mandate{} = mandate, %Facts{} = view, time)
      when is_integer(time) do
    with :ok <- Status.exact_snapshot(mandate, view),
         true <- act.mandate_ref == mandate.ref and act.mandate_revision == mandate.revision,
         :ok <- Status.standing(mandate, view),
         :ok <- containment_status(act, view),
         :ok <- Status.current_at(mandate, time),
         :ok <- Status.not_revoked(mandate, view, time) do
      :ok
    else
      false -> {:error, :act_mandate_snapshot_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def dispatchable?(_act, _mandate, _view, _time),
    do: {:error, :invalid_authority_input}

  @doc """
  Verifies that a child Mandate is a subtractive restriction of its parent.

  Quantitative transfer still has to be applied through `Kernel.Meter.delegate/3`;
  this function checks declared ceilings, not mutable balances. It also requires
  the parent's conditions to be preserved or strengthened and the recorded
  revocation policy to remain identical. Equality is intentionally used for
  opaque purpose parameters and revocation policies because the core has no
  safe domain-independent way to infer a broader restriction relation. It never
  creates the child or changes either Mandate.
  """
  @spec delegation_within?(
          Mandate.t() | map() | keyword(),
          Mandate.t() | map() | keyword(),
          integer()
        ) ::
          :ok | {:error, term()}
  defdelegate delegation_within?(parent, child, time), to: Attenuation

  @doc """
  Verifies that a successor is a strict, non-quantitative restriction.

  Restriction keeps the same authority lineage and Meter allocation while
  narrowing at least one decidable boundary. Moving or shrinking quantities is
  deliberately left to delegation/devolution, so replacing a Mandate cannot
  silently mint, destroy or strand an in-flight allocation.
  """
  @spec restriction_within?(
          Mandate.t() | map() | keyword(),
          Mandate.t() | map() | keyword(),
          integer()
        ) ::
          :ok | {:error, term()}
  defdelegate restriction_within?(predecessor, successor, time), to: Attenuation

  @doc "Verifies that every label owner explicitly granted within a Mandate lineage."
  @spec owners_authorize_mandate?(
          Mandate.t(),
          [String.t()],
          Facts.t()
        ) ::
          :ok | {:error, term()}
  defdelegate owners_authorize_mandate?(mandate, owner_refs, view), to: Coverage

  defp authenticated_context(context) do
    case Enum.find(@required_context_fields, &(not present?(Map.get(context, &1)))) do
      nil ->
        if is_integer(context.host_generation) and context.host_generation >= 0,
          do: :ok,
          else: {:error, :invalid_host_generation}

      :authenticated_principal_ref ->
        {:error, :unauthenticated_submission}

      field ->
        {:error, {:incomplete_submission_context, field}}
    end
  end

  defp matching_scope_context(candidate, context) do
    if candidate.scope_ref == context.scope_ref,
      do: :ok,
      else: {:error, :candidate_scope_mismatch}
  end

  defp mandate_sort_key(%Effective{} = authority),
    do: {Effective.ref(authority), Effective.revision(authority)}

  defp candidate_mandates(%Candidate{requested_mandate_ref: nil}, %Facts{} = view),
    do: Map.values(view.mandates)

  defp candidate_mandates(%Candidate{requested_mandate_ref: ref}, %Facts{} = view) do
    case Map.fetch(view.mandates, ref) do
      {:ok, %Mandate{} = mandate} -> [mandate]
      _missing_or_invalid -> []
    end
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
