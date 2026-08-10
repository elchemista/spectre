defmodule Spectre.Stack.Contract.V2 do
  @moduledoc """
  Mandatory runtime Stack contract for reflective Definition Manifests.

  Contract V2 seals two distinct objects: the effective Authority Envelope and
  the Execution Closure. Existing compiled Stack V1 definitions are accepted
  only through `from_v1/2`, which reads and conservatively lowers them without
  mutating or retaining V1 as the native Manifest contract.
  """

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition, as: CompiledDefinition
  alias Spectre.Definition.Canonical
  alias Spectre.Execution.Closure
  alias Spectre.Stack.Definition, as: StackDefinition
  alias Spectre.Stack.Installation

  @contract_version 2

  @enforce_keys [:contract_version, :source_contract, :authority, :execution_closure]
  defstruct contract_version: @contract_version,
            source_contract: nil,
            authority: nil,
            execution_closure: nil

  @type t :: %__MODULE__{
          contract_version: 2,
          source_contract: :native_v2 | :adapted_v1,
          authority: Envelope.t(),
          execution_closure: Closure.t()
        }

  @doc "Returns the mandatory reflective Stack contract version."
  @spec version() :: pos_integer()
  def version, do: @contract_version

  @doc "Builds a native Contract V2 from reviewed authority and closure data."
  @spec new(Envelope.t(), Closure.t()) :: {:ok, t()} | {:error, term()}
  def new(%Envelope{} = authority, %Closure{} = closure) do
    with {:ok, authority} <- Envelope.new(authority),
         {:ok, closure} <- Closure.new(closure),
         :ok <- require_mode(closure, :native_v2) do
      {:ok,
       %__MODULE__{
         contract_version: @contract_version,
         source_contract: :native_v2,
         authority: authority,
         execution_closure: closure
       }}
    end
  end

  @doc "Builds a native Contract V2 or raises."
  @spec new!(Envelope.t(), Closure.t()) :: t()
  def new!(authority, closure) do
    case new(authority, closure) do
      {:ok, contract} -> contract
      {:error, reason} -> raise ArgumentError, "invalid Stack Contract V2: #{inspect(reason)}"
    end
  end

  @doc """
  Conservatively adapts an immutable Stack Contract V1 definition.

  V1 capability declarations are requests only. Effective grants are their
  intersection with the explicit `:authority_ceiling`; omitting the ceiling
  produces an empty envelope.
  """
  @spec from_v1(StackDefinition.t() | module() | nil, keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_v1(stack, opts \\ []) when is_list(opts) do
    with {:ok, stack} <- normalize_v1_stack(stack),
         {:ok, requested} <- requested_authority(stack, opts),
         {:ok, ceiling} <- Envelope.new(Keyword.get(opts, :authority_ceiling, %{})),
         {:ok, effective} <- Envelope.compose(requested, ceiling),
         {:ok, closure} <- adapted_closure(stack, opts) do
      {:ok,
       %__MODULE__{
         contract_version: @contract_version,
         source_contract: :adapted_v1,
         authority: effective,
         execution_closure: closure
       }}
    end
  end

  @doc "Adapts a V1 Stack or raises with its stable validation reason."
  @spec from_v1!(StackDefinition.t() | module() | nil, keyword()) :: t()
  def from_v1!(stack, opts \\ []) do
    case from_v1(stack, opts) do
      {:ok, contract} ->
        contract

      {:error, reason} ->
        raise ArgumentError, "cannot adapt Stack Contract V1: #{inspect(reason)}"
    end
  end

  @doc """
  Builds Contract V2 for a compiled Agent/Skill and its canonical projection.
  """
  @spec from_compiled(CompiledDefinition.t(), Canonical.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def from_compiled(%CompiledDefinition{} = definition, %Canonical{} = canonical, opts \\ [])
      when is_list(opts) do
    opts =
      opts
      |> Keyword.update(:owner_modules, compiled_modules(definition), fn modules ->
        Enum.uniq(compiled_modules(definition) ++ List.wrap(modules))
      end)
      |> Keyword.put_new(:prompt_fragment_digests, prompt_digests(canonical))
      |> Keyword.update(:contract_refs, code_contract_refs(canonical), fn refs ->
        Enum.uniq(code_contract_refs(canonical) ++ List.wrap(refs))
      end)

    from_v1(definition.stack, opts)
  end

  @doc "Returns portable inspection data for the adapted contract."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = contract) do
    %{
      "contract_version" => contract.contract_version,
      "source_contract" => contract.source_contract,
      "authority" => Envelope.to_data(contract.authority),
      "execution_closure" => Closure.to_data(contract.execution_closure)
    }
  end

  @spec normalize_v1_stack(StackDefinition.t() | module() | nil) ::
          {:ok, StackDefinition.t() | nil} | {:error, term()}
  defp normalize_v1_stack(nil), do: {:ok, nil}

  defp normalize_v1_stack(%StackDefinition{contract: 1} = stack),
    do: StackDefinition.validate(stack)

  defp normalize_v1_stack(%StackDefinition{contract: contract}),
    do: {:error, {:unsupported_stack_adapter_source, contract}}

  defp normalize_v1_stack(module) when is_atom(module) and not is_nil(module),
    do: StackDefinition.fetch(module)

  defp normalize_v1_stack(value), do: {:error, {:invalid_stack_adapter_source, value}}

  @spec requested_authority(StackDefinition.t() | nil, keyword()) ::
          {:ok, Envelope.t()} | {:error, term()}
  defp requested_authority(stack, opts) do
    base =
      case stack do
        nil -> %{}
        %StackDefinition{installations: installations} -> stack_requests(installations)
      end

    explicit = Keyword.get(opts, :authority_requests, %{})

    with {:ok, base} <- Envelope.new(base),
         {:ok, explicit} <- Envelope.new(explicit) do
      Envelope.new(merge_requests(base, explicit))
    end
  end

  @spec stack_requests([Installation.t()]) :: map()
  defp stack_requests(installations) do
    Enum.reduce(installations, %{}, fn installation, requests ->
      requests
      |> append(:operations, installation.operations)
      |> append(:actions, installation.actions)
      |> append(:external_data_refs, installation.resources)
    end)
  end

  @spec merge_requests(Envelope.t(), Envelope.t()) :: map()
  defp merge_requests(base, explicit) do
    fields = base |> Map.from_struct() |> Map.keys() |> List.delete(:schema_version)

    Map.new(fields, fn
      :limits -> {:limits, Map.merge(base.limits, explicit.limits)}
      field -> {field, Map.fetch!(base, field) ++ Map.fetch!(explicit, field)}
    end)
  end

  @spec append(map(), atom(), [term()]) :: map()
  defp append(requests, field, values),
    do: Map.update(requests, field, List.wrap(values), &(List.wrap(&1) ++ List.wrap(values)))

  @spec adapted_closure(StackDefinition.t() | nil, keyword()) ::
          {:ok, Closure.t()} | {:error, term()}
  defp adapted_closure(stack, opts) do
    with {:ok, fingerprints} <- build_fingerprints(stack, opts) do
      Closure.new(%{
        stack_ref: stack_ref(stack),
        package_refs: package_refs(stack),
        contract_refs:
          Enum.uniq(stack_contract_refs(stack) ++ Keyword.get(opts, :contract_refs, [])),
        prompt_fragment_digests: Keyword.get(opts, :prompt_fragment_digests, []),
        projection_generators:
          Keyword.get(opts, :projection_generators, [
            %{id: "spectre.projection.audit", version: 1}
          ]),
        state_schema_ref: Keyword.get(opts, :state_schema_ref, "spectre.instance.canonical/1"),
        state_codec_ref:
          Keyword.get(opts, :state_codec_ref, "spectre.instance.canonical.codec/1"),
        model_profile_refs: Keyword.get(opts, :model_profile_refs, []),
        recording_refs: Keyword.get(opts, :recording_refs, []),
        build_fingerprints: fingerprints,
        evaluation_corpus_digest: Keyword.get(opts, :evaluation_corpus_digest),
        compatibility_mode: :adapted_v1
      })
    end
  end

  @spec build_fingerprints(StackDefinition.t() | nil, keyword()) ::
          {:ok, [Closure.fingerprint()]} | {:error, term()}
  defp build_fingerprints(stack, opts) do
    stack_modules =
      case stack do
        nil -> []
        %StackDefinition{} -> [stack.owner | Enum.map(stack.installations, & &1.package.module)]
      end

    modules =
      [__MODULE__ | stack_modules ++ List.wrap(Keyword.get(opts, :owner_modules, []))]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Enum.reduce_while(modules, {:ok, []}, fn module, {:ok, fingerprints} ->
      ref = "beam:" <> Atom.to_string(module)

      case Closure.fingerprint_entry(ref, module) do
        {:ok, fingerprint} -> {:cont, {:ok, [fingerprint | fingerprints]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fingerprints} -> {:ok, Enum.reverse(fingerprints)}
      {:error, _reason} = error -> error
    end
  end

  @spec stack_ref(StackDefinition.t() | nil) :: String.t()
  defp stack_ref(nil), do: "spectre.stack:none"
  defp stack_ref(%StackDefinition{digest: digest}), do: "legacy-sha256:" <> digest

  @spec package_refs(StackDefinition.t() | nil) :: [String.t()]
  defp package_refs(nil), do: []

  defp package_refs(%StackDefinition{installations: installations}) do
    Enum.map(installations, fn installation ->
      package = installation.package

      "spectre.package:#{Value.digest!(package.id)}@#{package.version}:sha256:#{package.digest}"
    end)
  end

  @spec stack_contract_refs(StackDefinition.t() | nil) :: [String.t()]
  defp stack_contract_refs(nil), do: []

  defp stack_contract_refs(%StackDefinition{index: index}) do
    index
    |> Map.keys()
    |> Enum.map(fn {kind, id} -> "spectre.stack.#{kind}:#{Value.digest!(id)}" end)
    |> Enum.sort()
  end

  @spec compiled_modules(CompiledDefinition.t()) :: [module()]
  defp compiled_modules(definition) do
    [definition.owner | Enum.map(definition.skills, & &1.module)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec prompt_digests(Canonical.t()) :: [String.t()]
  defp prompt_digests(canonical) do
    case Canonical.fetch_component(canonical, :prompt_fragments) do
      {:ok, %{payload: %{fragments: fragments}}} ->
        fragments
        |> Enum.map(&Map.get(&1, :digest, Map.get(&1, "digest")))
        |> Enum.filter(&is_binary/1)

      _other ->
        []
    end
  end

  @spec code_contract_refs(Canonical.t()) :: [String.t()]
  defp code_contract_refs(canonical) do
    canonical
    |> Canonical.to_data()
    |> collect_code_refs([])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec collect_code_refs(term(), [String.t()]) :: [String.t()]
  defp collect_code_refs(%{"$spectre_type" => "code_ref"} = ref, acc) do
    ["spectre.code:" <> Value.digest!(ref) | acc]
  end

  defp collect_code_refs(value, acc) when is_map(value) do
    Enum.reduce(value, acc, fn {key, item}, refs ->
      refs = collect_code_refs(key, refs)
      collect_code_refs(item, refs)
    end)
  end

  defp collect_code_refs(value, acc) when is_list(value),
    do: Enum.reduce(value, acc, &collect_code_refs/2)

  defp collect_code_refs(value, acc) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.reduce(acc, &collect_code_refs/2)

  defp collect_code_refs(_value, acc), do: acc

  @spec require_mode(Closure.t(), atom()) :: :ok | {:error, term()}
  defp require_mode(%Closure{compatibility_mode: mode}, mode), do: :ok

  defp require_mode(%Closure{compatibility_mode: actual}, expected),
    do: {:error, {:execution_closure_mode_mismatch, expected, actual}}
end
