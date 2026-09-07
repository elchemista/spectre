defmodule Spectre.GovernedAct.DispatchState do
  @moduledoc """
  Compact lifecycle index for executor-mediated Acts.

  Pending dispatches remain a `MapSet` because expiry, authority changes and
  reconciliation scan that small hot set repeatedly. Terminal dispatches share
  one mutually-exclusive index: an Act either consumed one Attempt or was
  cancelled. The durable Attempt and cancellation event remain in the ledger;
  this module only reads and updates their disposable projection indexes.
  """

  alias Spectre.{Act, Mandate}
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.{ReadIndex, State}

  @type cancellation :: %{
          required(:cause_ref) => String.t(),
          required(:reason) =>
            :mandate_revoked | :mandate_restricted | :mandate_expired | :disputed_evidence,
          required(:cancelled_at) => non_neg_integer()
        }

  @type terminal :: {:attempt, String.t()} | {:cancelled, cancellation()}

  @doc "Returns the hot set of Acts still eligible to consume a Grant."
  @spec pending_refs(State.t()) :: MapSet.t(String.t())
  def pending_refs(%State{pending_dispatches: refs}), do: refs

  @doc "Returns whether an Act is waiting at the executor boundary."
  @spec pending?(State.t(), String.t()) :: boolean()
  def pending?(%State{pending_dispatches: refs}, act_ref), do: MapSet.member?(refs, act_ref)

  @doc "Returns the terminal dispatch state for an Act, if one exists."
  @spec terminal(State.t(), String.t()) :: terminal() | nil
  def terminal(%State{terminal_dispatches: terminals}, act_ref), do: Map.get(terminals, act_ref)

  @doc "Returns the Attempt bound to an Act, or `nil` before/without execution."
  @spec attempt_ref(State.t(), String.t()) :: String.t() | nil
  def attempt_ref(%State{terminal_dispatches: terminals}, act_ref) do
    case Map.get(terminals, act_ref) do
      {:attempt, attempt_ref} -> attempt_ref
      _pending_cancelled_or_missing -> nil
    end
  end

  @doc "Returns the cancellation bound to an Act, or `nil` when not cancelled."
  @spec cancellation(State.t(), String.t()) :: cancellation() | nil
  def cancellation(%State{terminal_dispatches: terminals}, act_ref) do
    case Map.get(terminals, act_ref) do
      {:cancelled, cancellation} -> cancellation
      _pending_attempted_or_missing -> nil
    end
  end

  @doc "Returns whether an Act has consumed an Attempt."
  @spec attempted?(State.t(), String.t()) :: boolean()
  def attempted?(%State{} = state, act_ref), do: not is_nil(attempt_ref(state, act_ref))

  @doc "Returns whether an Act's dispatch was cancelled."
  @spec cancelled?(State.t(), String.t()) :: boolean()
  def cancelled?(%State{} = state, act_ref), do: not is_nil(cancellation(state, act_ref))

  @doc "Returns pending executor Acts whose pinned Mandate has expired."
  @spec expired(State.t(), integer()) ::
          {:ok, [{Act.t(), Mandate.t()}]} | {:error, term()}
  def expired(%State{} = state, time) when is_integer(time) do
    refs =
      if ReadIndex.dispatch_indexed?(state),
        do: ReadIndex.expired_dispatch_refs(state, time),
        else: state |> pending_refs() |> Enum.sort()

    with {:ok, pending} <- pending_records(state, refs) do
      {:ok, Enum.filter(pending, fn {_act, mandate} -> mandate.expires_at <= time end)}
    end
  end

  @doc "Returns the validated Act and pinned Mandate behind each pending dispatch."
  @spec pending(State.t()) :: {:ok, [{Act.t(), Mandate.t()}]} | {:error, term()}
  def pending(%State{} = state) do
    pending_records(state, state |> pending_refs() |> Enum.sort())
  end

  defp pending_records(state, refs) do
    Enum.reduce_while(refs, {:ok, []}, fn act_ref, {:ok, records} ->
      with {:ok, act} <- fetch_pending_act(state, act_ref),
           {:ok, mandate} <- fetch_pending_mandate(state, act),
           :ok <- valid_pending_pair(state, act, mandate) do
        {:cont, {:ok, [{act, mandate} | records]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  @doc false
  @spec mark_pending(State.t(), String.t()) :: State.t()
  def mark_pending(%State{} = state, act_ref) do
    %{state | pending_dispatches: MapSet.put(state.pending_dispatches, act_ref)}
  end

  @doc false
  @spec mark_attempted(State.t(), String.t(), String.t()) :: State.t()
  def mark_attempted(%State{} = state, act_ref, attempt_ref) do
    %{
      state
      | pending_dispatches: MapSet.delete(state.pending_dispatches, act_ref),
        terminal_dispatches: Map.put(state.terminal_dispatches, act_ref, {:attempt, attempt_ref})
    }
  end

  @doc false
  @spec mark_cancelled(State.t(), String.t(), cancellation()) :: State.t()
  def mark_cancelled(%State{} = state, act_ref, cancellation) do
    %{
      state
      | pending_dispatches: MapSet.delete(state.pending_dispatches, act_ref),
        terminal_dispatches:
          Map.put(state.terminal_dispatches, act_ref, {:cancelled, cancellation})
    }
  end

  @doc "Returns terminal cancellation entries without materializing another index."
  @spec cancellations(State.t()) :: Enumerable.t()
  def cancellations(%State{terminal_dispatches: terminals}) do
    Stream.flat_map(terminals, fn
      {act_ref, {:cancelled, cancellation}} -> [{act_ref, cancellation}]
      {_act_ref, {:attempt, _attempt_ref}} -> []
    end)
  end

  defp fetch_pending_act(state, act_ref) do
    case Map.fetch(state.acts, act_ref) do
      {:ok, %Act{} = act} -> {:ok, act}
      {:ok, _invalid} -> {:error, {:invalid_pending_dispatch_act, act_ref}}
      :error -> {:error, {:pending_dispatch_act_not_found, act_ref}}
    end
  end

  defp fetch_pending_mandate(state, act) do
    case Map.fetch(state.mandates, act.mandate_ref) do
      {:ok, %Mandate{} = mandate} -> {:ok, mandate}
      {:ok, _invalid} -> {:error, {:invalid_pending_dispatch_mandate, act.mandate_ref}}
      :error -> {:error, {:pending_dispatch_mandate_not_found, act.mandate_ref}}
    end
  end

  defp valid_pending_pair(state, act, mandate) do
    cond do
      not GovernedExecution.executor_mediated?(act) ->
        {:error, {:pending_dispatch_not_executor_mediated, act.ref}}

      act.mandate_revision != mandate.revision ->
        {:error, {:pending_dispatch_mandate_mismatch, act.ref}}

      not is_nil(terminal(state, act.ref)) ->
        {:error, {:pending_dispatch_already_terminal, act.ref}}

      true ->
        :ok
    end
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, _reason} = error), do: error
end
