defmodule Spectre.Domain.Recovery do
  @moduledoc """
  Conservative recovery helpers for a governed Domain.

  Recovery loads the canonical ledger, verifies its complete snapshot, and
  rebuilds a disposable `Spectre.Domain.Projection`. It never mints a Grant or
  releases executor capability.

  An ambiguous append is classified by recomputing the logical batch identity
  and consulting the Store's durable identity index. `:not_committed` means
  only that the identity was absent at that lookup instant; it is not an
  eternal proof that the append can never appear. A sequencer must reload and
  retry the same identity conservatively, and must not emit a Grant from that
  result alone.
  """

  require Spectre.Portable

  alias Spectre.Domain.Projection
  alias Spectre.GovernedAct.Fold
  alias Spectre.GovernedAct.State
  alias Spectre.{Ledger, Portable}
  alias Spectre.Ledger.Entry
  alias Spectre.Ledger.Store.Support

  @type append_classification :: {:committed, Ledger.batch_info()} | :not_committed

  @doc "Loads, verifies, and replays one Domain ledger without producing capabilities."
  @spec recover(Ledger.Store.config(), Ledger.domain_ref(), keyword()) ::
          :not_found | {:ok, Projection.t()} | {:error, term()}
  def recover(store, domain_ref, opts \\ []) do
    recover(store, domain_ref, %{}, opts)
  end

  @doc "Loads and replays a Domain against the exact Constitution pinned by Genesis."
  @spec recover(Ledger.Store.config(), Ledger.domain_ref(), map(), keyword()) ::
          :not_found | {:ok, Projection.t()} | {:error, term()}
  def recover(store, domain_ref, constitution, opts)
      when Portable.is_plain_map(constitution) and is_list(opts) do
    case Ledger.load(store, domain_ref, opts) do
      {:ok, snapshot} -> recover_snapshot(snapshot, domain_ref, constitution)
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Advances a verified prefix only after confirming the exact persisted batch.

  The Store's durable index must match the reconstructed chain, including its
  predecessor and recording time through the head digest. This uses the same
  adapter trust boundary as append/ambiguity recovery; it does not prove that
  the host's storage is tamper-proof. Startup and independent audit still verify
  the full history, rather than trusting this disposable in-memory prefix.

  An unavailable or inconsistent index falls back to a verified ledger read.
  In particular, an identical retry can have a different requested timestamp:
  the original committed timestamp wins and must never be rewritten.
  """
  @spec confirm_append(
          Ledger.Store.config(),
          Projection.t(),
          String.t(),
          [map()],
          non_neg_integer(),
          keyword()
        ) :: {:ok, Projection.t()} | {:error, term()}
  def confirm_append(store, %State{} = prefix, batch_id, payloads, recorded_at, opts) do
    with {:ok, entries} <-
           Entry.build_batch(
             prefix.domain_ref,
             batch_id,
             payloads,
             prefix.revision,
             recorded_at,
             prefix.head_digest
           ),
         {:ok, identity} <-
           Entry.batch_identity(prefix.domain_ref, batch_id, payloads, prefix.revision) do
      expected = Support.batch_info(batch_id, identity, prefix.revision, List.last(entries))

      case Ledger.lookup_batch(store, prefix.domain_ref, batch_id, opts) do
        {:ok, ^expected} -> Fold.append_batch(prefix, entries)
        _unconfirmed -> recover_committed_batch(store, prefix, expected, opts)
      end
    end
  end

  defp recover_committed_batch(store, prefix, expected, opts) do
    with {:ok, snapshot} <- Ledger.load(store, prefix.domain_ref, opts),
         entries = Enum.slice(snapshot.entries, expected.expected_revision, expected.entry_count),
         {:ok, actual} <- Support.derive_batch_info(prefix.domain_ref, entries),
         :ok <- match_predecessor(prefix, entries),
         true <- matching_batch_info?(actual, Map.delete(expected, :head_digest)) do
      recover_snapshot(snapshot, prefix.domain_ref, prefix.constitution)
    else
      :not_found -> {:error, :domain_ledger_disappeared}
      false -> {:error, {:committed_batch_identity_mismatch, expected.batch_id}}
      {:error, _} = error -> error
    end
  end

  defp match_predecessor(prefix, [first | _]) do
    if first.prev_digest == prefix.head_digest,
      do: :ok,
      else: {:error, {:committed_batch_predecessor_mismatch, first.batch_id}}
  end

  @doc """
  Classifies an ambiguous append using its stable batch identity.

  A matching durable lookup returns `{:ok, {:committed, info}}`. An absent
  lookup returns `{:ok, :not_committed}` with the temporal limitation described
  in the module documentation. Any mismatched identity or revision metadata is
  rejected rather than guessed.
  """
  @spec classify_ambiguous(
          Ledger.Store.config(),
          Ledger.domain_ref(),
          Ledger.batch_id(),
          [map()],
          non_neg_integer(),
          keyword()
        ) :: {:ok, append_classification()} | {:error, term()}
  def classify_ambiguous(
        store,
        domain_ref,
        batch_id,
        payloads,
        expected_revision,
        opts \\ []
      ) do
    with {:ok, identity} <-
           Ledger.batch_identity(domain_ref, batch_id, payloads, expected_revision) do
      expected = %{
        batch_id: batch_id,
        identity_digest: identity,
        expected_revision: expected_revision,
        first_revision: expected_revision + 1,
        last_revision: expected_revision + length(payloads),
        entry_count: length(payloads)
      }

      classify_lookup(
        Ledger.lookup_batch(store, domain_ref, batch_id, opts),
        expected
      )
    end
  end

  @spec recover_snapshot(map(), Ledger.domain_ref(), map()) ::
          {:ok, Projection.t()} | {:error, term()}
  defp recover_snapshot(snapshot, domain_ref, constitution) do
    # Ledger.load already verified the chain and its binding to domain_ref.
    # Recovery does not add another complete snapshot-verification pass here.
    with {:ok, projection} <- Fold.replay_verified(domain_ref, snapshot.entries, constitution),
         :ok <- match_snapshot(projection, snapshot) do
      {:ok, projection}
    end
  end

  @spec classify_lookup(
          :not_found | {:ok, Ledger.batch_info()} | {:error, term()},
          map()
        ) :: {:ok, append_classification()} | {:error, term()}
  defp classify_lookup(:not_found, _expected), do: {:ok, :not_committed}

  defp classify_lookup({:ok, info}, expected) do
    if matching_batch_info?(info, expected),
      do: {:ok, {:committed, info}},
      else: {:error, {:ambiguous_batch_identity_mismatch, expected.batch_id}}
  end

  defp classify_lookup({:error, _reason} = error, _expected), do: error

  @spec matching_batch_info?(map(), map()) :: boolean()
  defp matching_batch_info?(info, expected) do
    Enum.all?(expected, fn {key, value} -> Map.get(info, key) == value end) and
      Portable.sha256_digest?(Map.get(info, :head_digest))
  end

  @spec match_snapshot(Projection.t(), Ledger.snapshot()) :: :ok | {:error, term()}
  defp match_snapshot(projection, snapshot) do
    if projection.domain_ref == snapshot.domain_ref and
         projection.revision == snapshot.revision and
         projection.head_digest == snapshot.head_digest,
       do: :ok,
       else: {:error, :domain_recovery_snapshot_mismatch}
  end
end
