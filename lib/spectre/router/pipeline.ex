defmodule Spectre.Pipeline do
  @moduledoc """
  Minimal Plug-style pipeline executor for Spectre router stages.

  Router pipelines collect evidence rather than immediately executing handlers.
  This shape lets each plug focus on one strategy (regex, cache, classifier,
  embedding, arbitration) while the final route decision remains explicit.

      defmodule MyApp.RouterPipeline do
        use Spectre.Pipeline

        pipeline do
          plug Spectre.Router.Plugs.Regex
          plug Spectre.Router.Plugs.LocalClassifier
          plug Spectre.Router.Plugs.Arbitrate
          plug Spectre.Router.Plugs.Terminalize
        end
      end
  """

  defmodule Spec do
    @moduledoc """
    Initialized router plug declaration.

    The executor stores initialized state alongside the module so custom plugs
    can perform setup in `init/1` and keep `call/2` focused on per-turn routing.
    """

    defstruct [:module, :state]

    @type t :: %__MODULE__{module: module(), state: term()}
  end

  @type plug_spec :: module() | {module(), keyword()} | Spec.t()

  @doc """
  Imports router pipeline macros into a custom pipeline module.
  """
  defmacro __using__(_opts) do
    quote do
      import Spectre.Pipeline, only: [pipeline: 1, plug: 1, plug: 2]

      Module.register_attribute(__MODULE__, :spectre_pipeline, accumulate: true)
      @before_compile Spectre.Pipeline
    end
  end

  @doc """
  Groups router plug declarations.
  """
  defmacro pipeline(do: block), do: block

  @doc """
  Adds a router plug declaration to a custom pipeline.

      plug Spectre.Router.Plugs.Regex
      plug Spectre.Router.Plugs.LocalClassifier, classifier_local: MyApp.Classifier
  """
  defmacro plug(module, opts \\ []) do
    quote do
      @spectre_pipeline {unquote(module), unquote(opts)}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    specs =
      env.module
      |> Module.get_attribute(:spectre_pipeline)
      |> Enum.reverse()
      |> Macro.escape()

    quote do
      @spectre_pipeline_specs Spectre.Pipeline.init_specs!(unquote(specs))

      @doc false
      def call(%Spectre.Router.Context{} = context) do
        Spectre.Pipeline.run(context, @spectre_pipeline_specs)
      end
    end
  end

  @doc """
  Initializes pipeline specs and raises on invalid declarations.
  """
  @spec init_specs!([plug_spec()]) :: [Spec.t()]
  def init_specs!(specs) do
    case init_specs(specs) do
      {:ok, specs} -> specs
      {:error, reason} -> raise ArgumentError, "invalid Spectre pipeline: #{inspect(reason)}"
    end
  end

  @doc """
  Initializes pipeline specs.
  """
  @spec init_specs([plug_spec()]) :: {:ok, [Spec.t()]} | {:error, term()}
  def init_specs(specs) when is_list(specs) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      with {:ok, {module, opts}} <- normalize_declaration(spec),
           {:ok, state} <- init_plug(module, opts) do
        {:cont, {:ok, [%Spec{module: module, state: state} | acc]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Runs a router context through initialized or ad-hoc plug specs.
  """
  @spec run(Spectre.Router.Context.t(), [plug_spec()]) ::
          {:ok, Spectre.Router.Context.t()} | {:error, term()}
  def run(%Spectre.Router.Context{} = context, specs) when is_list(specs) do
    Enum.reduce_while(specs, {:ok, context}, fn spec, {:ok, context} ->
      case normalize_spec(spec) do
        {:ok, {module, state}} -> run_plug(module, state, context)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec normalize_spec(plug_spec()) :: {:ok, {module(), term()}} | {:error, term()}
  defp normalize_spec(%Spec{module: module, state: state}) when is_atom(module),
    do: {:ok, {module, state}}

  defp normalize_spec(spec) do
    with {:ok, {module, opts}} <- normalize_declaration(spec),
         {:ok, state} <- init_plug(module, opts) do
      {:ok, {module, state}}
    end
  end

  @spec normalize_declaration(plug_spec()) ::
          {:ok, {module(), keyword() | term()}} | {:error, term()}
  defp normalize_declaration(module) when is_atom(module), do: {:ok, {module, []}}

  defp normalize_declaration({module, opts}) when is_atom(module) and is_list(opts),
    do: {:ok, {module, opts}}

  defp normalize_declaration(%Spec{} = spec), do: {:ok, {spec.module, spec.state}}
  defp normalize_declaration(spec), do: {:error, {:invalid_plug_spec, spec}}

  @spec init_plug(module(), keyword()) :: {:ok, term()}
  defp init_plug(module, opts), do: {:ok, module.init(opts)}

  @spec run_plug(module(), term(), Spectre.Router.Context.t()) ::
          {:cont, {:ok, Spectre.Router.Context.t()}}
          | {:halt, {:ok, Spectre.Router.Context.t()} | {:error, term()}}
  defp run_plug(module, state, context) do
    case module.call(context, state) do
      {:cont, %Spectre.Router.Context{} = context} -> {:cont, {:ok, context}}
      {:halt, %Spectre.Router.Context{} = context} -> {:halt, {:ok, %{context | halted?: true}}}
      {:error, reason} -> {:halt, {:error, {module, reason}}}
      other -> {:halt, {:error, {module, {:invalid_plug_return, other}}}}
    end
  rescue
    error -> {:halt, {:error, {module, error}}}
  end
end
