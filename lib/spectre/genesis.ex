defmodule Spectre.Genesis do
  @moduledoc """
  Externally attested root of a governed domain.

  Genesis names the initial principals, root mandates, constitution, governed
  surface and host profile.  It is deliberately not authorized by an internal
  Act: its attestation is the visible external trust boundary. Its `ref` is an
  externally assigned trust-anchor identifier, rather than a content address;
  this is the one deliberate exception that breaks the Genesis/root-Mandate
  reference cycle. `content_ref/1` remains available for signing and auditing
  the exact document.
  """

  require Spectre.Portable

  alias Spectre.Portable

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :domain_ref,
    :principal_refs,
    :root_mandate_refs,
    :constitution_ref,
    :surface_ref,
    :surface_revision,
    :host_profile_ref,
    :emergency_mandate_ref,
    :issued_at,
    :attestation_ref
  ]

  @enforce_keys [
    :schema_version,
    :ref,
    :domain_ref,
    :principal_refs,
    :root_mandate_refs,
    :constitution_ref,
    :surface_ref,
    :surface_revision,
    :host_profile_ref,
    :issued_at,
    :attestation_ref
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            domain_ref: nil,
            principal_refs: [],
            root_mandate_refs: [],
            constitution_ref: nil,
            surface_ref: nil,
            surface_revision: nil,
            host_profile_ref: nil,
            emergency_mandate_ref: nil,
            issued_at: nil,
            attestation_ref: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          domain_ref: String.t(),
          principal_refs: [String.t()],
          root_mandate_refs: [String.t()],
          constitution_ref: String.t(),
          surface_ref: String.t(),
          surface_revision: non_neg_integer(),
          host_profile_ref: String.t(),
          emergency_mandate_ref: String.t() | nil,
          issued_at: integer(),
          attestation_ref: String.t()
        }

  @doc "Builds and validates a genesis record."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = genesis), do: genesis |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :genesis),
         attrs <- defaults(attrs),
         {:ok, principals} <-
           Portable.normalize_refs(Map.fetch!(attrs, :principal_refs), :principal_refs),
         {:ok, mandates} <-
           Portable.normalize_refs(Map.fetch!(attrs, :root_mandate_refs), :root_mandate_refs),
         attrs =
           attrs
           |> Map.put(:principal_refs, principals)
           |> Map.put(:root_mandate_refs, mandates),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         genesis = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(genesis),
         :ok <- Portable.validate(canonical(genesis)) do
      {:ok, genesis}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = genesis), do: Portable.canonical_fields(genesis, @fields)

  @doc "Restores genesis from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :genesis)

  @doc "Returns the stable digest of the complete genesis record."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = genesis), do: genesis |> canonical() |> Portable.digest!()

  @doc "Returns a content-derived attestation reference, independent of the trust-anchor `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = genesis),
    do: Portable.content_ref!(:genesis, content(genesis))

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:principal_refs, [])
    |> Map.put_new(:root_mandate_refs, [])
    |> Map.put_new(:emergency_mandate_ref, nil)
  end

  defp resolve_ref(ref, _attrs) do
    with :ok <- Portable.validate_ref(ref, :ref), do: {:ok, ref}
  end

  defp content(%__MODULE__{} = genesis), do: genesis |> canonical() |> Map.delete("ref")

  defp validate_record(%__MODULE__{} = genesis) do
    cond do
      genesis.schema_version !== @schema_version ->
        {:error, {:unsupported_genesis_schema_version, genesis.schema_version}}

      not Portable.is_non_negative_integer(genesis.surface_revision) ->
        {:error, {:invalid_genesis_surface_revision, genesis.surface_revision}}

      not is_integer(genesis.issued_at) ->
        {:error, {:invalid_genesis_issued_at, Portable.shape(genesis.issued_at)}}

      true ->
        with :ok <- Portable.validate_ref(genesis.ref, :ref),
             :ok <- Portable.validate_ref(genesis.domain_ref, :domain_ref),
             :ok <- Portable.validate_refs(genesis.principal_refs, :principal_refs),
             :ok <- Portable.validate_refs(genesis.root_mandate_refs, :root_mandate_refs),
             :ok <- Portable.validate_ref(genesis.constitution_ref, :constitution_ref),
             :ok <- Portable.validate_ref(genesis.surface_ref, :surface_ref),
             :ok <- Portable.validate_ref(genesis.host_profile_ref, :host_profile_ref),
             :ok <-
               Portable.validate_optional_ref(
                 genesis.emergency_mandate_ref,
                 :emergency_mandate_ref
               ) do
          Portable.validate_ref(genesis.attestation_ref, :attestation_ref)
        end
    end
  end
end
