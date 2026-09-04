defmodule Spectre.Kernel.Meter do
  @moduledoc """
  Pure, conservative accounting for Mandate resource limits.

  Every operation consumes a typed `Meter.Account` and preserves:

      ceiling = available + reserved + suspended + spent + delegated

  Quantities move between buckets; they are never inferred or created. A
  parent's delegated quantity becomes a child's ceiling, so delegation is
  subtractive rather than a second issuance of authority.

  `suspended` is never released by time or restart. It moves only through an
  explicit Duty disposition or definitive late Outcome.
  """

  alias Spectre.Kernel.Meter.{Account, Amounts}

  @type accounts :: %{optional(String.t()) => Account.t()}
  @type reason :: term()

  @doc "Validates a typed account and its conservation equation."
  @spec validate(Account.t()) :: :ok | {:error, reason()}
  defdelegate validate(account), to: Account

  @doc "Returns whether quantity can currently be reserved."
  @spec available?(Account.t(), non_neg_integer()) :: boolean()
  def available?(%Account{available: available} = account, quantity)
      when is_integer(quantity) and quantity >= 0 do
    Account.validate(account) == :ok and available >= quantity
  end

  def available?(_account, _quantity), do: false

  @doc "Moves quantity from `available` to `reserved`."
  @spec reserve(Account.t(), non_neg_integer()) :: {:ok, Account.t()} | {:error, reason()}
  def reserve(account, quantity), do: move(account, :available, :reserved, quantity)

  @doc "Moves a definitive effected quantity from `reserved` to `spent`."
  @spec settle(Account.t(), non_neg_integer()) :: {:ok, Account.t()} | {:error, reason()}
  def settle(account, quantity), do: move(account, :reserved, :spent, quantity)

  @doc "Returns `reserved` quantity only after definitive no-effect Evidence."
  @spec release(Account.t(), non_neg_integer()) :: {:ok, Account.t()} | {:error, reason()}
  def release(account, quantity), do: move(account, :reserved, :available, quantity)

  @doc "Moves an ambiguous reservation from `reserved` to `suspended`."
  @spec suspend(Account.t(), non_neg_integer()) :: {:ok, Account.t()} | {:error, reason()}
  def suspend(account, quantity), do: move(account, :reserved, :suspended, quantity)

  @doc """
  Conservatively takes back released quantities that remain available.

  The returned maps partition every request into `recontained` and `deficits`.
  A deficit is reported without inventing quantity or violating conservation.
  """
  @spec recontain_many(Amounts.t(), accounts()) ::
          {:ok, accounts(), Amounts.t(), Amounts.t()} | {:error, reason()}
  def recontain_many(requests, accounts) do
    with {:ok, requests} <- Amounts.normalize(requests),
         {:ok, accounts} <- account_index(accounts),
         :ok <- known_meters(requests, accounts) do
      requests
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while({:ok, accounts, %{}, %{}}, fn
        {meter_ref, quantity}, {:ok, current, recontained, deficits} ->
          account = Map.fetch!(current, meter_ref)
          recovered = min(account.available, quantity)

          case move_valid(account, :available, :suspended, recovered) do
            {:ok, account} ->
              {:cont,
               {:ok, Map.put(current, meter_ref, account),
                put_positive(recontained, meter_ref, recovered),
                put_positive(deficits, meter_ref, quantity - recovered)}}

            {:error, _reason} = error ->
              {:halt, error}
          end
      end)
    end
  end

  @doc """
  Resolves suspended quantity under an explicit durable disposition.

  `:settle` acknowledges it as spent; `:release` makes it available again.
  """
  @spec resolve_suspended(Account.t(), non_neg_integer(), :settle | :release) ::
          {:ok, Account.t()} | {:error, reason()}
  def resolve_suspended(account, quantity, :settle),
    do: move(account, :suspended, :spent, quantity)

  def resolve_suspended(account, quantity, :release),
    do: move(account, :suspended, :available, quantity)

  def resolve_suspended(_account, _quantity, disposition),
    do: {:error, {:invalid_suspended_disposition, disposition}}

  @doc """
  Transfers quantity subtractively from a parent to a child allocation.

  Both accounts must represent the same Meter. The parent moves
  `available -> delegated`; the child's `ceiling` and `available` grow by the
  same quantity.
  """
  @spec delegate(Account.t(), Account.t(), non_neg_integer()) ::
          {:ok, Account.t(), Account.t()} | {:error, reason()}
  def delegate(%Account{} = parent, %Account{} = child, quantity) do
    with :ok <- validate_pair(parent, child),
         :ok <- valid_quantity(quantity),
         :ok <- enough(parent, :available, quantity),
         {:ok, parent} <- move_valid(parent, :available, :delegated, quantity),
         {:ok, child} <- resize_child(child, quantity) do
      {:ok, parent, child}
    end
  end

  def delegate(_parent, _child, _quantity), do: {:error, :invalid_meter_account}

  @doc "Returns all currently free child quantity to its parent."
  @spec devolve(Account.t(), Account.t()) ::
          {:ok, Account.t(), Account.t()} | {:error, reason()}
  def devolve(%Account{} = parent, %Account{available: available} = child),
    do: devolve(parent, child, available)

  def devolve(_parent, _child), do: {:error, :invalid_meter_account}

  @doc """
  Returns only free child quantity to its parent.

  Reserved and suspended quantities remain bound to their Attempt or Duty, and
  spent remains historical. Only `available` can therefore be devolved.
  """
  @spec devolve(Account.t(), Account.t(), non_neg_integer()) ::
          {:ok, Account.t(), Account.t()} | {:error, reason()}
  def devolve(%Account{} = parent, %Account{} = child, quantity) do
    with :ok <- validate_pair(parent, child),
         :ok <- valid_quantity(quantity),
         :ok <- enough(parent, :delegated, quantity),
         :ok <- enough(child, :available, quantity),
         {:ok, parent} <- move_valid(parent, :delegated, :available, quantity),
         {:ok, child} <- resize_child(child, -quantity) do
      {:ok, parent, child}
    end
  end

  def devolve(_parent, _child, _quantity), do: {:error, :invalid_meter_account}

  @doc "Validates a canonical reservation request against current balances."
  @spec plan_reservations(Amounts.t(), accounts()) ::
          {:ok, Amounts.t()} | {:error, reason()}
  def plan_reservations(requests, accounts) do
    with {:ok, requests} <- Amounts.normalize(requests),
         {:ok, accounts} <- account_index(accounts),
         :ok <- requests_fit(requests, accounts) do
      {:ok, requests}
    end
  end

  @doc "Plans and applies several reservations as one pure transition."
  @spec reserve_many(Amounts.t(), accounts()) ::
          {:ok, accounts(), Amounts.t()} | {:error, reason()}
  def reserve_many(requests, accounts) do
    with {:ok, requests} <- Amounts.normalize(requests),
         {:ok, accounts} <- account_index(accounts),
         :ok <- requests_fit(requests, accounts) do
      updated =
        Enum.reduce(requests, accounts, fn {meter_ref, quantity}, current ->
          {:ok, account} =
            move_valid(Map.fetch!(current, meter_ref), :available, :reserved, quantity)

          Map.put(current, meter_ref, account)
        end)

      {:ok, updated, requests}
    end
  end

  defp move(%Account{} = account, from, to, quantity) do
    with :ok <- Account.validate(account),
         :ok <- valid_quantity(quantity),
         :ok <- enough(account, from, quantity) do
      move_valid(account, from, to, quantity)
    end
  end

  defp move(_account, _from, _to, _quantity), do: {:error, :invalid_meter_account}

  defp move_valid(account, from, to, quantity) do
    updated =
      account
      |> Map.update!(from, &(&1 - quantity))
      |> Map.update!(to, &(&1 + quantity))

    with :ok <- Account.validate(updated), do: {:ok, updated}
  end

  defp resize_child(child, quantity) do
    updated = %{
      child
      | ceiling: child.ceiling + quantity,
        available: child.available + quantity
    }

    with :ok <- Account.validate(updated), do: {:ok, updated}
  end

  defp enough(account, bucket, quantity) do
    if Map.fetch!(account, bucket) >= quantity,
      do: :ok,
      else: {:error, {:insufficient_meter_quantity, bucket}}
  end

  defp validate_pair(parent, child) do
    with :ok <- Account.validate(parent),
         :ok <- Account.validate(child),
         true <- parent.meter_ref == child.meter_ref do
      :ok
    else
      false -> {:error, :incompatible_meter_allocations}
      {:error, _reason} = error -> error
    end
  end

  defp requests_fit(requests, accounts) do
    Enum.reduce_while(requests, :ok, fn {meter_ref, quantity}, :ok ->
      case Map.fetch(accounts, meter_ref) do
        {:ok, %Account{available: available}} when available >= quantity ->
          {:cont, :ok}

        {:ok, %Account{}} ->
          {:halt, {:error, {:insufficient_meter_quantity, meter_ref}}}

        :error ->
          {:halt, {:error, {:unknown_meter, meter_ref}}}
      end
    end)
  end

  defp known_meters(requests, accounts) do
    case Enum.find(requests, fn {meter_ref, _quantity} ->
           not Map.has_key?(accounts, meter_ref)
         end) do
      nil -> :ok
      {meter_ref, _quantity} -> {:error, {:unknown_meter, meter_ref}}
    end
  end

  defp account_index(accounts) when is_map(accounts) and not is_struct(accounts) do
    accounts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn
      {meter_ref, %Account{meter_ref: meter_ref} = account}, {:ok, index} ->
        case Account.validate(account) do
          :ok -> {:cont, {:ok, Map.put(index, meter_ref, account)}}
          {:error, reason} -> {:halt, {:error, {meter_ref, reason}}}
        end

      {meter_ref, %Account{meter_ref: actual_ref}}, _acc ->
        {:halt, {:error, {:meter_account_ref_mismatch, meter_ref, actual_ref}}}

      _invalid, _acc ->
        {:halt, {:error, :invalid_meter_accounts}}
    end)
  end

  defp account_index(_accounts), do: {:error, :invalid_meter_accounts}

  defp valid_quantity(quantity) when is_integer(quantity) and quantity >= 0, do: :ok
  defp valid_quantity(_quantity), do: {:error, :invalid_meter_quantity}

  defp put_positive(map, _meter_ref, 0), do: map
  defp put_positive(map, meter_ref, quantity), do: Map.put(map, meter_ref, quantity)
end
