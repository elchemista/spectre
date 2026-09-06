defmodule Spectre.Input.Pipeline do
  @moduledoc """
  Reusable input plugs without a media schema or a runtime process.

      {:ok, pipeline} = Spectre.Input.Pipeline.new([
        {Spectre.Input.Plugs.NormalizeText, case: :downcase}
      ])
      {:ok, "hello"} = Spectre.Input.Pipeline.run(pipeline, "  HELLO  ")

  Prepare once in host configuration and reuse the plan. Values may be text,
  binary data or application-defined portable structures. Every intermediate
  value is checked against the same canonical resource budget: by default
  65,536 encoded bytes, depth 32 and 1,024 entries per collection. Override with
  `:max_bytes`, `:max_depth` and `:max_collection_size`; runtime capabilities
  and structs are never accepted as input or output.

  The pipeline runs where its caller runs, never automatically in the Domain
  sequencer. The host can use it before ingestion, or a Mind can transform
  already-visible Evidence. It neither authenticates input nor records it.
  Preserve the original observation when it matters; use `Spectre.Mind.evidence/3`
  for a derived interpretation so its parents and labels remain attached.

  Only host configuration selects modules. No module is loaded from a ledger
  record. Callback failures stop the pipeline without retries. Byte limits bound
  values accepted between stages, not arbitrary allocations or execution time
  inside application callbacks; isolation and timeouts remain host concerns.
  """

  alias Spectre.{Adapter, Portable}
  alias Spectre.Canonical.Value

  @defaults [max_bytes: 65_536, max_depth: 32, max_collection_size: 1024]
  @max_steps 64
  @enforce_keys [:steps, :limits]
  defstruct @enforce_keys

  @type plug :: module() | {module(), keyword()}
  @opaque t :: %__MODULE__{steps: [{module(), term()}], limits: keyword()}

  @doc "Validates and initializes at most 64 host-declared plugs."
  @spec new([plug()], keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(specs, opts \\ [])

  def new(specs, opts) when is_list(specs) and length(specs) <= @max_steps do
    with {:ok, attrs} <-
           Portable.normalize_attrs(opts, Keyword.keys(@defaults), :input_pipeline),
         limits = Keyword.merge(@defaults, Map.to_list(attrs)),
         :ok <- Value.validate(nil, limits),
         {:ok, steps} <- prepare(specs) do
      {:ok, %__MODULE__{steps: steps, limits: limits}}
    end
  end

  def new(_specs, _opts), do: {:error, :invalid_input_plugs}

  @doc "Transforms a portable value, preserving the distinction between completion and halt."
  @spec run(t(), term()) :: {:ok, term()} | {:halt, term()} | {:error, term()}
  def run(%__MODULE__{} = pipeline, input) do
    with :ok <- Value.validate(input, pipeline.limits) do
      Enum.reduce_while(pipeline.steps, {:ok, input}, fn {module, state}, {:ok, value} ->
        continue(invoke(module, state, value, pipeline.limits))
      end)
    end
  end

  def run(_pipeline, _input), do: {:error, :invalid_input_pipeline}

  defp prepare(specs) do
    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, steps} ->
      with {:ok, {module, opts}} <- declaration(spec),
           :ok <- Adapter.validate(module, call: 2),
           {:ok, state} <- initialize(module, opts) do
        {:cont, {:ok, [{module, state} | steps]}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.reverse(steps)}
      error -> error
    end
  end

  defp declaration({module, opts}) do
    if Portable.keyword?(opts),
      do: {:ok, {module, opts}},
      else: {:error, :invalid_input_plug_options}
  end

  defp declaration(module), do: declaration({module, []})

  defp initialize(module, opts) do
    if function_exported?(module, :init, 1) do
      with {:ok, result} <- Adapter.invoke(module, :init, [opts]), do: initialized(result)
    else
      {:ok, opts}
    end
  end

  defp initialized({:ok, _state} = result), do: result
  defp initialized({:error, _reason} = result), do: result
  defp initialized(_result), do: {:error, :invalid_input_plug_init_result}

  defp invoke(module, state, input, limits) do
    with {:ok, result} <- Adapter.invoke(module, :call, [input, state]),
         {:ok, result} <- validate_result(result, limits) do
      result
    else
      {:error, reason} -> {:error, {:input_plug_failed, module, reason}}
    end
  end

  defp validate_result({status, value} = result, limits) when status in [:cont, :halt] do
    with :ok <- Value.validate(value, limits), do: {:ok, result}
  end

  defp validate_result({:error, _reason} = error, _limits), do: error
  defp validate_result(_result, _limits), do: {:error, :invalid_input_plug_result}

  defp continue({:cont, value}), do: {:cont, {:ok, value}}
  defp continue(result), do: {:halt, result}
end
