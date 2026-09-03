defmodule Spectre.GovernedAct.MeterState do
  @moduledoc """
  Pure projection transitions for conserved Meter balances.

  `Spectre.Kernel.Meter` owns the account algebra. This module binds that
  algebra to governed records: Act reservations, Mandate ownership,
  corrections, and subtractive devolution. It mutates only disposable folded
  state and performs no ledger append or external I/O.
  """

  alias Spectre.{Act, Governance, Mandate, Outcome, Row}
  alias Spectre.GovernedAct.{State, View}
  alias Spectre.Kernel.Meter
  alias Spectre.Kernel.Meter.Amounts
  alias Spectre.Mandate.Ancestry

  @doc "Creates physical accounts for a root Mandate allocation."
  @spec initialize(map(), Mandate.t()) :: map()
  def initialize(all_meters, %Mandate{} = mandate) when is_map(all_meters) do
    accounts =
      Map.new(mandate.meters, fn {meter_ref, ceiling} ->
        {meter_ref,
         %{
           ceiling: ceiling,
           available: ceiling,
           reserved: 0,
           suspended: 0,
           spent: 0,
           delegated: 0
         }}
      end)

    Map.put(all_meters, mandate.ref, accounts)
  end

  @doc "Applies the first reservation for an Act."
  @spec reserve(State.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def reserve(%State{} = state, data) when is_map(data) do
    with {:ok, context} <- reservation_context(state, data),
         :ok <- reservation_absent(state, context.act_ref),
         {:ok, accounts} <- accounts(state, context.mandate_ref),
         {:ok, accounts} <- transition_accounts(accounts, context.amounts, :reserve, :unreserved),
         {:ok, state} <- put_accounts(state, context.mandate_ref, accounts) do
      {:ok,
       %{
         state
         | reservation_states: Map.put(state.reservation_states, context.act_ref, :reserved),
           reservation_bindings: Map.put(state.reservation_bindings, context.act_ref, context)
       }}
    end
  end

  @doc "Applies settle, release or suspend to an existing Act reservation."
  @spec transition(State.t(), map(), :settle | :release | :suspend) ::
          {:ok, State.t()} | {:error, term()}
  def transition(%State{} = state, data, operation)
      when is_map(data) and operation in [:settle, :release, :suspend] do
    with {:ok, context} <- reservation_context(state, data),
         {:ok, status, binding} <- reservation(state, context.act_ref),
         :ok <- match_reservation(binding, context),
         :ok <- validate_disposition(state, context.act_ref, operation),
         {:ok, next_status} <- next_status(status, operation, context.act_ref),
         {:ok, accounts} <- accounts(state, context.mandate_ref),
         {:ok, accounts} <- transition_accounts(accounts, context.amounts, operation, status),
         {:ok, state} <- put_accounts(state, context.mandate_ref, accounts) do
      {:ok,
       %{
         state
         | reservation_states: Map.put(state.reservation_states, context.act_ref, next_status)
       }}
    end
  end

  @doc "Recontains a released reservation after a contradictory Outcome."
  @spec recontain(State.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def recontain(%State{} = state, data) when is_map(data) do
    outcome_ref = data["outcome_ref"]

    with {:ok, context} <- reservation_context(state, data),
         {:ok, status, binding} <- reservation(state, context.act_ref),
         :ok <- released_reservation(status, context.act_ref),
         :ok <- match_reservation(binding, context),
         {:ok, %Outcome{} = outcome} <- Map.fetch(state.outcomes, outcome_ref),
         :ok <- validate_recontainment_cause(state, context, outcome),
         :ok <- recontainment_absent(state, context.act_ref),
         {:ok, recontained} <- Amounts.normalize(data["recontained"]),
         {:ok, deficits} <- Amounts.normalize(data["deficits"]),
         :ok <- recontainment_partition(context.amounts, recontained, deficits),
         {:ok, accounts} <- accounts(state, context.mandate_ref),
         {:ok, accounts, expected_recontained, expected_deficits} <-
           Meter.recontain_many(context.amounts, accounts),
         :ok <-
           exact_recontainment(
             context.act_ref,
             recontained,
             deficits,
             expected_recontained,
             expected_deficits
           ),
         {:ok, state} <- put_accounts(state, context.mandate_ref, accounts) do
      record = %{
        act_ref: context.act_ref,
        mandate_ref: context.mandate_ref,
        outcome_ref: outcome.ref,
        cause_key: {:contradicted_outcome, context.act_ref, outcome.attempt_ref, outcome.ref},
        amounts: context.amounts,
        recontained: recontained,
        deficits: deficits,
        status: :open,
        disposition_act_ref: nil
      }

      {:ok,
       %{
         state
         | reservation_states: Map.put(state.reservation_states, context.act_ref, :suspended),
           meter_recontainments: Map.put(state.meter_recontainments, context.act_ref, record)
       }}
    else
      :error -> {:error, {:recontainment_outcome_not_found, outcome_ref}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns all free balances of a terminal child Mandate to its parent."
  @spec devolve(State.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def devolve(%State{} = state, data) when is_map(data) do
    act_ref = data["act_ref"]
    child_ref = data["child_mandate_ref"]

    with {:ok, act} <- fetch(state.acts, act_ref, :act),
         :ok <- devolution_absent(state, act_ref),
         {:ok, child} <- fetch(state.mandates, child_ref, :mandate),
         :ok <- child_mandate(child),
         {:ok, parent} <- fetch(state.mandates, child.parent_ref, :mandate),
         {:ok, true} <- terminal?(state, child, act.committed_at),
         {:ok, amounts} <- devolution_amounts(data["amounts"]),
         :ok <- validate_devolution_act(act, child, amounts),
         {:ok, parent_owner_ref} <- owner(state, parent.ref),
         {:ok, child_owner_ref} <- owner(state, child.ref),
         true <- parent_owner_ref != child_owner_ref,
         {:ok, parent_accounts} <- accounts(state, parent.ref),
         {:ok, child_accounts} <- accounts(state, child.ref),
         :ok <- exact_available_devolution(child.ref, child_accounts, amounts),
         {:ok, parent_accounts, child_accounts} <-
           apply_devolution(parent_accounts, child_accounts, amounts) do
      meters =
        state.meters
        |> Map.put(parent_owner_ref, parent_accounts)
        |> Map.put(child_owner_ref, child_accounts)

      {:ok,
       %{
         state
         | meters: meters,
           meter_devolutions: MapSet.put(state.meter_devolutions, act_ref)
       }}
    else
      false -> {:error, {:meter_devolution_owner_collision, child_ref}}
      {:ok, false} -> {:error, {:mandate_not_terminal_for_devolution, child_ref}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetches the current reservation status and immutable Act binding."
  @spec reservation(State.t(), String.t()) :: {:ok, atom(), map()} | {:error, term()}
  def reservation(%State{} = state, act_ref) do
    with {:ok, status} <- Map.fetch(state.reservation_states, act_ref),
         {:ok, binding} <- Map.fetch(state.reservation_bindings, act_ref) do
      {:ok, status, binding}
    else
      :error -> {:error, {:reservation_not_found, act_ref}}
    end
  end

  @doc "Fetches the physical accounts backing a logical Mandate revision."
  @spec accounts(State.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def accounts(%State{} = state, mandate_ref),
    do: View.meter_accounts(state, mandate_ref)

  @doc "Fetches the physical owner for a logical Mandate revision."
  @spec owner(State.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def owner(%State{} = state, mandate_ref) do
    case Map.fetch(state.meter_owners, mandate_ref) do
      {:ok, owner_ref} -> {:ok, owner_ref}
      :error -> {:error, {:meter_owner_not_found, mandate_ref}}
    end
  end

  @doc "Replaces physical accounts after a validated algebra transition."
  @spec put_accounts(State.t(), String.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def put_accounts(%State{} = state, mandate_ref, accounts) when is_map(accounts) do
    with {:ok, owner_ref} <- owner(state, mandate_ref) do
      {:ok, %{state | meters: Map.put(state.meters, owner_ref, accounts)}}
    end
  end

  @doc "Applies one account operation to every amount as a single pure transition."
  @spec transition_accounts(map(), Amounts.t(), atom(), atom()) ::
          {:ok, map()} | {:error, term()}
  def transition_accounts(accounts, amounts, operation, reservation_status)
      when is_map(accounts) and is_map(amounts) do
    Enum.reduce_while(amounts, {:ok, accounts}, fn {meter_ref, amount}, {:ok, current} ->
      with {:ok, account} <- account(current, meter_ref),
           {:ok, account} <- transition_account(account, operation, reservation_status, amount) do
        {:cont, {:ok, Map.put(current, meter_ref, account)}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Fetches one physical Meter account."
  @spec account(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def account(accounts, meter_ref) when is_map(accounts) do
    case Map.fetch(accounts, meter_ref) do
      {:ok, account} -> {:ok, account}
      :error -> {:error, {:meter_not_found, meter_ref}}
    end
  end

  defp reservation_context(state, data) do
    act_ref = data["act_ref"]
    mandate_ref = data["mandate_ref"]

    with {:ok, act} <- fetch(state.acts, act_ref, :act),
         true <- act.mandate_ref == mandate_ref,
         {:ok, amounts} <- Amounts.normalize(data["amounts"]),
         true <- amounts == act.reservations do
      {:ok, %{act_ref: act_ref, mandate_ref: mandate_ref, amounts: amounts}}
    else
      false -> {:error, {:meter_act_binding_mismatch, act_ref, mandate_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp reservation_absent(state, act_ref) do
    case Map.fetch(state.reservation_states, act_ref) do
      :error -> :ok
      {:ok, status} -> {:error, {:reservation_already_exists, act_ref, status}}
    end
  end

  defp match_reservation(binding, context) do
    if binding.act_ref == context.act_ref and binding.mandate_ref == context.mandate_ref and
         binding.amounts == context.amounts,
       do: :ok,
       else: {:error, {:reservation_identity_mismatch, context.act_ref}}
  end

  defp validate_disposition(state, act_ref, operation) do
    outcomes = state.outcomes |> Map.values() |> Enum.filter(&(&1.act_ref == act_ref))

    allowed_statuses =
      case operation do
        :settle -> [:succeeded, :failed]
        :release -> [:definitive_no_effect]
        :suspend -> [:ambiguous]
      end

    cond do
      Enum.any?(outcomes, &(&1.status in allowed_statuses)) ->
        :ok

      operation == :settle and internal_spend_act?(Map.get(state.acts, act_ref)) ->
        :ok

      operation == :release and Map.has_key?(state.dispatch_cancellations, act_ref) ->
        :ok

      operation == :suspend and Map.has_key?(state.attempts_by_act, act_ref) and outcomes == [] ->
        :ok

      true ->
        {:error, {:reservation_disposition_not_evidenced, act_ref, operation}}
    end
  end

  defp next_status(:reserved, :settle, _act_ref), do: {:ok, :settled}
  defp next_status(:reserved, :release, _act_ref), do: {:ok, :released}
  defp next_status(:reserved, :suspend, _act_ref), do: {:ok, :suspended}
  defp next_status(:suspended, :settle, _act_ref), do: {:ok, :settled}
  defp next_status(:suspended, :release, _act_ref), do: {:ok, :released}

  defp next_status(status, operation, act_ref),
    do: {:error, {:invalid_reservation_transition, act_ref, status, operation}}

  defp transition_account(account, :reserve, :unreserved, amount),
    do: Meter.reserve(account, amount)

  defp transition_account(account, :settle, :reserved, amount),
    do: Meter.settle(account, amount)

  defp transition_account(account, :release, :reserved, amount),
    do: Meter.release(account, amount)

  defp transition_account(account, :suspend, :reserved, amount),
    do: Meter.suspend(account, amount)

  defp transition_account(account, :settle, :suspended, amount),
    do: Meter.resolve_suspended(account, amount, :settle)

  defp transition_account(account, :release, :suspended, amount),
    do: Meter.resolve_suspended(account, amount, :release)

  defp released_reservation(:released, _act_ref), do: :ok

  defp released_reservation(status, act_ref),
    do: {:error, {:meter_recontainment_requires_released_reservation, act_ref, status}}

  defp validate_recontainment_cause(state, context, outcome) do
    corrected = Map.get(state.outcomes, outcome.contradicts_outcome_ref)

    cond do
      not Outcome.correction?(outcome) ->
        {:error, {:meter_recontainment_outcome_not_correction, outcome.ref}}

      outcome.act_ref != context.act_ref ->
        {:error, {:meter_recontainment_act_mismatch, outcome.ref, context.act_ref}}

      not match?(%Outcome{status: :definitive_no_effect}, corrected) ->
        {:error, {:meter_recontainment_without_definitive_no_effect, outcome.ref}}

      true ->
        :ok
    end
  end

  defp recontainment_absent(state, act_ref) do
    if Map.has_key?(state.meter_recontainments, act_ref),
      do: {:error, {:meter_recontainment_already_recorded, act_ref}},
      else: :ok
  end

  defp recontainment_partition(amounts, recontained, deficits) do
    case Amounts.exact_partition(amounts, recontained, deficits) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_meter_recontainment_partition}
    end
  end

  defp exact_recontainment(_act_ref, left, right, left, right), do: :ok

  defp exact_recontainment(act_ref, _left, _right, _expected_left, _expected_right),
    do: {:error, {:meter_recontainment_balance_mismatch, act_ref}}

  defp devolution_absent(state, act_ref) do
    if MapSet.member?(state.meter_devolutions, act_ref),
      do: {:error, {:meter_devolution_already_applied, act_ref}},
      else: :ok
  end

  defp child_mandate(%Mandate{parent_ref: parent_ref})
       when is_binary(parent_ref) and parent_ref != "",
       do: :ok

  defp child_mandate(%Mandate{ref: ref}), do: {:error, {:root_mandate_cannot_devolve, ref}}

  defp terminal?(state, mandate, time) when is_integer(time) do
    Ancestry.terminal?(state.mandates, state.revocations, mandate, time)
  end

  defp validate_devolution_act(act, child, amounts) do
    consequence = %{
      "mandate_devolve" => %{"child_mandate_ref" => child.ref, "amounts" => amounts}
    }

    cond do
      act.class != "mandate.devolve" ->
        {:error, {:meter_devolution_act_class_mismatch, act.ref, act.class}}

      Row.dimensions(act.row) != [:delegate, :govern] ->
        {:error, {:meter_devolution_act_row_mismatch, act.ref}}

      map_size(act.reservations) > 0 ->
        {:error, {:meter_devolution_act_has_reservations, act.ref}}

      child.ref not in act.target_refs ->
        {:error, {:meter_devolution_target_missing, act.ref, child.ref}}

      act.consequence != consequence ->
        {:error, {:meter_devolution_consequence_mismatch, act.ref, child.ref}}

      true ->
        :ok
    end
  end

  defp exact_available_devolution(child_ref, accounts, amounts) do
    available =
      accounts
      |> Enum.flat_map(fn {meter_ref, account} ->
        case Map.get(account, :available) do
          quantity when is_integer(quantity) and quantity > 0 -> [{meter_ref, quantity}]
          _zero_or_invalid -> []
        end
      end)
      |> Map.new()

    cond do
      map_size(available) == 0 ->
        {:error, {:meter_devolution_has_no_available_quantity, child_ref}}

      available != amounts ->
        {:error, {:meter_devolution_not_exact_available, child_ref}}

      true ->
        :ok
    end
  end

  defp apply_devolution(parent_accounts, child_accounts, amounts) do
    amounts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, parent_accounts, child_accounts}, fn
      {meter_ref, quantity}, {:ok, parents, children} ->
        with {:ok, parent_account} <- account(parents, meter_ref),
             {:ok, child_account} <- account(children, meter_ref),
             {:ok, parent_account, child_account} <-
               Meter.devolve(parent_account, child_account, quantity) do
          {:cont,
           {:ok, Map.put(parents, meter_ref, parent_account),
            Map.put(children, meter_ref, child_account)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  defp devolution_amounts(amounts) do
    case Amounts.non_empty(amounts) do
      {:ok, amounts} -> {:ok, amounts}
      {:error, :empty_meter_amounts} -> {:error, :empty_meter_devolution}
      {:error, _reason} = error -> error
    end
  end

  defp internal_spend_act?(%Act{row: %{spend: true}, reservations: reservations} = act)
       when map_size(reservations) > 0,
       do: Governance.ledger_internal?(act)

  defp internal_spend_act?(_act), do: false

  defp fetch(collection, key, kind) do
    case Map.fetch(collection, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {kind, :not_found, key}}
    end
  end
end
