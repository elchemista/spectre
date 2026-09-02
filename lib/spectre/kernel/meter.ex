defmodule Spectre.Kernel.Meter.Account do
  @moduledoc """
  Portable quantitative allocation folded from ledger movements.

  The root ceiling is conserved across the five mutually exclusive buckets.
  A child allocation's ceiling is represented once in its parent's `delegated`
  bucket; it is not newly issued authority.
  """

  @schema_version 1
  alias Spectre.Kernel.Meter

  @fields [
    :schema_version,
    :ref,
    :mandate_ref,
    :parent_ref,
    :unit,
    :precision,
    :ceiling,
    :available,
    :reserved,
    :suspended,
    :spent,
    :delegated
  ]

  defstruct schema_version: @schema_version,
            ref: nil,
            mandate_ref: nil,
            parent_ref: nil,
            unit: nil,
            precision: 0,
            ceiling: 0,
            available: 0,
            reserved: 0,
            suspended: 0,
            spent: 0,
            delegated: 0

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          ref: term(),
          mandate_ref: term(),
          parent_ref: term(),
          unit: term(),
          precision: non_neg_integer(),
          ceiling: non_neg_integer(),
          available: non_neg_integer(),
          reserved: non_neg_integer(),
          suspended: non_neg_integer(),
          spent: non_neg_integer(),
          delegated: non_neg_integer()
        }

  @doc "Builds an account and validates its conservation equation."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()
  def new(%__MODULE__{} = account), do: validate_account(account)

  def new(attrs) when is_map(attrs) do
    with {:ok, attrs} <- normalize_attrs(attrs) do
      attrs = Map.put_new(attrs, :schema_version, @schema_version)
      attrs = Map.put_new(attrs, :precision, 0)
      account = struct(__MODULE__, attrs)
      validate_account(account)
    end
  end

  def new(_attrs), do: {:error, :invalid_meter_account}

  defp validate_account(account) do
    case Meter.validate(account) do
      :ok -> {:ok, account}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_attrs(attrs) do
    names = Map.new(@fields, &{Atom.to_string(&1), &1})

    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      field = if is_atom(key) and key in @fields, do: key, else: Map.get(names, key)

      cond do
        is_nil(field) ->
          {:halt, {:error, {:unknown_meter_account_field, key}}}

        Map.has_key?(normalized, field) ->
          {:halt, {:error, {:duplicate_meter_account_field, field}}}

        true ->
          {:cont, {:ok, Map.put(normalized, field, value)}}
      end
    end)
  end
end

defmodule Spectre.Kernel.Meter do
  @moduledoc """
  Pure, conservative accounting for Mandate resource limits.

  All quantities are non-negative integers in an explicitly declared unit and
  precision. Every transition preserves:

      ceiling = available + reserved + suspended + spent + delegated

  `suspended` is never released by ordinary settlement or time. It can move only
  through `resolve_suspended/3`, which is intended to be called while applying a
  durable Duty disposition or definitive late Outcome.

  Functions accept the included `Account` struct or a map with the same bucket
  fields. They do not persist transitions and do not make retries idempotent;
  idempotency belongs to uniquely keyed ledger movements.
  """

  alias Spectre.Kernel.Meter.Account

  @buckets [:available, :reserved, :suspended, :spent, :delegated]

  @type account :: Account.t() | map()
  @type reason :: term()

  @doc "Validates integer buckets and the conservation equation."
  @spec validate(account()) :: :ok | {:error, reason()}
  def validate(account) when is_map(account) do
    ceiling = amount(account, :ceiling)
    precision = get(account, [:precision], 0)

    invalid_bucket =
      Enum.find([:ceiling | @buckets], fn bucket ->
        not non_negative_integer?(amount(account, bucket))
      end)

    cond do
      invalid_bucket ->
        {:error, {:invalid_meter_quantity, invalid_bucket}}

      not is_integer(precision) or precision < 0 ->
        {:error, :invalid_meter_precision}

      Enum.sum(Enum.map(@buckets, &amount(account, &1))) != ceiling ->
        {:error,
         {:meter_conservation_violation,
          %{ceiling: ceiling, buckets: Map.new(@buckets, &{&1, amount(account, &1)})}}}

      true ->
        :ok
    end
  end

  def validate(_account), do: {:error, :invalid_meter_account}

  @doc "Returns whether an amount can currently be reserved."
  @spec available?(account(), non_neg_integer()) :: boolean()
  def available?(account, quantity) do
    validate(account) == :ok and non_negative_integer?(quantity) and
      amount(account, :available) >= quantity
  end

  @doc "Moves quantity from `available` to `reserved`."
  @spec reserve(account(), non_neg_integer()) :: {:ok, account()} | {:error, reason()}
  def reserve(account, quantity), do: move(account, :available, :reserved, quantity)

  @doc "Moves a definitive effected quantity from `reserved` to `spent`."
  @spec settle(account(), non_neg_integer()) :: {:ok, account()} | {:error, reason()}
  def settle(account, quantity), do: move(account, :reserved, :spent, quantity)

  @doc "Returns `reserved` quantity only after definitive no-effect Evidence."
  @spec release(account(), non_neg_integer()) :: {:ok, account()} | {:error, reason()}
  def release(account, quantity), do: move(account, :reserved, :available, quantity)

  @doc "Moves an ambiguous reservation from `reserved` to `suspended`."
  @spec suspend(account(), non_neg_integer()) :: {:ok, account()} | {:error, reason()}
  def suspend(account, quantity), do: move(account, :reserved, :suspended, quantity)

  @doc """
  Conservatively takes back as much released quantity as remains available.

  The returned maps partition every requested quantity into `recontained` and
  `deficits`. Only the former moves from `available` to `suspended`; a deficit
  is reported without creating quantity or violating the conservation equation.
  """
  @spec recontain_many(map() | list(), map() | list()) ::
          {:ok, %{term() => account()}, map(), map()} | {:error, reason()}
  def recontain_many(requests, accounts) do
    with {:ok, requests} <- normalize_requests(requests),
         {:ok, accounts} <- account_index(accounts) do
      Enum.reduce_while(requests, {:ok, accounts, %{}, %{}}, fn
        {ref, quantity}, {:ok, current, recontained, deficits} ->
          with {:ok, account} <- fetch_account(current, ref),
               :ok <- validate_account_for_request(account, ref),
               {:ok, account, recovered, deficit} <-
                 recontain_available(account, quantity) do
            {:cont,
             {:ok, Map.put(current, ref, account), put_positive(recontained, ref, recovered),
              put_positive(deficits, ref, deficit)}}
          else
            {:error, _reason} = error -> {:halt, error}
          end
      end)
    end
  end

  @doc """
  Resolves suspended quantity under an explicit durable disposition.

  `:settle` acknowledges it as spent; `:release` makes it available again. No
  default exists because silence, restart, expiry and elapsed time cannot choose
  either disposition.
  """
  @spec resolve_suspended(account(), non_neg_integer(), :settle | :release) ::
          {:ok, account()} | {:error, reason()}
  def resolve_suspended(account, quantity, :settle),
    do: move(account, :suspended, :spent, quantity)

  def resolve_suspended(account, quantity, :release),
    do: move(account, :suspended, :available, quantity)

  def resolve_suspended(_account, _quantity, disposition),
    do: {:error, {:invalid_suspended_disposition, disposition}}

  defp recontain_available(account, quantity) do
    recovered = min(amount(account, :available), quantity)

    with {:ok, account} <- move_valid(account, :available, :suspended, recovered) do
      {:ok, account, recovered, quantity - recovered}
    end
  end

  defp put_positive(map, _ref, 0), do: map
  defp put_positive(map, ref, quantity), do: Map.put(map, ref, quantity)

  @doc """
  Transfers quantity subtractively from a parent to a child allocation.

  The parent moves `available -> delegated`; the child's `ceiling` and
  `available` grow by exactly the same amount. Unit and precision must match.
  """
  @spec delegate(account(), account(), non_neg_integer()) ::
          {:ok, account(), account()} | {:error, reason()}
  def delegate(parent, child, quantity) do
    with :ok <- validate(parent),
         :ok <- validate(child),
         :ok <- valid_quantity(quantity),
         :ok <- compatible_allocations(parent, child),
         :ok <- enough(parent, :available, quantity),
         {:ok, parent} <- move_valid(parent, :available, :delegated, quantity),
         {:ok, child} <- grow_child(child, quantity) do
      {:ok, parent, child}
    end
  end

  @doc "Returns all currently free child quantity to its parent."
  @spec devolve(account(), account()) :: {:ok, account(), account()} | {:error, reason()}
  def devolve(parent, child), do: devolve(parent, child, amount(child, :available))

  @doc """
  Returns only free child quantity to its parent.

  Reserved and suspended amounts remain bound to their Attempt or Duty, and
  spent remains historical. Consequently `quantity` cannot exceed the child's
  `available` balance.
  """
  @spec devolve(account(), account(), non_neg_integer()) ::
          {:ok, account(), account()} | {:error, reason()}
  def devolve(parent, child, quantity) do
    with :ok <- validate(parent),
         :ok <- validate(child),
         :ok <- valid_quantity(quantity),
         :ok <- compatible_allocations(parent, child),
         :ok <- enough(parent, :delegated, quantity),
         :ok <- enough(child, :available, quantity),
         :ok <- enough(child, :ceiling, quantity),
         {:ok, parent} <- move_valid(parent, :delegated, :available, quantity),
         {:ok, child} <- shrink_child(child, quantity) do
      {:ok, parent, child}
    end
  end

  @doc """
  Checks a set of requested reservations against an account view.

  Requests use the canonical `%{meter_ref => non_neg_integer}` shape. A list of
  `%{meter_ref: ref, quantity: amount}` or `{ref, amount}` is also accepted at
  this pure boundary. The result is sorted by ref and suitable for a Decision.
  """
  @spec plan_reservations(map() | list() | nil, map() | list()) ::
          {:ok, [map()]} | {:error, reason()}
  def plan_reservations(requests, accounts) do
    with {:ok, requests} <- normalize_requests(requests),
         {:ok, index} <- account_index(accounts),
         :ok <- requests_fit(requests, index) do
      reservations =
        requests
        |> Enum.reject(fn {_ref, quantity} -> quantity == 0 end)
        |> Enum.map(fn {ref, quantity} ->
          account = Map.fetch!(index, ref)

          %{
            meter_ref: ref,
            quantity: quantity,
            unit: get(account, [:unit]),
            precision: get(account, [:precision], 0)
          }
        end)

      {:ok, reservations}
    end
  end

  @doc "Plans and applies several reservations to an account view atomically."
  @spec reserve_many(map() | list() | nil, map() | list()) ::
          {:ok, %{term() => account()}, [map()]} | {:error, reason()}
  def reserve_many(requests, accounts) do
    with {:ok, reservations} <- plan_reservations(requests, accounts),
         {:ok, index} <- account_index(accounts) do
      updated =
        Enum.reduce(reservations, index, fn reservation, acc ->
          ref = reservation.meter_ref
          {:ok, account} = reserve(Map.fetch!(acc, ref), reservation.quantity)
          Map.put(acc, ref, account)
        end)

      {:ok, updated, reservations}
    end
  end

  defp move(account, from, to, quantity) do
    with :ok <- validate(account),
         :ok <- valid_quantity(quantity),
         :ok <- enough(account, from, quantity) do
      move_valid(account, from, to, quantity)
    end
  end

  defp move_valid(account, from, to, quantity) do
    updated =
      account
      |> put_amount(from, amount(account, from) - quantity)
      |> put_amount(to, amount(account, to) + quantity)

    case validate(updated) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp grow_child(child, quantity) do
    updated =
      child
      |> put_amount(:ceiling, amount(child, :ceiling) + quantity)
      |> put_amount(:available, amount(child, :available) + quantity)

    case validate(updated) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp shrink_child(child, quantity) do
    updated =
      child
      |> put_amount(:ceiling, amount(child, :ceiling) - quantity)
      |> put_amount(:available, amount(child, :available) - quantity)

    case validate(updated) do
      :ok -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp enough(account, bucket, quantity) do
    if amount(account, bucket) >= quantity,
      do: :ok,
      else: {:error, {:insufficient_meter_quantity, bucket}}
  end

  defp compatible_allocations(parent, child) do
    same_unit? = get(parent, [:unit]) == get(child, [:unit])
    same_precision? = get(parent, [:precision], 0) == get(child, [:precision], 0)
    parent_ref = get(parent, [:ref, :meter_ref])
    child_ref = get(child, [:ref, :meter_ref])
    declared_parent_ref = get(child, [:parent_ref])

    distinct? = not present?(parent_ref) or not present?(child_ref) or parent_ref != child_ref

    correct_parent? =
      not present?(declared_parent_ref) or not present?(parent_ref) or
        declared_parent_ref == parent_ref

    if same_unit? and same_precision? and distinct? and correct_parent?,
      do: :ok,
      else: {:error, :incompatible_meter_allocations}
  end

  defp requests_fit(requests, index) do
    Enum.reduce_while(requests, :ok, fn {ref, quantity}, :ok ->
      case request_fits(ref, quantity, index) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp request_fits(ref, quantity, index) do
    with {:ok, account} <- fetch_account(index, ref),
         :ok <- validate_account_for_request(account, ref) do
      if amount(account, :available) >= quantity,
        do: :ok,
        else: {:error, {:insufficient_meter_quantity, ref}}
    end
  end

  defp fetch_account(index, ref) do
    case Map.fetch(index, ref) do
      {:ok, account} -> {:ok, account}
      :error -> {:error, {:unknown_meter, ref}}
    end
  end

  defp validate_account_for_request(account, ref) do
    case validate(account) do
      :ok -> :ok
      {:error, reason} -> {:error, {ref, reason}}
    end
  end

  defp normalize_requests(nil), do: {:ok, []}

  defp normalize_requests(requests) when is_map(requests) do
    requests
    |> Enum.to_list()
    |> normalize_request_pairs()
  end

  defp normalize_requests(requests) when is_list(requests) do
    requests
    |> Enum.map(fn
      {ref, quantity} ->
        {ref, quantity}

      request when is_map(request) ->
        {get(request, [:meter_ref, :ref]), get(request, [:quantity, :amount])}

      invalid ->
        {:invalid, invalid}
    end)
    |> normalize_request_pairs()
  end

  defp normalize_requests(_requests), do: {:error, :invalid_meter_requests}

  defp normalize_request_pairs(pairs) do
    invalid =
      Enum.find(pairs, fn
        {ref, quantity} -> not present?(ref) or not non_negative_integer?(quantity)
        _other -> true
      end)

    if invalid do
      {:error, {:invalid_meter_request, invalid}}
    else
      requests =
        pairs
        |> Enum.reduce(%{}, fn {ref, quantity}, acc ->
          Map.update(acc, ref, quantity, &(&1 + quantity))
        end)
        |> Enum.sort_by(fn {ref, _quantity} -> inspect(ref) end)

      {:ok, requests}
    end
  end

  defp account_index(accounts) when is_list(accounts) do
    build_account_index(accounts)
  end

  defp account_index(accounts) when is_map(accounts) do
    nested = get(accounts, [:accounts, :meter_accounts])

    cond do
      is_list(nested) -> build_account_index(nested)
      is_map(nested) -> account_index(nested)
      account_like?(accounts) -> build_account_index([accounts])
      true -> build_keyed_account_index(accounts)
    end
  end

  defp account_index(_accounts), do: {:error, :invalid_meter_accounts}

  defp build_account_index(accounts) do
    Enum.reduce_while(accounts, {:ok, %{}}, fn account, {:ok, index} ->
      ref = get(account, [:ref, :meter_ref])

      cond do
        not is_map(account) or not present?(ref) ->
          {:halt, {:error, :invalid_meter_account}}

        Map.has_key?(index, ref) ->
          {:halt, {:error, {:duplicate_meter_account, ref}}}

        true ->
          {:cont, {:ok, Map.put(index, ref, account)}}
      end
    end)
  end

  defp build_keyed_account_index(accounts) do
    Enum.reduce_while(accounts, {:ok, %{}}, fn
      {ref, account}, {:ok, index} when is_map(account) ->
        actual_ref = get(account, [:ref, :meter_ref], ref)

        if actual_ref == ref do
          {:cont, {:ok, Map.put(index, ref, account)}}
        else
          {:halt, {:error, {:meter_account_ref_mismatch, ref, actual_ref}}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_meter_accounts}}
    end)
  end

  defp account_like?(account) do
    has_key?(account, :ceiling) and Enum.any?(@buckets, &has_key?(account, &1))
  end

  defp valid_quantity(quantity) do
    if non_negative_integer?(quantity),
      do: :ok,
      else: {:error, :invalid_meter_quantity}
  end

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp amount(account, field), do: get(account, [field], 0)

  defp put_amount(account, field, value) do
    cond do
      Map.has_key?(account, field) ->
        Map.put(account, field, value)

      Map.has_key?(account, Atom.to_string(field)) ->
        Map.put(account, Atom.to_string(field), value)

      true ->
        Map.put(account, field, value)
    end
  end

  defp has_key?(map, field),
    do: Map.has_key?(map, field) or Map.has_key?(map, Atom.to_string(field))

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp get(map, fields, default \\ nil)

  defp get(map, fields, default) when is_map(map) do
    Enum.find_value(fields, default, fn field ->
      case fetch(map, field) do
        {:ok, nil} -> nil
        {:ok, value} -> {:found, value}
        :error -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      value -> value
    end
  end

  defp get(_other, _fields, default), do: default

  defp fetch(map, field) do
    case Map.fetch(map, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(field))
    end
  end
end
