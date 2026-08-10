defmodule Spectre.Definition.Canonical do
  @moduledoc """
  Portable, immutable envelope for declared Spectre behavior.

  A canonical Definition contains a small versioned header and typed
  components. It is the single input to Definition identity and deterministic
  projections; compiled Agent and Skill definitions enter this representation
  through `lower/2`.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition
  alias Spectre.Definition.Canonical.Lowerer
  alias Spectre.Definition.Component
  alias Spectre.Definition.Ref

  @canonicalization_version 1
  @contract_version 1
  @digest_algorithm :sha256
  @kinds [:agent, :skill]
  @origins [:compiled, :runtime]

  @enforce_keys [
    :canonicalization_version,
    :contract_version,
    :digest_algorithm,
    :kind,
    :id,
    :declared_version,
    :origin,
    :components
  ]
  defstruct canonicalization_version: @canonicalization_version,
            contract_version: @contract_version,
            digest_algorithm: @digest_algorithm,
            kind: nil,
            id: nil,
            declared_version: nil,
            origin: nil,
            components: []

  @type t :: %__MODULE__{
          canonicalization_version: pos_integer(),
          contract_version: pos_integer(),
          digest_algorithm: :sha256,
          kind: :agent | :skill,
          id: term(),
          declared_version: term(),
          origin: :compiled | :runtime,
          components: [Component.t()]
        }

  @doc "Returns the current canonical Definition schema version."
  @spec canonicalization_version() :: pos_integer()
  def canonicalization_version, do: @canonicalization_version

  @doc "Returns the current canonical Definition contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc "Builds and validates a canonical Definition envelope."
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:canonicalization_version, @canonicalization_version)
      |> Map.put_new(:contract_version, @contract_version)
      |> Map.put_new(:digest_algorithm, @digest_algorithm)

    canonical = struct(__MODULE__, Map.take(attrs, fields()))

    with :ok <- validate_header(canonical),
         {:ok, components} <- normalize_components(canonical.components),
         canonical = %{canonical | components: components},
         :ok <- validate_portable(canonical) do
      {:ok, canonical}
    end
  end

  def new(value), do: {:error, {:invalid_canonical_definition, shape(value)}}

  @doc "Builds a canonical Definition or raises with its stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, canonical} ->
        canonical

      {:error, reason} ->
        raise ArgumentError, "invalid canonical Definition: #{inspect(reason)}"
    end
  end

  @doc """
  Lowers a compiled `Spectre.Definition` or DSL module into the canonical IR.
  """
  @spec lower(module() | Definition.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def lower(source, opts \\ []), do: Lowerer.lower(source, opts)

  @doc "Lowers a compiled Definition or raises with its stable failure reason."
  @spec lower!(module() | Definition.t(), keyword()) :: t()
  def lower!(source, opts \\ []) do
    case lower(source, opts) do
      {:ok, canonical} -> canonical
      {:error, reason} -> raise ArgumentError, "cannot lower Definition: #{inspect(reason)}"
    end
  end

  @doc "Returns the portable envelope used for encoding and projections."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = canonical) do
    %{
      "canonicalization_version" => canonical.canonicalization_version,
      "contract_version" => canonical.contract_version,
      "digest_algorithm" => canonical.digest_algorithm,
      "kind" => canonical.kind,
      "id" => canonical.id,
      "declared_version" => canonical.declared_version,
      "origin" => canonical.origin,
      "components" => Enum.map(canonical.components, &Component.to_data/1)
    }
  end

  @doc "Restores and validates an envelope from portable decoded data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{
        "canonicalization_version" => canonicalization_version,
        "contract_version" => contract_version,
        "digest_algorithm" => digest_algorithm,
        "kind" => kind,
        "id" => id,
        "declared_version" => declared_version,
        "origin" => origin,
        "components" => component_data
      })
      when is_list(component_data) do
    with {:ok, components} <- decode_components(component_data) do
      new(
        canonicalization_version: canonicalization_version,
        contract_version: contract_version,
        digest_algorithm: digest_algorithm,
        kind: kind,
        id: id,
        declared_version: declared_version,
        origin: origin,
        components: components
      )
    end
  end

  def from_data(value), do: {:error, {:invalid_canonical_definition_data, shape(value)}}

  @doc "Encodes a Definition into canonical bytes."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = canonical), do: canonical |> to_data() |> Value.encode()

  @doc "Encodes a Definition or raises on an invalid envelope."
  @spec encode!(t()) :: binary()
  def encode!(%__MODULE__{} = canonical), do: canonical |> to_data() |> Value.encode!()

  @doc "Decodes and validates canonical Definition bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_canonical_definition_binary, shape(value)}}

  @doc "Returns the stable lowercase SHA-256 identity digest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = canonical) do
    canonical
    |> to_data()
    |> Value.digest!()
  end

  @doc "Returns the content-addressed Ref for a Definition."
  @spec ref(t()) :: Ref.t()
  def ref(%__MODULE__{} = canonical), do: Ref.new(canonical)

  @doc "Fetches one component by its unique type."
  @spec fetch_component(t(), atom() | String.t()) ::
          {:ok, Component.t()} | {:error, {:unknown_definition_component, term()}}
  def fetch_component(%__MODULE__{components: components}, component_type) do
    case Enum.find(components, &(&1.component_type == component_type)) do
      %Component{} = component -> {:ok, component}
      nil -> {:error, {:unknown_definition_component, component_type}}
    end
  end

  @spec validate_header(t()) :: :ok | {:error, term()}
  defp validate_header(%__MODULE__{} = canonical) do
    with :ok <- validate_format_header(canonical),
         :ok <- validate_identity_header(canonical) do
      validate_component_header(canonical)
    end
  end

  @spec validate_format_header(t()) :: :ok | {:error, term()}
  defp validate_format_header(%__MODULE__{} = canonical) do
    cond do
      canonical.canonicalization_version != @canonicalization_version ->
        {:error,
         {:unsupported_definition_canonicalization_version, canonical.canonicalization_version}}

      canonical.contract_version != @contract_version ->
        {:error, {:unsupported_definition_contract_version, canonical.contract_version}}

      canonical.digest_algorithm != @digest_algorithm ->
        {:error, {:unsupported_definition_digest_algorithm, canonical.digest_algorithm}}

      true ->
        :ok
    end
  end

  @spec validate_identity_header(t()) :: :ok | {:error, term()}
  defp validate_identity_header(%__MODULE__{} = canonical) do
    cond do
      canonical.kind not in @kinds ->
        {:error, {:invalid_canonical_definition_kind, canonical.kind}}

      is_nil(canonical.id) ->
        {:error, :missing_canonical_definition_id}

      is_nil(canonical.declared_version) ->
        {:error, :missing_canonical_definition_version}

      canonical.origin not in @origins ->
        {:error, {:invalid_canonical_definition_origin, canonical.origin}}

      true ->
        :ok
    end
  end

  @spec validate_component_header(t()) :: :ok | {:error, term()}
  defp validate_component_header(%__MODULE__{components: components}) when is_list(components),
    do: :ok

  defp validate_component_header(%__MODULE__{components: components}) do
    {:error, {:invalid_canonical_definition_components, shape(components)}}
  end

  @spec normalize_components([term()]) :: {:ok, [Component.t()]} | {:error, term()}
  defp normalize_components(components) do
    with true <- Enum.all?(components, &match?(%Component{}, &1)),
         nil <- duplicate_component(components) do
      {:ok, Enum.sort_by(components, &component_sort_key/1)}
    else
      false -> {:error, :invalid_canonical_definition_component}
      duplicate -> {:error, {:duplicate_definition_component, duplicate}}
    end
  end

  @spec duplicate_component([Component.t()]) :: term() | nil
  defp duplicate_component(components) do
    components
    |> Enum.group_by(& &1.component_type)
    |> Enum.find_value(fn
      {type, [_first, _second | _rest]} -> type
      {_type, [_single]} -> nil
    end)
  end

  @spec component_sort_key(Component.t()) :: binary()
  defp component_sort_key(%Component{} = component) do
    Value.encode!(%{
      component_type: component.component_type,
      schema_ref: component.schema_ref
    })
  end

  @spec validate_portable(t()) :: :ok | {:error, term()}
  defp validate_portable(canonical) do
    case canonical |> to_data() |> Value.validate() do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_canonical_definition, reason}}
    end
  end

  @spec decode_components([term()]) :: {:ok, [Component.t()]} | {:error, term()}
  defp decode_components(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, components} ->
      case Component.from_data(value) do
        {:ok, component} -> {:cont, {:ok, [component | components]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, components} -> {:ok, Enum.reverse(components)}
      {:error, _reason} = error -> error
    end
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
