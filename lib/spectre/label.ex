defmodule Spectre.Label do
  @moduledoc """
  Canonical information constraint with an explicit owner.

  Spectre does not interpret `value` or impose a label taxonomy. The stable
  reference binds that portable value to the principal which may authorize its
  removal.
  """

  alias Spectre.Portable

  @schema_version 1
  @fields [:schema_version, :ref, :owner_ref, :value]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            ref: nil,
            owner_ref: nil,
            value: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          owner_ref: String.t(),
          value: term()
        }

  @doc "Builds a canonical, content-addressed label."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = label), do: label |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :label),
         attrs <- Map.put_new(attrs, :schema_version, @schema_version),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         label = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate(label),
         :ok <- Portable.validate(canonical(label)) do
      {:ok, label}
    end
  end

  @doc "Normalizes, de-duplicates and orders labels by stable reference."
  @spec normalize_many(term()) :: {:ok, [t()]} | {:error, term()}
  def normalize_many(labels) when is_list(labels) do
    Enum.reduce_while(labels, {:ok, []}, fn value, {:ok, normalized} ->
      case new(value) do
        {:ok, label} -> {:cont, {:ok, [label | normalized]}}
        {:error, reason} -> {:halt, {:error, {:invalid_label, reason}}}
      end
    end)
    |> case do
      {:ok, labels} ->
        labels = labels |> Enum.uniq_by(& &1.ref) |> Enum.sort_by(& &1.ref)
        {:ok, labels}

      {:error, _reason} = error ->
        error
    end
  end

  def normalize_many(_labels), do: {:error, :invalid_labels}

  @doc "Returns the plain, string-keyed representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = label) do
    %{
      "schema_version" => label.schema_version,
      "ref" => label.ref,
      "owner_ref" => label.owner_ref,
      "value" => label.value
    }
  end

  @doc "Restores a label and verifies its content reference."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value), do: new(value)

  @doc "Returns the stable digest of the complete label."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = label), do: label |> canonical() |> Portable.digest!()

  @doc "Returns the reference derived from owner and value."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = label), do: Portable.content_ref!(:label, content(label))

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:label, ref, content(attrs))

  defp content(%__MODULE__{} = label), do: label |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    %{
      "schema_version" => Map.get(attrs, :schema_version, @schema_version),
      "owner_ref" => Map.get(attrs, :owner_ref),
      "value" => Map.get(attrs, :value)
    }
  end

  defp validate(%__MODULE__{} = label) do
    cond do
      label.schema_version != @schema_version ->
        {:error, {:unsupported_label_schema_version, label.schema_version}}

      is_nil(label.value) ->
        {:error, :missing_label_value}

      true ->
        with :ok <- Portable.validate_content_ref(label.ref, :label, :ref),
             :ok <- Portable.validate_ref(label.owner_ref, :owner_ref) do
          Portable.validate(label.value)
        end
    end
  end
end
