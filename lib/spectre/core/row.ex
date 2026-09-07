defmodule Spectre.Row do
  @moduledoc """
  Decidable summary of the governed dimensions touched by a consequence.

  Rows deliberately remain a small boolean vocabulary.  Domain-specific
  classes, targets and quantitative limits live in `Spectre.Surface` and
  `Spectre.Mandate`; a row only states which kinds of power are involved.
  """

  alias Spectre.Portable

  @schema_version 1
  @dimensions [:attempt, :observe, :read, :write, :disclose, :spend, :delegate, :govern, :present]
  @fields [:schema_version | @dimensions]

  defstruct schema_version: @schema_version,
            attempt: false,
            observe: false,
            read: false,
            write: false,
            disclose: false,
            spend: false,
            delegate: false,
            govern: false,
            present: false

  @type dimension ::
          :attempt
          | :observe
          | :read
          | :write
          | :disclose
          | :spend
          | :delegate
          | :govern
          | :present
  @type t :: %__MODULE__{
          schema_version: 1,
          attempt: boolean(),
          observe: boolean(),
          read: boolean(),
          write: boolean(),
          disclose: boolean(),
          spend: boolean(),
          delegate: boolean(),
          govern: boolean(),
          present: boolean()
        }

  @doc "Returns the fixed governed-dimension vocabulary."
  @spec known_dimensions() :: [dimension()]
  def known_dimensions, do: @dimensions

  @doc "Builds and validates an effect row. Omitted dimensions are `false`."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = row), do: row |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :row),
         attrs = Map.put_new(attrs, :schema_version, @schema_version),
         row = struct(__MODULE__, attrs),
         :ok <- validate_record(row) do
      {:ok, row}
    end
  end

  @doc "Validates an effect row without changing it."
  @spec validate(t() | map() | keyword()) :: :ok | {:error, term()}
  def validate(row) do
    case new(row) do
      {:ok, _row} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns true when every enabled dimension in `row` is enabled by `ceiling`.

  Both arguments may be structs, keyword lists or canonical maps. Malformed
  rows fail closed and return `false`; unknown keys are never ignored.
  """
  @spec subset?(t() | map() | keyword(), t() | map() | keyword()) :: boolean()
  def subset?(row, ceiling) do
    with {:ok, row} <- new(row),
         {:ok, ceiling} <- new(ceiling) do
      Enum.all?(@dimensions, fn dimension ->
        not Map.fetch!(row, dimension) or Map.fetch!(ceiling, dimension)
      end)
    else
      {:error, _reason} -> false
    end
  end

  @doc "Returns enabled dimensions in stable vocabulary order."
  @spec dimensions(t()) :: [dimension()]
  def dimensions(%__MODULE__{} = row),
    do: Enum.filter(@dimensions, &Map.fetch!(row, &1))

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = row), do: Portable.canonical_fields(row, @fields)

  @doc "Restores a row from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :row)

  @doc "Returns the stable digest of a row."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = row), do: row |> canonical() |> Portable.digest!()

  defp validate_record(%__MODULE__{} = row) do
    cond do
      row.schema_version !== @schema_version ->
        {:error, {:unsupported_row_schema_version, row.schema_version}}

      invalid = Enum.find(@dimensions, &(not is_boolean(Map.fetch!(row, &1)))) ->
        {:error, {:invalid_row_dimension, invalid, Map.fetch!(row, invalid)}}

      true ->
        :ok
    end
  end
end
