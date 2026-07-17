defmodule Spectre.Router.Evaluator do
  @moduledoc false

  alias Spectre.Context
  alias Spectre.Input
  alias Spectre.Input.Pipeline
  alias Spectre.Router
  alias Spectre.Router.Receipt
  alias Spectre.State

  @agent_config_keys [:model, :classifier, :adapter, :embedding, :input_pipeline]
  @state_keys State.__struct__() |> Map.keys() |> List.delete(:__struct__)

  @spec evaluate(module(), Input.t() | String.t() | map(), keyword()) :: {:ok, Receipt.t()}
  def evaluate(agent, input, opts) when is_atom(agent) and is_list(opts) do
    started_at = System.monotonic_time()
    observer_ref = make_ref()

    result =
      try do
        with :ok <- validate_agent(agent),
             opts <-
               agent
               |> evaluation_opts(opts)
               |> Keyword.put(:spectre_provider_observer, {self(), observer_ref}),
             {:ok, state} <- evaluation_state(agent, Keyword.get(opts, :state)),
             {:ok, input} <- normalize_input(agent, Input.new(input), opts) do
          context = runtime_context(agent, input, state, opts)
          Router.route_context(input, context)
        end
      rescue
        exception ->
          {:error,
           {:routing_evaluation_exception, exception.__struct__, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {:routing_evaluation_failure, kind, reason}}
      end

    duration_us = elapsed_us(started_at)
    provider_calls = collect_provider_calls(observer_ref)

    try do
      case result do
        {:ok, router_context} ->
          {:ok, Receipt.from_context(router_context, duration_us, provider_calls)}

        {:error, reason} ->
          {:ok, Receipt.from_error(reason, duration_us, provider_calls)}
      end
    rescue
      exception ->
        {:ok,
         Receipt.from_error(
           {:routing_receipt_exception, exception.__struct__, Exception.message(exception)},
           duration_us,
           provider_calls
         )}
    catch
      kind, reason ->
        {:ok,
         Receipt.from_error(
           {:routing_receipt_failure, kind, reason},
           duration_us,
           provider_calls
         )}
    end
  end

  @spec validate_agent(module()) :: :ok | {:error, term()}
  defp validate_agent(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_config__, 0) and
         function_exported?(agent, :__spectre_router__, 0) and
         function_exported?(agent, :__spectre_rules__, 0) do
      :ok
    else
      {:error, {:invalid_spectre_agent, agent}}
    end
  end

  @spec evaluation_opts(module(), keyword()) :: keyword()
  defp evaluation_opts(agent, opts) do
    agent.__spectre_config__()
    |> Keyword.take(@agent_config_keys)
    |> Keyword.merge(opts)
    |> Keyword.put(:journal, false)
    |> Keyword.put(:semantic_learn?, false)
    |> Keyword.put(:evaluation?, true)
    |> Keyword.put_new(:classification_log?, false)
  end

  @spec normalize_input(module(), Input.t(), keyword()) :: {:ok, Input.t()} | {:error, term()}
  defp normalize_input(agent, input, opts) do
    case Keyword.get(opts, :input_pipeline, []) do
      [] -> {:ok, input}
      specs when is_list(specs) -> Pipeline.run(input, %{agent: agent, opts: opts}, specs)
      other -> {:error, {:invalid_input_pipeline, other}}
    end
  end

  @spec evaluation_state(module(), State.t() | map() | keyword() | nil) ::
          {:ok, State.t()} | {:error, term()}
  defp evaluation_state(_agent, %State{} = state), do: {:ok, state}
  defp evaluation_state(_agent, nil), do: {:ok, %State{}}

  defp evaluation_state(agent, state) when is_map(state) or is_list(state) do
    state = if is_list(state), do: Map.new(state), else: state

    normalized =
      Enum.reduce(@state_keys, %{}, fn key, normalized ->
        case fetch_known_key(state, key) do
          {:ok, value} -> Map.put(normalized, key, value)
          :error -> normalized
        end
      end)
      |> normalize_state_data()

    with {:ok, current_flow} <- normalize_current_flow(agent, Map.get(normalized, :current_flow)) do
      {:ok, normalized |> Map.put(:current_flow, current_flow) |> State.new()}
    end
  rescue
    error -> {:error, {:invalid_evaluation_state, error}}
  end

  defp evaluation_state(_agent, state), do: {:error, {:invalid_evaluation_state, state}}

  @spec fetch_known_key(map(), atom()) :: {:ok, term()} | :error
  defp fetch_known_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

  @spec normalize_state_data(map()) :: map()
  defp normalize_state_data(%{data: data} = state) when is_map(data) do
    data =
      case Map.fetch(data, "chat_history") do
        {:ok, history} -> Map.put_new(data, :chat_history, history)
        :error -> data
      end

    %{state | data: data}
  end

  defp normalize_state_data(state), do: state

  @spec normalize_current_flow(module(), atom() | String.t() | nil) ::
          {:ok, atom() | nil} | {:error, term()}
  defp normalize_current_flow(_agent, flow) when is_atom(flow) or is_nil(flow), do: {:ok, flow}

  defp normalize_current_flow(agent, flow) when is_binary(flow) do
    available_flows =
      agent.__spectre_rules__()
      |> Enum.map(&Map.get(&1, :flow))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case Enum.find(available_flows, &(canonical_flow(&1) == canonical_flow(flow))) do
      nil -> {:error, {:unknown_evaluation_flow, flow}}
      existing -> {:ok, existing}
    end
  end

  defp normalize_current_flow(_agent, flow), do: {:error, {:invalid_evaluation_flow, flow}}

  @spec canonical_flow(atom() | String.t()) :: String.t()
  defp canonical_flow(flow), do: flow |> to_string() |> String.upcase()

  @spec runtime_context(module(), Input.t(), State.t(), keyword()) :: Context.t()
  defp runtime_context(agent, input, state, opts) do
    %Context{
      agent: agent,
      input: input,
      state: state,
      opts: opts,
      assigns: Keyword.get(opts, :assigns, %{})
    }
  end

  @spec elapsed_us(integer()) :: non_neg_integer()
  defp elapsed_us(started_at) do
    started_at
    |> then(&(System.monotonic_time() - &1))
    |> System.convert_time_unit(:native, :microsecond)
  end

  @spec collect_provider_calls(reference(), [map()]) :: [map()]
  defp collect_provider_calls(reference, calls \\ []) do
    receive do
      {:spectre_provider_call, ^reference, call} when is_map(call) ->
        collect_provider_calls(reference, [call | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end
end
