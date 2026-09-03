defmodule Spectre.HostProfile do
  @moduledoc """
  Attested statement about the deployment boundary in force for a domain.

  The profile records what the deployment claims (`:mediated`, `:isolated` or
  `:development`) and the assumptions behind that claim.  Recording it does
  not prove that the physical isolation is real.
  """

  alias Spectre.Portable

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :revision,
    :mode,
    :attestation_ref,
    :assumptions,
    :declared_at
  ]
  @modes [:mediated, :isolated, :development]

  @enforce_keys [
    :schema_version,
    :ref,
    :revision,
    :mode,
    :attestation_ref,
    :assumptions,
    :declared_at
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            revision: 1,
            mode: nil,
            attestation_ref: nil,
            assumptions: [],
            declared_at: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          revision: pos_integer(),
          mode: :mediated | :isolated | :development,
          attestation_ref: String.t(),
          assumptions: [term()],
          declared_at: integer()
        }

  @doc "Builds and validates a host profile."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = profile), do: profile |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :host_profile),
         attrs =
           attrs
           |> Map.put_new(:schema_version, @schema_version)
           |> Map.put_new(:revision, 1)
           |> Map.put_new(:assumptions, []),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         profile = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(profile),
         :ok <- Portable.validate(canonical(profile)) do
      {:ok, profile}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = profile) do
    %{
      "schema_version" => profile.schema_version,
      "ref" => profile.ref,
      "revision" => profile.revision,
      "mode" => profile.mode,
      "attestation_ref" => profile.attestation_ref,
      "assumptions" => profile.assumptions,
      "declared_at" => profile.declared_at
    }
  end

  @doc "Restores a host profile from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :host_profile)

  @doc "Returns the stable digest of the complete canonical record."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = profile), do: profile |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = profile),
    do: Portable.content_ref!(:host_profile, content(profile))

  defp resolve_ref(ref, attrs),
    do: Portable.resolve_content_ref(:host_profile, ref, content(attrs))

  defp content(%__MODULE__{} = profile), do: profile |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    %{
      "schema_version" => Map.get(attrs, :schema_version, @schema_version),
      "revision" => Map.get(attrs, :revision, 1),
      "mode" => Map.get(attrs, :mode),
      "attestation_ref" => Map.get(attrs, :attestation_ref),
      "assumptions" => Map.get(attrs, :assumptions, []),
      "declared_at" => Map.get(attrs, :declared_at)
    }
  end

  defp validate_record(%__MODULE__{} = profile) do
    cond do
      profile.schema_version != @schema_version ->
        {:error, {:unsupported_host_profile_schema_version, profile.schema_version}}

      not is_integer(profile.revision) or profile.revision <= 0 ->
        {:error, {:invalid_host_profile_revision, profile.revision}}

      profile.mode not in @modes ->
        {:error, {:invalid_host_profile_mode, profile.mode}}

      not is_list(profile.assumptions) ->
        {:error, {:invalid_host_profile_assumptions, Portable.shape(profile.assumptions)}}

      not is_integer(profile.declared_at) ->
        {:error, {:invalid_host_profile_declared_at, Portable.shape(profile.declared_at)}}

      true ->
        with :ok <- Portable.validate_ref(profile.ref, :ref),
             :ok <- Portable.validate_ref(profile.attestation_ref, :attestation_ref) do
          :ok
        end
    end
  end
end
