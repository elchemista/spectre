defmodule Spectre.Inference.Usage do
  @moduledoc "Portable, monotonic usage counters for one inference attempt."

  @fields [:input_tokens, :output_tokens, :total_tokens, :cost, :duration_ms, :output_bytes]

  defstruct input_tokens: 0,
            output_tokens: 0,
            total_tokens: 0,
            cost: 0,
            duration_ms: 0,
            output_bytes: 0

  @type t :: %__MODULE__{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost: number(),
          duration_ms: non_neg_integer(),
          output_bytes: non_neg_integer()
        }

  @spec new(t() | map() | keyword() | nil) :: t()
  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = usage), do: validate!(usage)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs = atomize_known_keys(attrs)
    attrs |> Map.take(@fields) |> then(&struct(__MODULE__, &1)) |> validate!()
  end

  @spec merge(t(), t() | map() | keyword()) :: t()
  def merge(%__MODULE__{} = current, update) do
    update = new(update)

    Enum.reduce(@fields, current, fn field, acc ->
      Map.put(acc, field, max(Map.fetch!(acc, field), Map.fetch!(update, field)))
    end)
  end

  @spec add(t(), t() | map() | keyword()) :: t()
  def add(%__MODULE__{} = left, right) do
    right = new(right)

    Enum.reduce(@fields, left, fn field, acc ->
      Map.update!(acc, field, &(&1 + Map.fetch!(right, field)))
    end)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = usage), do: Map.from_struct(usage)

  @doc false
  @spec at_least?(t(), t() | map() | keyword()) :: boolean()
  def at_least?(%__MODULE__{} = usage, floor) do
    floor = new(floor)
    Enum.all?(@fields, &(Map.fetch!(usage, &1) >= Map.fetch!(floor, &1)))
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, :invalid_inference_usage}
  def validate(%__MODULE__{} = usage) do
    if valid?(usage), do: :ok, else: {:error, :invalid_inference_usage}
  end

  def validate(_usage), do: {:error, :invalid_inference_usage}

  defp validate!(%__MODULE__{} = usage) do
    if valid?(usage),
      do: usage,
      else: raise(ArgumentError, "inference usage must be non-negative")
  end

  defp valid?(usage) do
    Enum.all?(@fields, fn
      :cost -> is_number(usage.cost) and usage.cost >= 0
      field -> is_integer(Map.fetch!(usage, field)) and Map.fetch!(usage, field) >= 0
    end)
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(@fields, attrs, fn field, acc ->
      case Map.fetch(acc, Atom.to_string(field)) do
        {:ok, value} -> Map.put_new(acc, field, value)
        :error -> acc
      end
    end)
  end
end
