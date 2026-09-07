defmodule Spectre.GovernedAct.Index do
  @moduledoc """
  Shared access rules for collections in disposable governed state.

  Transition modules use these functions so missing-record and duplicate-record
  errors remain stable as the fold is split by concern. This is not a general
  repository abstraction: it only reads and updates the in-memory projection
  rebuilt from the ledger.
  """

  alias Spectre.Canonical.Record
  alias Spectre.GovernedAct.State

  @doc "Fetches an Act using the common governed-history error vocabulary."
  @spec fetch_act(State.t(), String.t()) :: {:ok, Spectre.Act.t()} | {:error, term()}
  def fetch_act(%State{} = state, ref), do: fetch(state.acts, ref, :act)

  @doc "Fetches a Mandate using the common governed-history error vocabulary."
  @spec fetch_mandate(State.t(), String.t()) :: {:ok, Spectre.Mandate.t()} | {:error, term()}
  def fetch_mandate(%State{} = state, ref), do: fetch(state.mandates, ref, :mandate)

  @doc "Fetches an Attempt using the common governed-history error vocabulary."
  @spec fetch_attempt(State.t(), String.t()) :: {:ok, Spectre.Attempt.t()} | {:error, term()}
  def fetch_attempt(%State{} = state, ref), do: fetch(state.attempts, ref, :attempt)

  @doc "Fetches a Decision using the common governed-history error vocabulary."
  @spec fetch_decision(State.t(), String.t()) :: {:ok, Spectre.Decision.t()} | {:error, term()}
  def fetch_decision(%State{} = state, ref), do: fetch(state.decisions, ref, :decision)

  @doc "Fetches a Duty by its stable causal identity."
  @spec fetch_duty_by_cause(State.t(), term()) ::
          {:ok, Spectre.Duty.t()} | {:error, term()}
  def fetch_duty_by_cause(%State{} = state, cause_key) when not is_nil(cause_key) do
    case Map.fetch(state.duties, cause_key) do
      {:ok, duty} -> {:ok, duty}
      :error -> {:error, {:duty_not_found, cause_key}}
    end
  end

  def fetch_duty_by_cause(%State{}, cause_key),
    do: {:error, {:invalid_duty_cause_key, cause_key}}

  @doc "Fetches a Duty by its durable record reference."
  @spec fetch_duty_by_ref(State.t(), term()) :: {:ok, Spectre.Duty.t()} | {:error, term()}
  def fetch_duty_by_ref(%State{} = state, duty_ref)
      when is_binary(duty_ref) and duty_ref != "" do
    with {:ok, cause_key} <- Map.fetch(state.read_index.duties.by_ref, duty_ref),
         {:ok, duty} <- Map.fetch(state.duties, cause_key) do
      {:ok, duty}
    else
      :error -> {:error, {:duty_not_found, duty_ref}}
    end
  end

  def fetch_duty_by_ref(%State{}, duty_ref), do: {:error, {:invalid_duty_ref, duty_ref}}

  @doc "Fetches a required value while preserving the caller's record kind."
  @spec fetch_required(map(), term(), atom()) :: {:ok, term()} | {:error, term()}
  def fetch_required(collection, key, kind) when is_map(collection) and is_atom(kind) do
    case Map.fetch(collection, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {kind, :not_found, key}}
    end
  end

  @doc "Rejects a duplicate identity in a governed-state collection."
  @spec unique(map(), term(), atom()) :: :ok | {:error, term()}
  def unique(collection, identity, kind) when is_map(collection) and is_atom(kind) do
    if Map.has_key?(collection, identity),
      do: {:error, {:duplicate_domain_record, kind, identity}},
      else: :ok
  end

  @doc "Requires every reference to exist in a collection, preserving caller error context."
  @spec ensure_present(map(), [String.t()], atom()) :: :ok | {:error, term()}
  def ensure_present(collection, refs, missing_error)
      when is_map(collection) and is_list(refs) and is_atom(missing_error) do
    case Enum.find(refs, &(not Map.has_key?(collection, &1))) do
      nil -> :ok
      ref -> {:error, {missing_error, ref}}
    end
  end

  @doc "Restores one canonical record and rejects identity reuse in its target index."
  @spec restore_unique(map(), module(), String.t(), term(), atom()) ::
          {:ok, struct()} | {:error, term()}
  def restore_unique(collection, module, identity, canonical, kind)
      when is_map(collection) and is_atom(module) and is_binary(identity) and is_atom(kind) do
    with {:ok, record} <- Record.decode(module, canonical),
         :ok <- Record.match_identity(identity, record),
         :ok <- unique(collection, identity, kind) do
      {:ok, record}
    end
  end

  defp fetch(collection, ref, kind) do
    case Map.fetch(collection, ref) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, {missing_error(kind), ref}}
    end
  end

  defp missing_error(:act), do: :act_not_found
  defp missing_error(:mandate), do: :mandate_not_found
  defp missing_error(:attempt), do: :attempt_not_found
  defp missing_error(:decision), do: :decision_not_found
end
