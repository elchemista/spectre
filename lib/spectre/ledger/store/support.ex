defmodule Spectre.Ledger.Store.Support do
  @moduledoc """
  Storage-neutral helpers for ledger adapters.

  This module owns only portable result shapes and common call-option parsing.
  Locking, transactions, durability barriers, encoding and recovery remain in
  each adapter, where their guarantees can be audited without indirection.
  """

  alias Spectre.Ledger
  alias Spectre.Ledger.Entry

  @digest_pattern ~r/\A[0-9a-f]{64}\z/
  @max_identifier_bytes 1_024

  @doc "Builds metadata for entries just committed as one logical batch."
  @spec batch_info(String.t(), Entry.digest(), non_neg_integer(), [Entry.t()], Entry.t()) ::
          Ledger.batch_info()
  def batch_info(batch_id, identity, expected_revision, entries, %Entry{} = last) do
    batch_info(
      batch_id,
      identity,
      expected_revision,
      expected_revision + 1,
      last.revision,
      length(entries),
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
  def valid_identifier?(value),
    do: is_binary(value) and value != "" and byte_size(value) <= @max_identifier_bytes

  @doc false
  @spec valid_digest?(term()) :: boolean()
  def valid_digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: Regex.match?(@digest_pattern, value)

  def valid_digest?(_value), do: false
end
