defmodule Spectre.Input.Pipeline do
  @moduledoc """
  Runs input plugs before the Spectre runtime handles a turn.
  """

  defmodule Spec do
    @moduledoc false
    defstruct [:module, :state]

    @type t :: %__MODULE__{module: module(), state: term()}
  end

  @type plug_spec :: module() | {module(), keyword()} | Spec.t()

  @doc """
  Initializes input plug specs.
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
  Runs an input through initialized or ad-hoc plug specs.
  """
  @spec run(Spectre.Input.t(), map(), [plug_spec()]) ::
          {:ok, Spectre.Input.t()} | {:error, term()}
  def run(%Spectre.Input{} = input, context, specs) when is_map(context) and is_list(specs) do
    Enum.reduce_while(specs, {:ok, input}, fn spec, {:ok, input} ->
      case normalize_spec(spec) do
        {:ok, {module, state}} -> run_plug(module, state, input, context)
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
  defp normalize_declaration(spec), do: {:error, {:invalid_input_plug_spec, spec}}

  @spec init_plug(module(), keyword()) :: {:ok, term()}
  defp init_plug(module, opts), do: {:ok, module.init(opts)}

  @spec run_plug(module(), term(), Spectre.Input.t(), map()) ::
          {:cont, {:ok, Spectre.Input.t()}}
          | {:halt, {:ok, Spectre.Input.t()} | {:error, term()}}
  defp run_plug(module, state, input, context) do
    case module.call(input, context, state) do
      {:cont, %Spectre.Input{} = input} -> {:cont, {:ok, input}}
      {:halt, %Spectre.Input{} = input} -> {:halt, {:ok, input}}
      {:error, reason} -> {:halt, {:error, {module, reason}}}
      other -> {:halt, {:error, {module, {:invalid_input_plug_return, other}}}}
    end
  rescue
    error -> {:halt, {:error, {module, error}}}
  end
end
