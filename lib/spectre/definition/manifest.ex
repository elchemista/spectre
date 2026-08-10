defmodule Spectre.Definition.Manifest do
  @moduledoc """
  Sealed Manifest V2 for one canonical Definition.

  A Manifest binds the Definition Ref, its effective Authority Envelope, its
  Execution Closure, and the exact component-contract interpretation used at
  publication time. Integrity is content-addressed; publisher trust, approval,
  revocation, and current authority remain separate host concerns.
  """

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.ContractRegistry
  alias Spectre.Definition.Ref
  alias Spectre.Execution.Closure

  @schema_version 1
  @contract_version 2

  @enforce_keys [
    :schema_version,
    :contract_version,
    :definition_ref,
    :authority,
    :execution_closure,
    :component_contracts,
    :parent_refs,
    :publisher_ref,
    :provenance_refs,
    :receipt_refs
  ]
  defstruct schema_version: @schema_version,
            contract_version: @contract_version,
            definition_ref: nil,
            authority: nil,
            execution_closure: nil,
            component_contracts: [],
            parent_refs: [],
            publisher_ref: nil,
            provenance_refs: [],
            receipt_refs: []

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          contract_version: pos_integer(),
          definition_ref: Ref.t(),
          authority: Envelope.t(),
          execution_closure: Closure.t(),
          component_contracts: [map()],
          parent_refs: [Ref.t()],
          publisher_ref: String.t() | nil,
          provenance_refs: [String.t()],
          receipt_refs: [String.t()]
        }

  @doc "Returns the Manifest schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the mandatory reflective Stack/Manifest contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc "Builds and seals a Manifest for a canonical Definition."
  @spec new(Canonical.t(), Envelope.t(), Closure.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def new(%Canonical{} = canonical, %Envelope{} = authority, %Closure{} = closure, opts \\ [])
      when is_list(opts) do
    registry = Keyword.get(opts, :component_registry, ContractRegistry.default())

    with {:ok, contracts} <- ContractRegistry.snapshot(registry, canonical) do
      new(%{
        schema_version: @schema_version,
        contract_version: @contract_version,
        definition_ref: Canonical.ref(canonical),
        authority: authority,
        execution_closure: closure,
        component_contracts: contracts,
        parent_refs: Keyword.get(opts, :parent_refs, []),
        publisher_ref: Keyword.get(opts, :publisher_ref),
        provenance_refs: Keyword.get(opts, :provenance_refs, []),
        receipt_refs: Keyword.get(opts, :receipt_refs, [])
      })
    end
  end

  @doc "Builds and validates a Manifest from already normalized fields."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = manifest), do: manifest |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         :ok <- validate_versions(attrs),
         {:ok, definition_ref} <- normalize_ref(Map.get(attrs, :definition_ref)),
         {:ok, authority} <- normalize_authority(Map.get(attrs, :authority)),
         {:ok, closure} <- normalize_closure(Map.get(attrs, :execution_closure)),
         {:ok, contracts} <- normalize_contracts(Map.get(attrs, :component_contracts)),
         {:ok, parents} <- normalize_parent_refs(Map.get(attrs, :parent_refs, [])),
         :ok <- validate_optional_ref(Map.get(attrs, :publisher_ref), :publisher_ref),
         {:ok, provenance} <-
           normalize_string_refs(Map.get(attrs, :provenance_refs, []), :provenance_refs),
         {:ok, receipts} <-
           normalize_string_refs(Map.get(attrs, :receipt_refs, []), :receipt_refs) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         contract_version: @contract_version,
         definition_ref: definition_ref,
         authority: authority,
         execution_closure: closure,
         component_contracts: contracts,
         parent_refs: parents,
         publisher_ref: Map.get(attrs, :publisher_ref),
         provenance_refs: provenance,
         receipt_refs: receipts
       }}
    end
  end

  def new(value), do: {:error, {:invalid_definition_manifest, shape(value)}}

  @doc "Builds a Manifest or raises with its stable validation reason."
  @spec new!(Canonical.t(), Envelope.t(), Closure.t(), keyword()) :: t()
  def new!(canonical, authority, closure, opts \\ []) do
    case new(canonical, authority, closure, opts) do
      {:ok, manifest} -> manifest
      {:error, reason} -> raise ArgumentError, "invalid Definition Manifest: #{inspect(reason)}"
    end
  end

  @doc "Returns the portable Manifest representation."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = manifest) do
    %{
      "schema_version" => manifest.schema_version,
      "contract_version" => manifest.contract_version,
      "definition_ref" => Ref.to_string(manifest.definition_ref),
      "definition_canonicalization_version" => manifest.definition_ref.canonicalization_version,
      "definition_contract_version" => manifest.definition_ref.contract_version,
      "authority" => Envelope.to_data(manifest.authority),
      "execution_closure" => Closure.to_data(manifest.execution_closure),
      "component_contracts" =>
        Enum.map(manifest.component_contracts, &contract_snapshot_to_data/1),
      "parent_refs" => Enum.map(manifest.parent_refs, &Ref.to_string/1),
      "publisher_ref" => manifest.publisher_ref,
      "provenance_refs" => manifest.provenance_refs,
      "receipt_refs" => manifest.receipt_refs
    }
  end

  @doc "Restores a Manifest from decoded canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{
        "schema_version" => schema_version,
        "contract_version" => contract_version,
        "definition_ref" => definition_ref,
        "definition_canonicalization_version" => canonicalization_version,
        "definition_contract_version" => definition_contract_version,
        "authority" => authority,
        "execution_closure" => closure,
        "component_contracts" => component_contracts,
        "parent_refs" => parent_refs,
        "publisher_ref" => publisher_ref,
        "provenance_refs" => provenance_refs,
        "receipt_refs" => receipt_refs
      }) do
    with {:ok, definition_ref} <-
           Ref.parse(definition_ref,
             canonicalization_version: canonicalization_version,
             contract_version: definition_contract_version
           ),
         {:ok, authority} <- Envelope.from_data(authority),
         {:ok, closure} <- Closure.from_data(closure),
         {:ok, component_contracts} <- contracts_from_data(component_contracts),
         {:ok, parent_refs} <-
           parse_refs(parent_refs, canonicalization_version, definition_contract_version) do
      new(%{
        schema_version: schema_version,
        contract_version: contract_version,
        definition_ref: definition_ref,
        authority: authority,
        execution_closure: closure,
        component_contracts: component_contracts,
        parent_refs: parent_refs,
        publisher_ref: publisher_ref,
        provenance_refs: provenance_refs,
        receipt_refs: receipt_refs
      })
    end
  end

  def from_data(value), do: {:error, {:invalid_definition_manifest_data, shape(value)}}

  @doc "Encodes a Manifest into portable canonical bytes."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = manifest), do: manifest |> to_data() |> Value.encode()

  @doc "Encodes a Manifest or raises on invalid canonical data."
  @spec encode!(t()) :: binary()
  def encode!(%__MODULE__{} = manifest), do: manifest |> to_data() |> Value.encode!()

  @doc "Decodes and validates canonical Manifest bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_definition_manifest_binary, shape(value)}}

  @doc "Returns the content digest of the sealed Manifest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = manifest), do: manifest |> to_data() |> Value.digest!()

  @doc """
  Verifies the Definition binding and its exact component-contract snapshot.
  """
  @spec verify(t(), Canonical.t(), ContractRegistry.t()) :: :ok | {:error, term()}
  def verify(
        %__MODULE__{} = manifest,
        %Canonical{} = canonical,
        registry \\ ContractRegistry.default()
      ) do
    with :ok <- Ref.verify(manifest.definition_ref, canonical),
         :ok <-
           ContractRegistry.verify_snapshot(registry, canonical, manifest.component_contracts),
         {:ok, ^manifest} <- new(manifest) do
      :ok
    else
      {:ok, rebuilt} ->
        {:error, {:definition_manifest_integrity_mismatch, digest(manifest), digest(rebuilt)}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec validate_keys(map()) :: :ok | {:error, term()}
  defp validate_keys(attrs) do
    allowed = [
      :schema_version,
      :contract_version,
      :definition_ref,
      :authority,
      :execution_closure,
      :component_contracts,
      :parent_refs,
      :publisher_ref,
      :provenance_refs,
      :receipt_refs
    ]

    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_definition_manifest_fields, Enum.sort(unknown)}}
    end
  end

  @spec validate_versions(map()) :: :ok | {:error, term()}
  defp validate_versions(attrs) do
    schema = Map.get(attrs, :schema_version, @schema_version)
    contract = Map.get(attrs, :contract_version, @contract_version)

    cond do
      schema != @schema_version ->
        {:error, {:unsupported_definition_manifest_schema, schema}}

      contract != @contract_version ->
        {:error, {:unsupported_definition_manifest_contract, contract}}

      true ->
        :ok
    end
  end

  @spec normalize_ref(term()) :: {:ok, Ref.t()} | {:error, term()}
  defp normalize_ref(%Ref{} = ref) do
    if Ref.valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_manifest_definition_ref, ref}}
  end

  defp normalize_ref(value), do: {:error, {:invalid_manifest_definition_ref, value}}

  @spec normalize_authority(term()) :: {:ok, Envelope.t()} | {:error, term()}
  defp normalize_authority(%Envelope{} = authority), do: Envelope.new(authority)
  defp normalize_authority(value), do: {:error, {:invalid_manifest_authority, shape(value)}}

  @spec normalize_closure(term()) :: {:ok, Closure.t()} | {:error, term()}
  defp normalize_closure(%Closure{} = closure), do: Closure.new(closure)
  defp normalize_closure(value), do: {:error, {:invalid_manifest_execution_closure, shape(value)}}

  @spec normalize_contracts(term()) :: {:ok, [map()]} | {:error, term()}
  defp normalize_contracts(contracts) when is_list(contracts) and contracts != [] do
    if Enum.all?(contracts, &valid_contract_snapshot?/1) do
      {:ok, Enum.sort_by(contracts, &{&1.schema_ref, &1.component_type})}
    else
      {:error, :invalid_component_contract_snapshot}
    end
  end

  defp normalize_contracts(_value), do: {:error, :incomplete_component_contract_snapshot}

  @spec valid_contract_snapshot?(term()) :: boolean()
  defp valid_contract_snapshot?(%{
         component_type: type,
         schema_ref: schema_ref,
         criticality: criticality,
         contract_version: version,
         status: status
       }) do
    valid_contract_type?(type) and valid_contract_ref?(schema_ref) and
      valid_contract_criticality?(criticality) and valid_contract_version?(status, version)
  end

  defp valid_contract_snapshot?(_value), do: false

  @spec valid_contract_type?(term()) :: boolean()
  defp valid_contract_type?(type) when is_atom(type), do: not is_nil(type)
  defp valid_contract_type?(type) when is_binary(type), do: type != ""
  defp valid_contract_type?(_type), do: false

  @spec valid_contract_ref?(term()) :: boolean()
  defp valid_contract_ref?(schema_ref), do: is_binary(schema_ref) and schema_ref != ""

  @spec valid_contract_criticality?(term()) :: boolean()
  defp valid_contract_criticality?(criticality),
    do: criticality in [:must_understand, :advisory, :descriptive]

  @spec valid_contract_version?(term(), term()) :: boolean()
  defp valid_contract_version?(:understood, version), do: is_integer(version) and version > 0
  defp valid_contract_version?(:opaque, version), do: is_nil(version)
  defp valid_contract_version?(_status, _version), do: false

  @spec contract_snapshot_to_data(map()) :: map()
  defp contract_snapshot_to_data(contract) do
    %{
      "component_type" => contract.component_type,
      "schema_ref" => contract.schema_ref,
      "criticality" => Atom.to_string(contract.criticality),
      "contract_version" => contract.contract_version,
      "status" => Atom.to_string(contract.status)
    }
  end

  @spec contracts_from_data(term()) :: {:ok, [map()]} | {:error, term()}
  defp contracts_from_data(contracts) when is_list(contracts) do
    Enum.reduce_while(contracts, {:ok, []}, fn contract, {:ok, decoded} ->
      case contract_from_data(contract) do
        {:ok, contract} -> {:cont, {:ok, [contract | decoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      {:error, _reason} = error -> error
    end
  end

  defp contracts_from_data(value),
    do: {:error, {:invalid_component_contract_snapshot, shape(value)}}

  @spec contract_from_data(term()) :: {:ok, map()} | {:error, term()}
  defp contract_from_data(%{
         "component_type" => component_type,
         "schema_ref" => schema_ref,
         "criticality" => criticality,
         "contract_version" => contract_version,
         "status" => status
       }) do
    with {:ok, criticality} <- criticality_from_data(criticality),
         {:ok, status} <- contract_status_from_data(status) do
      {:ok,
       %{
         component_type: component_type,
         schema_ref: schema_ref,
         criticality: criticality,
         contract_version: contract_version,
         status: status
       }}
    end
  end

  defp contract_from_data(_value), do: {:error, :invalid_component_contract_snapshot}

  @spec criticality_from_data(term()) ::
          {:ok, :must_understand | :advisory | :descriptive} | {:error, term()}
  defp criticality_from_data("must_understand"), do: {:ok, :must_understand}
  defp criticality_from_data("advisory"), do: {:ok, :advisory}
  defp criticality_from_data("descriptive"), do: {:ok, :descriptive}
  defp criticality_from_data(value), do: {:error, {:invalid_component_criticality, value}}

  @spec contract_status_from_data(term()) :: {:ok, :understood | :opaque} | {:error, term()}
  defp contract_status_from_data("understood"), do: {:ok, :understood}
  defp contract_status_from_data("opaque"), do: {:ok, :opaque}

  defp contract_status_from_data(value),
    do: {:error, {:invalid_component_contract_status, value}}

  @spec normalize_parent_refs(term()) :: {:ok, [Ref.t()]} | {:error, term()}
  defp normalize_parent_refs(refs) when is_list(refs) do
    if Enum.all?(refs, &Ref.valid?/1) do
      {:ok, refs |> Enum.uniq_by(&Ref.to_string/1) |> Enum.sort_by(&Ref.to_string/1)}
    else
      {:error, :invalid_definition_parent_refs}
    end
  end

  defp normalize_parent_refs(value),
    do: {:error, {:invalid_definition_parent_refs, shape(value)}}

  @spec validate_optional_ref(term(), atom()) :: :ok | {:error, term()}
  defp validate_optional_ref(nil, _field), do: :ok
  defp validate_optional_ref(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_optional_ref(value, field), do: {:error, {:invalid_manifest_ref, field, value}}

  @spec normalize_string_refs(term(), atom()) :: {:ok, [String.t()]} | {:error, term()}
  defp normalize_string_refs(refs, _field) when is_list(refs) do
    if Enum.all?(refs, &(is_binary(&1) and &1 != "")),
      do: {:ok, refs |> Enum.uniq() |> Enum.sort()},
      else: {:error, :invalid_manifest_refs}
  end

  defp normalize_string_refs(value, field),
    do: {:error, {:invalid_manifest_refs, field, shape(value)}}

  @spec parse_refs(term(), pos_integer(), pos_integer()) ::
          {:ok, [Ref.t()]} | {:error, term()}
  defp parse_refs(refs, canonicalization_version, contract_version) when is_list(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn value, {:ok, parsed} ->
      case Ref.parse(value,
             canonicalization_version: canonicalization_version,
             contract_version: contract_version
           ) do
        {:ok, ref} -> {:cont, {:ok, [ref | parsed]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_refs(value, _canonicalization_version, _contract_version),
    do: {:error, {:invalid_definition_parent_refs, shape(value)}}

  @spec shape(term()) :: atom()
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
