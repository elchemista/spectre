defmodule Spectre.Domain.Sequencer.State do
  @moduledoc """
  Private process state for one Domain sequencer.

  Immutable host wiring and the latest disposable governed projection live in
  this container. Queue and timer fields are operational only; none of them is
  ledger truth or authority. Keeping the shape outside the GenServer module
  lets focused command modules operate on an explicit value rather than on the
  Sequencer mailbox itself.
  """

  @enforce_keys [
    :domain_ref,
    :store,
    :projection,
    :clock,
    :id_source,
    :late_observer,
    :mind,
    :mind_ref,
    :ingress,
    :ingress_ref,
    :generation,
    :grant_secret,
    :checkout_receipt_secret,
    :grant_ttl_ms,
    :batch_size,
    :batch_wait_ms,
    :conflict_retries,
    :ambiguous_retries,
    :ledger_opts,
    :payload_store,
    :execution_routes,
    :broker,
    :bootstrap_opts,
    :constitution
  ]

  defstruct @enforce_keys ++
              [
                pending: :queue.new(),
                pending_count: 0,
                flush_token: nil,
                flush_timer: nil,
                reconciliation_token: nil,
                reconciliation_timer: nil,
                halted_reason: nil
              ]

  @type t :: %__MODULE__{}
end
