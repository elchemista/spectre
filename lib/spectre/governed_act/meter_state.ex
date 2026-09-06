defmodule Spectre.GovernedAct.MeterState do
  @moduledoc """
  Pure projection transitions for conserved Meter balances.

  `Spectre.Kernel.Meter` owns the account algebra. This module binds that
  algebra to governed records: Act reservations, Mandate ownership,
  corrections, and subtractive devolution. It mutates only disposable folded
  state and performs no ledger append or external I/O.
  """

  alias Spectre.GovernedAct.{Class, DispatchState, Index, ReadIndex, State}
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.Kernel.Meter
  alias Spectre.Kernel.Meter.Account
  alias Spectre.Kernel.Meter.Amounts
  alias Spectre.{Mandate, Outcome}
  alias Spectre.Mandate.Ancestry

  @doc "Creates physical accounts for a root Mandate allocation."
  @spec initialize(%{optional(String.t()) => Meter.accounts()}, Mandate.t()) ::
          %{optional(String.t()) => Meter.accounts()}
  def initialize(all_meters, %Mandate{} = mandate) when is_map(all_meters) do
    accounts =
      Map.new(mandate.meters, fn {meter_ref, ceiling} ->
        {meter_ref, Account.root(meter_ref, ceiling)}
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
         | meter_reservations: Map.put(state.meter_reservations, context.act_ref, :reserved)
       }}
    end
  end

  @doc "Applies settle, release or suspend to an existing Act reservation."
  @spec transition(State.t(), map(), :settle | :release | :suspend) ::
          {:ok, State.t()} | {:error, term()}
  def transition(%State{} = state, data, operation)
      when is_map(data) and operation in [:settle, :release, :suspend] do
    with {:ok, context} <- reservation_context(state, data),
         {:ok, reservation} <- reservation(state, context.act_ref),
         :ok <- match_reservation(reservation, context),
         :ok <- validate_disposition(state, context.act_ref, operation),
         {:ok, next_status} <- next_status(reservation.status, operation, context.act_ref),
         {:ok, accounts} <- accounts(state, context.mandate_ref),
         {:ok, accounts} <-
           transition_accounts(accounts, context.amounts, operation, reservation.status),
         {:ok, state} <- put_accounts(state, context.mandate_ref, accounts) do
      set_reservation_status(state, context.act_ref, next_status)
    end
  end

  @doc "Recontains a released reservation after a contradictory Outcome."
  @spec recontain(State.t(), map()) :: {:ok, State.t()} | {:error, term()}
  def recontain(%State{} = state, data) when is_map(data) do
    outcome_ref = data["outcome_ref"]

    with {:ok, context} <- reservation_context(state, data),
         {:ok, reservation} <- reservation(state, context.act_ref),
         :ok <- released_reservation(reservation.status, context.act_ref),
         :ok <- match_reservation(reservation, context),
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
         {:ok, state} <- put_accounts(state, context.mandate_ref, accounts),
         {:ok, state} <- set_reservation_status(state, context.act_ref, :suspended) do
      record = %{
        outcome_ref: outcome.ref,
        cause_key: {:contradicted_outcome, context.act_ref, outcome.attempt_ref, outcome.ref},
        recontained: recontained,
        deficits: deficits,
        disposition_act_ref: nil
      }

      {:ok,
       %{
         state
         | meter_recontainments: Map.put(state.meter_recontainments, context.act_ref, record)
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

    with {:ok, act} <- Index.fetch_required(state.acts, act_ref, :act),
         :ok <- devolution_absent(state, act_ref),
         {:ok, child} <- Index.fetch_required(state.mandates, child_ref, :mandate),
         :ok <- child_mandate(child),
         {:ok, parent} <-
           Index.fetch_required(state.mandates, child.parent_ref, :mandate),
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

  @doc "Fetches the current status and immutable binding for an Act reservation."
  @spec reservation(State.t(), String.t()) ::
          {:ok, State.meter_reservation()} | {:error, term()}
  def reservation(%State{} = state, act_ref) do
    case Map.fetch(state.meter_reservations, act_ref) do
      {:ok, status} when status in [:reserved, :suspended, :settled, :released] ->
        reservation_for_act(state, act_ref, status)

      :error ->
        {:error, {:reservation_not_found, act_ref}}

      {:ok, _invalid} ->
        {:error, {:invalid_reservation, act_ref}}
    end
  end

  defp reservation_for_act(state, act_ref, status) do
    case Map.fetch(state.acts, act_ref) do
      {:ok, act} ->
        if Spectre.Act.reservations?(act) do
          {:ok, %{status: status, mandate_ref: act.mandate_ref, amounts: act.reservations}}
        else
          {:error, {:invalid_reservation_act, act_ref}}
        end

      :error ->
        {:error, {:reservation_act_not_found, act_ref}}
    end
  end

  @doc "Returns the projected status for an Act reservation, or `nil` when absent."
  @spec reservation_status(State.t(), String.t()) :: State.reservation_status() | nil
  def reservation_status(%State{} = state, act_ref) do
    case Map.get(state.meter_reservations, act_ref) do
      status when status in [:reserved, :suspended, :settled, :released] -> status
      _missing_or_invalid -> nil
    end
  end

  @doc false
  @spec set_reservation_status(State.t(), String.t(), State.reservation_status()) ::
          {:ok, State.t()} | {:error, term()}
  def set_reservation_status(%State{} = state, act_ref, status)
      when status in [:reserved, :suspended, :settled, :released] do
    with {:ok, _reservation} <- reservation(state, act_ref) do
      {:ok, %{state | meter_reservations: Map.put(state.meter_reservations, act_ref, status)}}
    end
  end

  @doc "Fetches the physical accounts backing a logical Mandate revision."
  @spec accounts(State.t(), String.t()) :: {:ok, Meter.accounts()} | {:error, term()}
  def accounts(%State{} = state, mandate_ref) do
    with {:ok, owner_ref} <- owner(state, mandate_ref),
         {:ok, accounts} <- Map.fetch(state.meters, owner_ref) do
      {:ok, accounts}
    else
      :error -> {:error, {:meter_mandate_not_found, mandate_ref}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Fetches the physical owner for a logical Mandate revision."
  @spec owner(State.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def owner(%State{} = state, mandate_ref) do
    case Map.fetch(state.meter_owner_aliases, mandate_ref) do
      {:ok, owner_ref} ->
        {:ok, owner_ref}

      :error ->
        if Map.has_key?(state.meters, mandate_ref),
          do: {:ok, mandate_ref},
          else: {:error, {:meter_owner_not_found, mandate_ref}}
    end
  end

  @doc "Replaces physical accounts after a validated algebra transition."
  @spec put_accounts(State.t(), String.t(), Meter.accounts()) ::
          {:ok, State.t()} | {:error, term()}
  def put_accounts(%State{} = state, mandate_ref, accounts) when is_map(accounts) do
    with {:ok, owner_ref} <- owner(state, mandate_ref) do
      {:ok, %{state | meters: Map.put(state.meters, owner_ref, accounts)}}
    end
  end

  @doc "Applies one account operation to every amount as a single pure transition."
  @spec transition_accounts(Meter.accounts(), Amounts.t(), atom(), atom()) ::
          {:ok, Meter.accounts()} | {:error, term()}
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
  @spec account(Meter.accounts(), String.t()) :: {:ok, Account.t()} | {:error, term()}
  def account(accounts, meter_ref) when is_map(accounts) do
    case Map.fetch(accounts, meter_ref) do
      {:ok, %Account{meter_ref: ^meter_ref} = account} ->
        {:ok, account}

      {:ok, %Account{meter_ref: actual_ref}} ->
        {:error, {:meter_account_ref_mismatch, meter_ref, actual_ref}}

      {:ok, _invalid} ->
        {:error, {:invalid_meter_account, meter_ref}}

      :error ->
        {:error, {:meter_not_found, meter_ref}}
    end
  end

  defp reservation_context(state, data) do
    act_ref = data["act_ref"]
    mandate_ref = data["mandate_ref"]

    with {:ok, act} <- Index.fetch_required(state.acts, act_ref, :act),
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
    case Map.fetch(state.meter_reservations, act_ref) do
      :error ->
        :ok

      {:ok, reservation} ->
        {:error, {:reservation_already_exists, act_ref, reservation}}
    end
  end

  defp match_reservation(reservation, context) do
    if reservation.mandate_ref == context.mandate_ref and
         reservation.amounts == context.amounts,
       do: :ok,
       else: {:error, {:reservation_identity_mismatch, context.act_ref}}
  end

  defp validate_disposition(state, act_ref, operation) do
    allowed_statuses =
      case operation do
        :settle -> Outcome.correction_statuses()
        :release -> [:definitive_no_effect]
        :suspend -> [:ambiguous]
      end

    cond do
      operation == :settle and internal_spend_act?(Map.get(state.acts, act_ref)) ->
        :ok

      operation == :release and DispatchState.cancelled?(state, act_ref) ->
        :ok

      true ->
        validate_outcome_disposition(state, act_ref, operation, allowed_statuses)
    end
  end

  defp validate_outcome_disposition(state, act_ref, operation, allowed_statuses) do
    {outcome_present?, allowed_outcome?} =
      Enum.reduce_while(
        ReadIndex.outcomes_for(state, :act, act_ref),
        {false, false},
        fn
          {_ref, %Outcome{act_ref: ^act_ref, status: status}}, _acc ->
            if status in allowed_statuses,
              do: {:halt, {true, true}},
              else: {:cont, {true, false}}

          _other, acc ->
            {:cont, acc}
        end
      )

    if allowed_outcome? or
         (operation == :suspend and DispatchState.attempted?(state, act_ref) and
            not outcome_present?) do
      :ok
    else
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

      not Class.exact_row?("mandate.devolve", act.row) ->
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
      Enum.reduce(accounts, %{}, fn {meter_ref, account}, available ->
        case account.available do
          quantity when is_integer(quantity) and quantity > 0 ->
            Map.put(available, meter_ref, quantity)

          _zero_or_invalid ->
            available
        end
      end)

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

  defp internal_spend_act?(act), do: GovernedExecution.metered_ledger_internal?(act)
end
