defmodule Spectre.Input.Pipeline do
  @moduledoc """
  Runs input plugs before the Spectre runtime handles a turn.

  Input normalization is a boundary concern. By running it before state loading,
  policy matching, and routing, the rest of the runtime can depend on one
  internal `%Spectre.Input{}` shape instead of repeatedly handling raw host
  payloads.

      specs = [
        {Spectre.Input.Plugs.NormalizeText, trim?: true, case: :downcase}
      ]

      {:ok, input} =
        Spectre.Input.Pipeline.run(
          Spectre.Input.new("  HELLO  "),
          %{agent: MyApp.Agent, opts: []},
          specs
        )
  """

  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure

  defmodule Spec do
    @moduledoc """
    Initialized input plug declaration.

    Specs store the plug module and initialized state separately so plug
    initialization happens once when possible, while `run/3` stays focused on
    passing the input through the pipeline.
    """

    defstruct [:module, :state]

    @type t :: %__MODULE__{module: module(), state: term()}
  end

  @type plug_spec :: module() | {module(), keyword()} | Spec.t()

  @doc """
  Initializes input plug specs.

  Use this when a host process wants to prepare a reusable pipeline once and run
  it for many turns.
  """
  @spec init_specs([plug_spec()], keyword()) :: {:ok, [Spec.t()]} | {:error, term()}
  def init_specs(specs, callback_opts \\ []) when is_list(specs) and is_list(callback_opts) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      with {:ok, {module, opts}} <- normalize_declaration(spec),
           {:ok, state} <- init_plug(module, opts, callback_opts) do
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

  A plug may continue with a new input, halt with a final input, or return an
  error. Halting is useful when a boundary plug can fully normalize or reject a
  turn before router/runtime work starts.
  """
  @spec run(Spectre.Input.t(), map(), [plug_spec()]) ::
          {:ok, Spectre.Input.t()} | {:error, term()}
  def run(%Spectre.Input{} = input, context, specs) when is_map(context) and is_list(specs) do
    callback_opts = Map.get(context, :opts, [])

    Enum.reduce_while(specs, {:ok, input}, fn spec, {:ok, input} ->
      case normalize_spec(spec, callback_opts) do
        {:ok, {module, state}} -> run_plug(module, state, input, context, callback_opts)
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec normalize_spec(plug_spec(), keyword()) ::
          {:ok, {module(), term()}} | {:error, term()}
  defp normalize_spec(%Spec{module: module, state: state}, _callback_opts) when is_atom(module),
    do: {:ok, {module, state}}

  defp normalize_spec(spec, callback_opts) do
    with {:ok, {module, opts}} <- normalize_declaration(spec),
         {:ok, state} <- init_plug(module, opts, callback_opts) do
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

  @spec init_plug(module(), keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  defp init_plug(module, opts, callback_opts) do
    Call.run(
      :input,
      fn -> {:ok, module.init(opts)} end,
      callback_opts |> Call.adapter_opts() |> Keyword.put(:purpose, :input_plug_init)
    )
  end

  @spec run_plug(module(), term(), Spectre.Input.t(), map(), keyword()) ::
          {:cont, {:ok, Spectre.Input.t()}}
          | {:halt, {:ok, Spectre.Input.t()} | {:error, term()}}
  defp run_plug(module, state, input, context, callback_opts) do
    result =
      Call.run(
        :input,
        fn -> module.call(input, context, state) |> normalize_plug_reply() end,
        callback_opts |> Call.adapter_opts() |> Keyword.put(:purpose, :input_plug_call)
      )

    case result do
      {:ok, {:cont, input}} -> {:cont, {:ok, input}}
      {:ok, {:halt, input}} -> {:halt, {:ok, input}}
      {:error, reason} -> {:halt, {:error, {module, reason}}}
    end
  end

  @spec normalize_plug_reply(term()) ::
          {:ok, {:cont | :halt, Spectre.Input.t()}} | {:error, term()}
  defp normalize_plug_reply({:cont, %Spectre.Input{} = input}), do: {:ok, {:cont, input}}
  defp normalize_plug_reply({:halt, %Spectre.Input{} = input}), do: {:ok, {:halt, input}}
  defp normalize_plug_reply({:error, reason}), do: {:error, reason}

  defp normalize_plug_reply(other),
    do: {:error, Failure.invalid_reply(:input, other)}
end
