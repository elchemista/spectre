defmodule Spectre.Execution.Closure do
  @moduledoc """
  Portable execution dependencies sealed into a Definition Manifest.

  The closure records exact data references and the fingerprints of compiled
  implementations observed when a Definition was composed. A fingerprint is
  evidence of one build, not a promise that BEAM code can be restored by
  digest. `compare_builds/2` makes missing or changed code explicit so a
  resolver can block before execution or report drift under a host policy.
  """

  alias Spectre.Canonical.Value

  @schema_version 1
  @compatibility_modes [:native_v2, :adapted_v1]
  @list_fields [
    :package_refs,
    :contract_refs,
    :prompt_fragment_digests,
    :model_profile_refs,
    :recording_refs
  ]
  @required_fields [
    :stack_ref,
    :package_refs,
    :contract_refs,
    :prompt_fragment_digests,
    :projection_generators,
    :state_schema_ref,
    :state_codec_ref,
    :model_profile_refs,
    :recording_refs,
    :build_fingerprints,
    :evaluation_corpus_digest,
    :compatibility_mode
  ]

  @enforce_keys [:schema_version | @required_fields]
  defstruct schema_version: @schema_version,
            stack_ref: nil,
            package_refs: [],
            contract_refs: [],
            prompt_fragment_digests: [],
            projection_generators: [],
            state_schema_ref: nil,
            state_codec_ref: nil,
            model_profile_refs: [],
            recording_refs: [],
            build_fingerprints: [],
            evaluation_corpus_digest: nil,
            compatibility_mode: nil

  @type fingerprint :: %{
          required(:ref) => String.t(),
          required(:digest) => String.t(),
          required(:drift_policy) => :block | :report
        }

  @type drift :: %{
          required(:ref) => String.t(),
          required(:expected) => String.t(),
          required(:observed) => String.t() | nil,
          required(:reason) => :changed | :missing,
          required(:policy) => :block | :report
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          stack_ref: String.t(),
          package_refs: [String.t()],
          contract_refs: [String.t()],
          prompt_fragment_digests: [String.t()],
          projection_generators: [map()],
          state_schema_ref: String.t(),
          state_codec_ref: String.t(),
          model_profile_refs: [String.t()],
          recording_refs: [String.t()],
          build_fingerprints: [fingerprint()],
          evaluation_corpus_digest: String.t() | nil,
          compatibility_mode: :native_v2 | :adapted_v1
        }

  @doc "Returns the Execution Closure schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds a complete, validated execution closure."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = closure), do: closure |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- validate_keys(attrs),
         :ok <- validate_required(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version, @schema_version)),
         {:ok, lists} <- normalize_lists(attrs),
         {:ok, generators} <- normalize_generators(Map.fetch!(attrs, :projection_generators)),
         {:ok, fingerprints} <- normalize_fingerprints(Map.fetch!(attrs, :build_fingerprints)),
         :ok <- validate_refs(attrs),
         :ok <- validate_digest(Map.fetch!(attrs, :evaluation_corpus_digest), true),
         :ok <- validate_compatibility(Map.fetch!(attrs, :compatibility_mode)) do
      closure =
        attrs
        |> Map.merge(lists)
        |> Map.put(:schema_version, @schema_version)
        |> Map.put(:projection_generators, generators)
        |> Map.put(:build_fingerprints, fingerprints)
        |> then(&struct!(__MODULE__, &1))

      {:ok, closure}
    end
  end

  def new(value), do: {:error, {:invalid_execution_closure, shape(value)}}

  @doc "Builds a closure or raises with its stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, closure} -> closure
      {:error, reason} -> raise ArgumentError, "invalid execution closure: #{inspect(reason)}"
    end
  end

  @doc "Returns the portable data sealed into a Definition Manifest."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = closure) do
    %{
      "schema_version" => closure.schema_version,
      "stack_ref" => closure.stack_ref,
      "package_refs" => closure.package_refs,
      "contract_refs" => closure.contract_refs,
      "prompt_fragment_digests" => closure.prompt_fragment_digests,
      "projection_generators" => closure.projection_generators,
      "state_schema_ref" => closure.state_schema_ref,
      "state_codec_ref" => closure.state_codec_ref,
      "model_profile_refs" => closure.model_profile_refs,
      "recording_refs" => closure.recording_refs,
      "build_fingerprints" => closure.build_fingerprints,
      "evaluation_corpus_digest" => closure.evaluation_corpus_digest,
      "compatibility_mode" => closure.compatibility_mode
    }
  end

  @doc "Restores a closure from decoded canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{"schema_version" => schema_version} = data) do
    attrs =
      Enum.reduce(@required_fields, %{schema_version: schema_version}, fn field, acc ->
        Map.put(acc, field, Map.get(data, Atom.to_string(field)))
      end)

    new(attrs)
  end

  def from_data(value), do: {:error, {:invalid_execution_closure_data, shape(value)}}

  @doc "Returns the canonical SHA-256 digest of the closure."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = closure), do: closure |> to_data() |> Value.digest!()

  @doc """
  Compares sealed build fingerprints with fingerprints observed by trusted host
  code. The observed map is keyed by the closure's logical code Refs.
  """
  @spec compare_builds(t(), %{optional(String.t()) => String.t()}) ::
          {:ok, :matched} | {:drift, [drift()]} | {:error, term()}
  def compare_builds(%__MODULE__{} = closure, observed) when is_map(observed) do
    with :ok <- validate_observed(observed) do
      drifts = build_drifts(closure.build_fingerprints, observed)

      if drifts == [], do: {:ok, :matched}, else: {:drift, drifts}
    end
  end

  def compare_builds(%__MODULE__{}, value),
    do: {:error, {:invalid_observed_build_fingerprints, shape(value)}}

  @doc """
  Computes the SHA-256 fingerprint of the currently loaded BEAM object code.

  This helper is intended for trusted composition and deployment registries;
  canonical runtime data is never converted into a module to call it.
  """
  @spec fingerprint(module()) :: {:ok, String.t()} | {:error, term()}
  def fingerprint(module) when is_atom(module) and not is_nil(module) do
    case :code.get_object_code(module) do
      {^module, binary, _path} when is_binary(binary) ->
        {:ok, binary |> sha256() |> Base.encode16(case: :lower)}

      :error ->
        fingerprint_module_md5(module)
    end
  end

  def fingerprint(value), do: {:error, {:invalid_fingerprint_module, value}}

  @doc "Builds one validated fingerprint entry for a trusted loaded module."
  @spec fingerprint_entry(String.t(), module(), :block | :report) ::
          {:ok, fingerprint()} | {:error, term()}
  def fingerprint_entry(ref, module, policy \\ :block) do
    with true <- nonempty_binary?(ref),
         true <- policy in [:block, :report],
         {:ok, digest} <- fingerprint(module) do
      {:ok, %{ref: ref, digest: digest, drift_policy: policy}}
    else
      false -> {:error, {:invalid_build_fingerprint_entry, ref, module, policy}}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_keys(map()) :: :ok | {:error, term()}
  defp validate_keys(attrs) do
    allowed = [:schema_version | @required_fields]

    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_execution_closure_fields, Enum.sort(unknown)}}
    end
  end

  @spec validate_required(map()) :: :ok | {:error, term()}
  defp validate_required(attrs) do
    case Enum.find(@required_fields, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:incomplete_execution_closure, field}}
    end
  end

  @spec validate_schema(term()) :: :ok | {:error, term()}
  defp validate_schema(@schema_version), do: :ok

  defp validate_schema(version),
    do: {:error, {:unsupported_execution_closure_schema, version}}

  @spec normalize_lists(map()) :: {:ok, map()} | {:error, term()}
  defp normalize_lists(attrs) do
    Enum.reduce_while(@list_fields, {:ok, %{}}, fn field, {:ok, normalized} ->
      value = Map.fetch!(attrs, field)
      validator = if field == :prompt_fragment_digests, do: &digest?/1, else: &nonempty_binary?/1

      case normalize_string_list(value, field, validator) do
        {:ok, values} -> {:cont, {:ok, Map.put(normalized, field, values)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec normalize_string_list(term(), atom(), (term() -> boolean())) ::
          {:ok, [String.t()]} | {:error, term()}
  defp normalize_string_list(values, field, validator) when is_list(values) do
    if Enum.all?(values, validator) do
      {:ok, values |> Enum.uniq() |> Enum.sort()}
    else
      {:error, {:invalid_execution_closure_list, field}}
    end
  end

  defp normalize_string_list(value, field, _validator),
    do: {:error, {:invalid_execution_closure_list, field, shape(value)}}

  @spec normalize_generators(term()) :: {:ok, [map()]} | {:error, term()}
  defp normalize_generators(generators) when is_list(generators) and generators != [] do
    if Enum.all?(generators, &valid_generator?/1) do
      {:ok,
       generators |> Enum.uniq_by(&{&1.id, &1.version}) |> Enum.sort_by(&{&1.id, &1.version})}
    else
      {:error, :invalid_projection_generators}
    end
  end

  defp normalize_generators(_value), do: {:error, :incomplete_projection_generators}

  @spec valid_generator?(term()) :: boolean()
  defp valid_generator?(%{id: id, version: version}),
    do: nonempty_binary?(id) and is_integer(version) and version > 0

  defp valid_generator?(_value), do: false

  @spec normalize_fingerprints(term()) :: {:ok, [fingerprint()]} | {:error, term()}
  defp normalize_fingerprints(fingerprints) when is_map(fingerprints) do
    fingerprints
    |> Enum.map(fn {ref, digest} -> %{ref: ref, digest: digest, drift_policy: :block} end)
    |> normalize_fingerprints()
  end

  defp normalize_fingerprints(fingerprints) when is_list(fingerprints) and fingerprints != [] do
    if Enum.all?(fingerprints, &valid_fingerprint?/1) do
      case duplicate_ref(fingerprints) do
        nil -> {:ok, Enum.sort_by(fingerprints, & &1.ref)}
        ref -> {:error, {:duplicate_build_fingerprint, ref}}
      end
    else
      {:error, :invalid_build_fingerprints}
    end
  end

  defp normalize_fingerprints(_value), do: {:error, :incomplete_build_fingerprints}

  @spec valid_fingerprint?(term()) :: boolean()
  defp valid_fingerprint?(%{ref: ref, digest: digest, drift_policy: policy}) do
    nonempty_binary?(ref) and digest?(digest) and policy in [:block, :report]
  end

  defp valid_fingerprint?(_value), do: false

  @spec duplicate_ref([fingerprint()]) :: String.t() | nil
  defp duplicate_ref(fingerprints) do
    fingerprints
    |> Enum.frequencies_by(& &1.ref)
    |> Enum.find_value(fn
      {ref, count} when count > 1 -> ref
      {_ref, _count} -> nil
    end)
  end

  @spec validate_refs(map()) :: :ok | {:error, term()}
  defp validate_refs(attrs) do
    case Enum.find([:stack_ref, :state_schema_ref, :state_codec_ref], fn field ->
           not nonempty_binary?(Map.fetch!(attrs, field))
         end) do
      nil -> :ok
      field -> {:error, {:invalid_execution_closure_ref, field, Map.fetch!(attrs, field)}}
    end
  end

  @spec validate_digest(term(), boolean()) :: :ok | {:error, term()}
  defp validate_digest(nil, true), do: :ok

  defp validate_digest(value, _optional?) do
    if digest?(value),
      do: :ok,
      else: {:error, {:invalid_execution_closure_digest, value}}
  end

  @spec validate_compatibility(term()) :: :ok | {:error, term()}
  defp validate_compatibility(mode) when mode in @compatibility_modes, do: :ok

  defp validate_compatibility(mode),
    do: {:error, {:invalid_execution_compatibility_mode, mode}}

  @spec validate_observed(map()) :: :ok | {:error, term()}
  defp validate_observed(observed) do
    if Enum.all?(observed, fn {ref, digest} -> nonempty_binary?(ref) and digest?(digest) end),
      do: :ok,
      else: {:error, :invalid_observed_build_fingerprints}
  end

  @spec build_drifts([fingerprint()], map()) :: [drift()]
  defp build_drifts(fingerprints, observed) do
    Enum.flat_map(fingerprints, &build_drift(&1, Map.fetch(observed, &1.ref)))
  end

  @spec build_drift(fingerprint(), {:ok, String.t()} | :error) :: [drift()]
  defp build_drift(fingerprint, {:ok, digest}) when digest == fingerprint.digest, do: []
  defp build_drift(fingerprint, {:ok, digest}), do: [drift(fingerprint, digest, :changed)]
  defp build_drift(fingerprint, :error), do: [drift(fingerprint, nil, :missing)]

  @spec drift(fingerprint(), String.t() | nil, :changed | :missing) :: drift()
  defp drift(fingerprint, observed, reason) do
    %{
      ref: fingerprint.ref,
      expected: fingerprint.digest,
      observed: observed,
      reason: reason,
      policy: fingerprint.drift_policy
    }
  end

  @spec digest?(term()) :: boolean()
  defp digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
    match?({:ok, <<_::256>>}, Base.decode16(digest, case: :mixed))
  end

  defp digest?(_value), do: false

  @spec fingerprint_module_md5(module()) :: {:ok, String.t()} | {:error, term()}
  defp fingerprint_module_md5(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :module_info, 1) do
      digest = module.module_info(:md5)
      {:ok, digest |> sha256() |> Base.encode16(case: :lower)}
    else
      {:error, {:object_code_unavailable, module}}
    end
  rescue
    _exception -> {:error, {:object_code_unavailable, module}}
  end

  @spec sha256(binary()) :: binary()
  defp sha256(binary), do: :crypto.hash(:sha256, binary)

  @spec nonempty_binary?(term()) :: boolean()
  defp nonempty_binary?(value), do: is_binary(value) and value != ""

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
