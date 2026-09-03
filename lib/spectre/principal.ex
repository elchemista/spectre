defmodule Spectre.Principal do
  @moduledoc """
  Portable identity named by a domain's genesis or later governance acts.

  A principal identifies a participant; it does not, by itself, grant any
  authority.  Authority is carried exclusively by mandates.
  """

  alias Spectre.Portable

  @schema_version 1
  @fields [:schema_version, :ref, :kind, :display_name, :attributes]
  @kinds [:human, :organization, :service, :agent, :system]

  @enforce_keys [:schema_version, :ref, :kind, :attributes]
  defstruct schema_version: @schema_version,
            ref: nil,
            kind: nil,
            display_name: nil,
            attributes: %{}

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          kind: :human | :organization | :service | :agent | :system,
          display_name: String.t() | nil,
          attributes: map()
        }

  @doc "Builds and validates a principal."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = principal), do: principal |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :principal),
         attrs = Map.put_new(attrs, :schema_version, @schema_version),
         attrs = Map.put_new(attrs, :attributes, %{}),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         principal = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(principal),
         :ok <- Portable.validate(canonical(principal)) do
      {:ok, principal}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = principal) do
    %{
      "schema_version" => principal.schema_version,
      "ref" => principal.ref,
      "kind" => principal.kind,
      "display_name" => principal.display_name,
      "attributes" => principal.attributes
    }
  end

  @doc "Restores a principal from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :principal)

  @doc "Returns the stable digest of the complete canonical record."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = principal), do: principal |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = principal),
    do: Portable.content_ref!(:principal, content(principal))

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:principal, ref, content(attrs))

  defp content(%__MODULE__{} = principal), do: principal |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    %{
      "schema_version" => Map.get(attrs, :schema_version, @schema_version),
      "kind" => Map.get(attrs, :kind),
      "display_name" => Map.get(attrs, :display_name),
      "attributes" => Map.get(attrs, :attributes, %{})
    }
  end

  defp validate_record(%__MODULE__{} = principal) do
    cond do
      principal.schema_version != @schema_version ->
        {:error, {:unsupported_principal_schema_version, principal.schema_version}}

      principal.kind not in @kinds ->
        {:error, {:invalid_principal_kind, principal.kind}}

      not (is_nil(principal.display_name) or is_binary(principal.display_name)) ->
        {:error, {:invalid_principal_display_name, Portable.shape(principal.display_name)}}

      not is_map(principal.attributes) or is_struct(principal.attributes) ->
        {:error, {:invalid_principal_attributes, Portable.shape(principal.attributes)}}

      true ->
        Portable.validate_ref(principal.ref, :ref)
    end
  end
end
