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

  alias Spectre.{Ledger, Portable}
  alias Spectre.Domain.Projection

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
      when is_map(constitution) and not is_struct(constitution) and is_list(opts) do
    case Ledger.load(store, domain_ref, opts) do
      {:ok, snapshot} -> recover_snapshot(snapshot, domain_ref, constitution)
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
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
    with {:ok, verified} <- Ledger.verify_snapshot(snapshot, domain_ref),
         {:ok, projection} <- Projection.replay(verified, constitution),
         :ok <- match_snapshot(projection, verified) do
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
    is_map(info) and
      Enum.all?(Map.keys(expected), fn key -> Map.get(info, key) == Map.fetch!(expected, key) end) and
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
