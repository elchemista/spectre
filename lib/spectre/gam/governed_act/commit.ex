defmodule Spectre.GAM.GovernedAct.Commit do
  @moduledoc """
  One prepared governed transaction, before its durability acknowledgement.

  The existing pure fold validates the exact canonical records once, including
  their real batch identity, acquisition time and predecessor. `state` is the
  proposed result, not committed authority. A persistence driver may publish it
  only after confirming `receipt` exactly; uncertainty must recover the actual
  committed records instead. No capability is created by preparation.

  This separates the semantic transaction from its physical storage. A ledger
  driver persists `payloads`; a state-oriented driver can additionally publish
  the resulting current facts in the same storage transaction. Neither driver
  gets to reimplement the governed transitions or change the accepted records.
  The current representation still contains a full State: this is not a bounded
  read-model implementation or a persisted checkpoint format.
  """

  alias Spectre.GAM.GovernedAct.{Fold, State}
  alias Spectre.GAM.Ledger.Entry
  alias Spectre.GAM.Ledger.Store.Support

  @enforce_keys [:prefix, :payloads, :recorded_at, :receipt, :state]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          prefix: Spectre.GAM.Ledger.cursor(),
          payloads: [map()],
          recorded_at: non_neg_integer(),
          receipt: Spectre.GAM.Ledger.batch_info(),
          state: State.t()
        }

  @doc """
  Folds an exact proposed batch and builds its expected durability receipt.

  Entries use the real predecessor and batch coordinates so confirmation can
  reuse the checked State without another semantic fold. Neither the entries
  nor `state` prove persistence: the storage driver must match the receipt or
  recover the actual durable prefix before adopting this result.
  """
  @spec prepare(State.t(), String.t(), [map()], non_neg_integer()) ::
          {:ok, t()} | {:error, term()}
  def prepare(%State{} = prefix, id, payloads, recorded_at) do
    with {:ok, entries} <-
           Entry.build_batch(
             prefix.domain_ref,
             id,
             payloads,
             prefix.revision,
             recorded_at,
             prefix.head_digest
           ),
         {:ok, state} <- Fold.append_batch(prefix, entries),
         {:ok, identity} <- Entry.batch_identity(prefix.domain_ref, id, payloads, prefix.revision) do
      {:ok,
       %__MODULE__{
         prefix: Map.take(prefix, [:revision, :head_digest]),
         payloads: payloads,
         recorded_at: recorded_at,
         receipt: Support.batch_info(id, identity, prefix.revision, List.last(entries)),
         state: state
       }}
    end
  end

  @doc "Checks an exact durable acknowledgement; numeric coercion is never allowed."
  @spec confirmed?(t(), term()) :: boolean()
  def confirmed?(%__MODULE__{receipt: expected}, actual), do: expected === actual
end
