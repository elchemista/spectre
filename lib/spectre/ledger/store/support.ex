defmodule Spectre.Ledger.Store.Support do
  @moduledoc """
  Storage-neutral helpers for ledger adapters.

  This module owns portable result shapes and storage-neutral batch checks.
  Locking, transactions, durability barriers, encoding and recovery remain in
  each adapter, where their guarantees can be audited without indirection.
  """

  alias Spectre.{Ledger, Portable}
  alias Spectre.Ledger.Entry

  @doc "Builds metadata for an already verified non-empty logical batch."
  @spec batch_info(String.t(), Entry.digest(), non_neg_integer(), Entry.t()) ::
          Ledger.batch_info()
  def batch_info(batch_id, identity, expected_revision, %Entry{} = last) do
    batch_info(
      batch_id,
      identity,
      expected_revision,
      expected_revision + 1,
      last.revision,
      last.revision - expected_revision,
      last.digest
    )
  end

  @doc "Builds batch metadata from already decoded storage columns."
  @spec batch_info(
          String.t(),
          Entry.digest(),
          non_neg_integer(),
          integer(),
          integer(),
          integer(),
          Entry.digest()
        ) :: Ledger.batch_info()
  def batch_info(batch_id, identity, expected, first, last, count, head) do
    %{
      batch_id: batch_id,
      identity_digest: identity,
      expected_revision: expected,
      first_revision: first,
      last_revision: last,
      entry_count: count,
      head_digest: head
    }
  end

  @doc false
  @spec derive_batch_info(String.t(), [Entry.t()]) ::
          {:ok, Ledger.batch_info()} | {:error, term()}
  def derive_batch_info(domain_ref, [%Entry{revision: revision} = first | _rest] = entries)
      when is_binary(domain_ref) and is_integer(revision) and revision > 0 do
    expected_revision = revision - 1

    with {:ok, verified} <-
           Entry.verify_chain(entries,
             domain_ref: domain_ref,
             start_revision: expected_revision,
             prev_digest: first.prev_digest
           ),
         :ok <- validate_batch_coordinates(verified.entries, domain_ref, first.batch_id),
         {:ok, identity} <-
           Entry.batch_identity(
             domain_ref,
             first.batch_id,
             Enum.map(verified.entries, & &1.payload),
             expected_revision
           ) do
      {:ok, batch_info(first.batch_id, identity, expected_revision, List.last(verified.entries))}
    end
  end

  def derive_batch_info(_domain_ref, []), do: {:error, :empty_ledger_batch}
  def derive_batch_info(_domain_ref, _entries), do: {:error, :invalid_ledger_batch_entries}

  @doc false
  @spec validate_batch_coordinates([Entry.t()], String.t(), String.t()) ::
          :ok | {:error, :ledger_batch_coordinates_mismatch}
  def validate_batch_coordinates(
        [%Entry{recorded_at: recorded_at} | _rest] = entries,
        domain_ref,
        batch_id
      ) do
    size = length(entries)

    entries
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn
      {%Entry{} = entry, index}, :ok ->
        if entry.domain_ref == domain_ref and entry.batch_id == batch_id and
             entry.batch_index == index and entry.batch_size == size and
             entry.recorded_at == recorded_at,
           do: {:cont, :ok},
           else: {:halt, {:error, :ledger_batch_coordinates_mismatch}}

      {_invalid, _index}, :ok ->
        {:halt, {:error, :ledger_batch_coordinates_mismatch}}
    end)
  end

  def validate_batch_coordinates(_entries, _domain_ref, _batch_id),
    do: {:error, :ledger_batch_coordinates_mismatch}

  @doc false
  @spec validate_batch_info(Ledger.batch_info(), String.t() | nil) ::
          :ok | {:error, :batch_id | :identity | :revision | :range | :count | :head}
  def validate_batch_info(info, expected_batch_id \\ nil) when is_map(info) do
    cond do
      not is_nil(expected_batch_id) and info.batch_id != expected_batch_id ->
        {:error, :batch_id}

      not valid_identifier?(info.batch_id) ->
        {:error, :batch_id}

      not valid_digest?(info.identity_digest) ->
        {:error, :identity}

      not is_integer(info.expected_revision) or info.expected_revision < 0 ->
        {:error, :revision}

      info.first_revision != info.expected_revision + 1 ->
        {:error, :range}

      not is_integer(info.last_revision) or info.last_revision < info.first_revision ->
        {:error, :range}

      not is_integer(info.entry_count) or info.entry_count <= 0 or
        info.entry_count > Entry.max_batch_entries() or
          info.entry_count != info.last_revision - info.first_revision + 1 ->
        {:error, :count}

      not valid_digest?(info.head_digest) ->
        {:error, :head}

      true ->
        :ok
    end
  end

  @doc "Returns the initial in-memory state shared by serialized adapters."
  @spec empty_domain() :: map()
  def empty_domain do
    %{
      revision: 0,
      head_digest: Entry.genesis_digest(),
      entries_rev: [],
      batches: %{},
      recovery: nil
    }
  end

  @doc "Classifies a prospective append against a serialized adapter's cached Domain."
  @spec append_status(map(), String.t(), Entry.digest(), non_neg_integer(), atom() | nil) ::
          :new | {:existing, non_neg_integer()} | {:error, term()}
  def append_status(domain, batch_id, identity, expected_revision, fault) do
    case Map.fetch(domain.batches, batch_id) do
      {:ok, %{identity_digest: ^identity, expected_revision: ^expected_revision} = info} ->
        {:existing, info.last_revision}

      {:ok, _different} ->
        {:error, {:batch_identity_conflict, batch_id}}

      :error when expected_revision != domain.revision ->
        {:error, :conflict}

      :error when fault == :before_commit ->
        {:error, :ambiguous}

      :error ->
        :new
    end
  end

  @doc "Installs an already verified batch in a serialized adapter's cached Domain."
  @spec install_batch(map(), String.t(), Entry.digest(), non_neg_integer(), [Entry.t()]) ::
          {map(), Entry.t()}
  def install_batch(domain, batch_id, identity, expected_revision, entries)
      when is_list(entries) and entries != [] do
    {entries_rev, last} = prepend_reversed(entries, domain.entries_rev)
    info = batch_info(batch_id, identity, expected_revision, last)

    committed = %{
      domain
      | revision: last.revision,
        head_digest: last.digest,
        entries_rev: entries_rev,
        batches: Map.put(domain.batches, batch_id, info)
    }

    {committed, last}
  end

  @doc "Builds the portable snapshot returned by a serialized adapter."
  @spec snapshot(String.t(), map()) :: Ledger.snapshot()
  def snapshot(domain_ref, domain) do
    %{
      domain_ref: domain_ref,
      revision: domain.revision,
      head_digest: domain.head_digest,
      entries: Enum.reverse(domain.entries_rev),
      recovery: domain.recovery
    }
  end

  @doc false
  @spec fault_phase(keyword()) ::
          {:ok, nil | :before_commit | :after_commit} | {:error, term()}
  def fault_phase(opts) when is_list(opts) do
    value = Keyword.get(opts, :fault_injection, Keyword.get(opts, :fault))

    if value in [nil, :before_commit, :after_commit],
      do: {:ok, value},
      else: {:error, {:invalid_ledger_fault_injection, value}}
  end

  @doc false
  @spec recorded_at(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def recorded_at(opts) when is_list(opts) do
    case Keyword.fetch(opts, :recorded_at) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _missing_or_invalid -> {:error, :ledger_recorded_at_required}
    end
  end

  @doc false
  @spec validate_options(keyword(), [atom()], atom(), atom()) :: :ok | {:error, term()}
  def validate_options(opts, allowed, invalid_error, unknown_error)
      when is_list(opts) and is_list(allowed) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- allowed do
        [] -> :ok
        unknown -> {:error, {unknown_error, unknown |> Enum.uniq() |> Enum.sort()}}
      end
    else
      {:error, invalid_error}
    end
  end

  def validate_options(_opts, _allowed, invalid_error, _unknown_error),
    do: {:error, invalid_error}

  @doc false
  @spec valid_identifier?(term()) :: boolean()
  defdelegate valid_identifier?(value), to: Entry

  @doc false
  @spec valid_digest?(term()) :: boolean()
  defdelegate valid_digest?(value), to: Portable, as: :sha256_digest?

  defp prepend_reversed([first | rest], tail),
    do: prepend_reversed(rest, [first | tail], first)

  defp prepend_reversed([entry | rest], reversed, _last),
    do: prepend_reversed(rest, [entry | reversed], entry)

  defp prepend_reversed([], reversed, last), do: {reversed, last}
end
