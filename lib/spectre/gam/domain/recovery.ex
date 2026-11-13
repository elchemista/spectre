defmodule Spectre.GAM.Domain.Recovery do
  @moduledoc """
  Conservative recovery helpers for a governed Domain.

  Recovery loads the canonical ledger, verifies its complete snapshot, and
  rebuilds a disposable `Spectre.GAM.Domain.Projection`. It never mints a Grant or
  releases executor capability.

  An ambiguous append is classified by recomputing the logical batch identity
  and consulting the Store's durable identity index. `:not_committed` means
  only that the identity was absent at that lookup instant; it is not an
  eternal proof that the append can never appear. A sequencer must reload and
  retry the same identity conservatively, and must not emit a Grant from that
  result alone.
  """

  require Spectre.GAM.Portable

  alias Spectre.GAM.Domain.Projection
  alias Spectre.GAM.GovernedAct.{Commit, Fold}
  alias Spectre.GAM.GovernedAct.State
  alias Spectre.GAM.{Ledger, Portable}
  alias Spectre.GAM.Ledger.Store.Support
  alias Spectre.GAM.Payload.Store, as: PayloadStore

  @type append_classification :: {:committed, Ledger.batch_info()} | :not_committed
  @type payload_check :: (Projection.t(), [String.t()] -> :ok | {:error, term()}) | nil

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
    if Ledger.Store.batch_reads?(store) do
      with :ok <- Spectre.GAM.Constitution.validate(constitution),
           initial = Fold.new(domain_ref, constitution),
           {:ok, projection} <- recover_batches(store, initial, opts),
           :ok <- Fold.validate_complete(projection) do
        {:ok, projection}
      end
    else
      case Ledger.load(store, domain_ref, opts) do
        {:ok, snapshot} -> recover_snapshot(snapshot, domain_ref, constitution)
        :not_found -> :not_found
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Resumes an in-memory verified prefix using only the newly committed batches.

  A changed predecessor or a head behind the cursor is an error, never a reason
  to silently replace the trusted prefix. Cold startup still uses `recover/4`.

  An optional payload check receives the final verified projection and the
  distinct payload references introduced or affected by the recovered suffix. It cannot
  replace the projection. Checking at the final head matters when that suffix
  also contains a legitimate erasure of one of those payloads.
  """
  @spec resume(Ledger.Store.config(), Projection.t(), keyword(), payload_check()) ::
          :not_found | {:ok, Projection.t()} | {:error, term()}
  def resume(store, %State{} = prefix, opts \\ [], check \\ nil) do
    if Ledger.Store.batch_reads?(store) do
      recover_batches(store, prefix, opts, check)
    else
      with {:ok, suffix} <- Ledger.load_from(store, prefix.domain_ref, cursor(prefix), opts) do
        recover_suffix(prefix, suffix, check)
      end
    end
  end

  defp recover_batches(store, prefix, opts, check \\ nil) do
    with {:ok, {projection, refs}} <-
           Ledger.Reader.reduce(
             store,
             prefix.domain_ref,
             cursor(prefix),
             {prefix, initial_refs(check)},
             &fold_delta/2,
             opts
           ) do
      check_recovered(projection, refs, check)
    end
  end

  defp recover_suffix(prefix, suffix, check) do
    suffix.entries
    |> Stream.chunk_by(& &1.batch_id)
    |> Enum.reduce_while({:ok, {prefix, initial_refs(check)}}, fn batch, {:ok, current} ->
      case fold_delta(batch, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, {projection, refs}} ->
        with :ok <- match_snapshot(projection, suffix),
             do: check_recovered(projection, refs, check)

      {:error, _} = error ->
        error
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
          keyword(),
          payload_check()
        ) :: {:ok, Projection.t()} | {:error, term()}
  def confirm_append(
        store,
        %State{} = prefix,
        batch_id,
        payloads,
        recorded_at,
        opts,
        check \\ nil
      ) do
    with {:ok, prepared} <- Commit.prepare(prefix, batch_id, payloads, recorded_at),
         do: confirm_prepared(store, prefix, prepared, opts, check)
  end

  @doc false
  @spec confirm_prepared(
          Ledger.Store.config(),
          Projection.t(),
          Commit.t(),
          keyword(),
          payload_check()
        ) ::
          {:ok, Projection.t()} | {:error, term()}
  def confirm_prepared(store, %State{} = prefix, %Commit{} = prepared, opts, check \\ nil) do
    # The prepared value is local to this command, never loaded from storage.
    # Its exact predecessor must still be the caller's verified prefix.
    if prepared.prefix === cursor(prefix) and prepared.state.domain_ref === prefix.domain_ref do
      confirm_prepared_at_prefix(store, prefix, prepared, opts, check)
    else
      {:error, :prepared_commit_prefix_mismatch}
    end
  end

  defp confirm_prepared_at_prefix(store, prefix, prepared, opts, check) do
    case Ledger.lookup_batch(store, prefix.domain_ref, prepared.receipt.batch_id, opts) do
      {:ok, receipt} when receipt === prepared.receipt ->
        check_prepared(prepared, check)

      _unconfirmed ->
        recover_committed_batch(store, prefix, prepared.receipt, opts, check)
    end
  end

  defp check_prepared(prepared, nil), do: {:ok, prepared.state}

  defp check_prepared(prepared, check) do
    refs = PayloadStore.recovered_refs(prepared.state, prepared.payloads)
    with :ok <- check.(prepared.state, refs), do: {:ok, prepared.state}
  end

  defp recover_committed_batch(store, prefix, expected, opts, check) do
    if Ledger.Store.batch_reads?(store) do
      with {:ok, snapshot} <-
             Ledger.Store.read_batch(store, prefix.domain_ref, prefix.revision + 1, opts),
           {:ok, snapshot} <- Ledger.verify_suffix(snapshot, prefix.domain_ref, cursor(prefix)),
           {:ok, actual} <- Support.derive_batch_info(prefix.domain_ref, snapshot.entries),
           :ok <- match_predecessor(prefix, snapshot.entries),
           true <- matching_batch_info?(actual, Map.delete(expected, :head_digest)) do
        resume(store, prefix, opts, check)
      else
        :not_found -> {:error, :domain_ledger_disappeared}
        false -> {:error, {:committed_batch_identity_mismatch, expected.batch_id}}
        {:error, _} = error -> error
      end
    else
      recover_committed_suffix(store, prefix, expected, opts, check)
    end
  end

  defp recover_committed_suffix(store, prefix, expected, opts, check) do
    with {:ok, snapshot} <- Ledger.load_from(store, prefix.domain_ref, cursor(prefix), opts),
         entries = Enum.take(snapshot.entries, expected.entry_count),
         {:ok, actual} <- Support.derive_batch_info(prefix.domain_ref, entries),
         :ok <- match_predecessor(prefix, entries),
         true <- matching_batch_info?(actual, Map.delete(expected, :head_digest)) do
      recover_suffix(prefix, snapshot, check)
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

  defp cursor(prefix), do: %{revision: prefix.revision, head_digest: prefix.head_digest}

  defp fold_delta(entries, {prefix, refs}) do
    with {:ok, projection} <- Fold.append_batch(prefix, entries) do
      {:ok, {projection, collect_refs(refs, projection, entries)}}
    end
  end

  defp initial_refs(nil), do: nil
  defp initial_refs(_check), do: MapSet.new()
  defp collect_refs(nil, _projection, _entries), do: nil

  defp collect_refs(refs, projection, entries) do
    introduced = PayloadStore.recovered_refs(projection, Enum.map(entries, & &1.payload))
    Enum.reduce(introduced, refs, &MapSet.put(&2, &1))
  end

  defp check_recovered(projection, _refs, nil), do: {:ok, projection}

  defp check_recovered(projection, refs, check) do
    with :ok <- check.(projection, Enum.sort(refs)), do: {:ok, projection}
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
    Enum.all?(expected, fn {key, value} -> Map.get(info, key) === value end) and
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
