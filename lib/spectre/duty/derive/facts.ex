defmodule Spectre.Duty.Derive.Facts do
  @moduledoc """
  Read-only input prepared for pure Duty derivation.

  Governed records stay as their decoded structs. Ledger position and
  acquisition time stay in `Spectre.Domain.Event.Metadata`, where replay put
  them. This avoids manufacturing a second, map-shaped representation of an
  Act, Evidence or Outcome merely to attach metadata.

  Each governed collection keeps the projection's single keyed representation;
  derivation traverses those maps directly instead of allocating parallel lists
  or retaining derived indexes beside their source. This view is disposable and
  carries no authority: the append-only ledger remains the source of truth and
  `Spectre.GovernedAct.State` remains the complete replay projection.
  """

  alias Spectre.Domain.Event
  alias Spectre.Erasure.Analysis.Facts, as: ErasureFacts
  alias Spectre.GovernedAct.State

  @enforce_keys [
    :acts,
    :attempts,
    :duties,
    :erasures,
    :evidence,
    :event_metadata,
    :mandates,
    :outcomes,
    :presentations,
    :scopes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          acts: %{optional(String.t()) => Spectre.Act.t()},
          attempts: %{optional(String.t()) => Spectre.Attempt.t()},
          duties: %{optional(term()) => Spectre.Duty.t()},
          erasures: %{optional(String.t()) => Spectre.Erasure.t()},
          evidence: %{optional(String.t()) => Spectre.Evidence.t()},
          event_metadata: %{optional(String.t()) => Event.Metadata.t()},
          mandates: %{optional(String.t()) => Spectre.Mandate.t()},
          outcomes: %{optional(String.t()) => Spectre.Outcome.t()},
          presentations: %{optional(String.t()) => Spectre.Presentation.t()},
          scopes: %{optional(String.t()) => Spectre.Scope.Opening.t()}
        }

  @doc "Builds the minimal indexed view used by the Duty algebra."
  @spec from_state(State.t()) :: t()
  def from_state(%State{} = state) do
    %__MODULE__{
      acts: state.acts,
      attempts: state.attempts,
      duties: state.duties,
      erasures: state.erasures,
      evidence: state.evidence,
      event_metadata: state.event_metadata,
      mandates: state.mandates,
      outcomes: state.outcomes,
      presentations: state.presentations,
      scopes: state.scopes
    }
  end

  @doc "Looks up trusted ledger metadata for a typed record identity."
  @spec metadata(t(), String.t()) ::
          {:ok, Event.Metadata.t()} | {:error, :missing_event_metadata}
  def metadata(%__MODULE__{} = facts, ref) when is_binary(ref) do
    case Map.fetch(facts.event_metadata, ref) do
      {:ok, %Event.Metadata{} = metadata} -> {:ok, metadata}
      _missing -> {:error, :missing_event_metadata}
    end
  end

  def metadata(%__MODULE__{}, _ref), do: {:error, :missing_event_metadata}

  @doc "Returns whether a fact was durably known at the given ledger revision."
  @spec recorded_through?(t(), String.t(), non_neg_integer()) :: boolean()
  def recorded_through?(%__MODULE__{} = facts, ref, revision) do
    case metadata(facts, ref) do
      {:ok, metadata} -> metadata.revision <= revision
      {:error, :missing_event_metadata} -> false
    end
  end

  @doc "Filters typed records to the ledger prefix ending at `revision`."
  @spec records_through(t(), Enumerable.t(), non_neg_integer()) :: [struct()]
  def records_through(%__MODULE__{} = facts, records, revision)
      when is_integer(revision) and revision >= 0 do
    records
    |> Enum.reduce([], fn
      {_key, record}, found -> maybe_record_through(record, facts, revision, found)
      record, found -> maybe_record_through(record, facts, revision, found)
    end)
    |> Enum.reverse()
  end

  @doc "Returns Evidence durably known in the ledger prefix ending at `revision`."
  @spec evidence_through(t(), non_neg_integer()) :: [Spectre.Evidence.t()]
  def evidence_through(%__MODULE__{} = facts, revision),
    do: records_through(facts, facts.evidence, revision)

  @doc "Returns metadata when Evidence was recorded after a revision and no later than `time`."
  @spec later_evidence(t(), Spectre.Evidence.t(), non_neg_integer(), integer()) ::
          {:ok, Event.Metadata.t()} | :error
  def later_evidence(%__MODULE__{} = facts, %Spectre.Evidence{} = evidence, revision, time)
      when is_integer(revision) and revision >= 0 and is_integer(time) do
    with {:ok, metadata} <- metadata(facts, evidence.ref),
         true <- metadata.revision > revision and metadata.recorded_at <= time do
      {:ok, metadata}
    else
      _not_later -> :error
    end
  end

  @doc "Returns Evidence durably present and not erased at trusted `time`."
  @spec available_evidence(t(), integer()) :: [Spectre.Evidence.t()]
  def available_evidence(%__MODULE__{} = facts, time) when is_integer(time) do
    unavailable = unavailable_evidence_at(facts, time)

    facts.evidence
    |> records_available_at(facts, time)
    |> Enum.reject(&MapSet.member?(unavailable, &1.ref))
  end

  @doc "Returns whether a fact was durably available at the given trusted time."
  @spec available_at?(t(), String.t(), integer()) :: boolean()
  def available_at?(%__MODULE__{} = facts, ref, time) when is_integer(time) do
    case metadata(facts, ref) do
      {:ok, metadata} -> metadata.recorded_at <= time
      {:error, :missing_event_metadata} -> false
    end
  end

  defp unavailable_evidence_at(facts, time) do
    prefix = %ErasureFacts{
      evidence: facts.evidence |> records_available_at(facts, time) |> index_by_ref(),
      presentations: facts.presentations |> records_available_at(facts, time) |> index_by_ref(),
      acts: facts.acts |> records_available_at(facts, time) |> index_by_ref(),
      attempts: facts.attempts |> records_available_at(facts, time) |> index_by_ref(),
      outcomes: facts.outcomes |> records_available_at(facts, time) |> index_by_ref(),
      duties: facts.duties |> records_available_at(facts, time) |> index_by_ref(),
      erasures: facts.erasures |> records_available_at(facts, time) |> index_by_ref()
    }

    Spectre.Erasure.Analysis.unavailable_evidence_refs(prefix)
  end

  defp records_available_at(records, facts, time) do
    records
    |> Enum.reduce([], fn
      {_key, record}, found -> maybe_record_available(record, facts, time, found)
      record, found -> maybe_record_available(record, facts, time, found)
    end)
    |> Enum.reverse()
  end

  defp maybe_record_through(record, facts, revision, found) do
    if recorded_through?(facts, record.ref, revision), do: [record | found], else: found
  end

  defp maybe_record_available(record, facts, time, found) do
    if available_at?(facts, record.ref, time), do: [record | found], else: found
  end

  defp index_by_ref(records), do: Map.new(records, &{&1.ref, &1})
end
