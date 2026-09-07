defmodule Spectre.Foundation do
  @moduledoc """
  Pure assembly of the explicit records used to bootstrap a Domain.

  `new/2` derives Genesis links from supplied records, then validates the bundle
  through the same fold and structural checks as Domain bootstrap. It returns
  ordinary keyword options for `Spectre.start_domain/3` or a Domain child spec;
  there is no additional runtime container or owner.

  Supply all six keys: `:genesis`, `:constitution`, `:principals`, `:root_mandates`,
  `:surface` and `:host_profile`. Genesis metadata must explicitly name `:ref`,
  `:issued_at`, `:attestation_ref` and `:emergency_mandate_ref` (use `nil` for no
  emergency Mandate). The remaining Genesis references are derived, never
  copied from caller overrides. Root Mandates still name the host-chosen Genesis
  anchor in their `source_ref`; their content references are not that anchor.

  This builder chooses no Principal, Mandate, expiry, Conditions, Meter, Duty
  route, clock, secret or verifier. Existing record constructors validate the
  supplied values. A valid bundle is **not externally recognized authority**:
  the application must obtain the real attestation and supply its independent
  `:genesis_verifier` at boot. No verifier callback or I/O runs here. The preview
  uses the explicit Genesis issue time; boot revalidates at its trusted time.
  """

  alias Spectre.{Constitution, Genesis, Portable}
  alias Spectre.Domain.Bootstrap

  @fields [:genesis, :constitution, :principals, :root_mandates, :surface, :host_profile]
  @metadata [:ref, :issued_at, :attestation_ref, :emergency_mandate_ref]

  @doc "Builds bootstrap options without supplying or recognizing authority on the host's behalf."
  @spec new(String.t(), map() | keyword()) :: {:ok, keyword()} | {:error, term()}
  def new(domain_ref, attrs) do
    with :ok <- Portable.validate_ref(domain_ref, :domain_ref),
         {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :foundation),
         :ok <- required(attrs, @fields),
         {:ok, metadata} <-
           Portable.normalize_attrs(attrs.genesis, @metadata, :foundation_genesis),
         :ok <- required(metadata, @metadata),
         {:ok, records} <- Bootstrap.records(Map.to_list(attrs)),
         {:ok, constitution_ref} <- Constitution.ref(records.constitution),
         {:ok, genesis} <-
           Genesis.new(
             Map.merge(metadata, %{
               domain_ref: domain_ref,
               principal_refs: Enum.map(records.principals, & &1.ref),
               root_mandate_refs: Enum.map(records.root_mandates, & &1.ref),
               constitution_ref: constitution_ref,
               surface_ref: records.surface.ref,
               surface_revision: records.surface.revision,
               host_profile_ref: records.host_profile.ref
             })
           ),
         options = records |> Map.put(:genesis, genesis) |> Map.to_list(),
         :ok <- Bootstrap.validate(domain_ref, options, genesis.issued_at) do
      {:ok, options}
    end
  end

  defp required(attrs, fields) do
    case Enum.reject(fields, &Map.has_key?(attrs, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_foundation_fields, missing}}
    end
  end
end
