defmodule Spectre.Execution.Boundary do
  @moduledoc """
  Normalizes and validates the host execution boundary shared by Domain boot,
  the executor Runner and Doctor.

  Executor and broker callbacks expose stable identifiers only. Adapter options
  remain host-local and are deliberately omitted from `describe/1`, because
  they may contain credentials or other operational material that must never
  enter a diagnostic report or the ledger.
  """

  alias Spectre.{Adapter, Portable}

  @profiles [:development, :mediated, :isolated]

  @type route_key :: {String.t(), String.t()}
  @type route :: %{
          required(:executor) => module(),
          required(:executor_opts) => keyword()
        }
  @type broker :: %{
          required(:broker) => module(),
          required(:broker_opts) => keyword(),
          required(:descriptor) => %{
            required(:ref) => String.t(),
            required(:profile) => atom()
          }
        }
  @type t :: %{
          required(:routes) => %{optional(route_key()) => route()},
          required(:broker) => broker() | nil
        }
  @type runtime_route :: %{
          required(:executor) => module(),
          required(:executor_opts) => keyword(),
          required(:broker) => module(),
          required(:broker_opts) => keyword(),
          required(:broker_descriptor) => map()
        }

  @doc "Normalizes the configured executor routes and credential broker."
  @spec normalize(term(), term()) :: {:ok, t()} | {:error, term()}
  def normalize(executors, broker) do
    with {:ok, routes} <- normalize_routes(executors),
         {:ok, broker} <- normalize_broker(broker, routes) do
      {:ok, %{routes: routes, broker: broker}}
    end
  end

  @doc "Returns a deterministic, credential-free description of a normalized boundary."
  @spec describe(t()) :: map()
  def describe(%{routes: routes, broker: broker}) when is_map(routes) do
    executor_descriptors =
      routes
      |> Enum.map(fn {{executor_ref, contract_ref}, route} ->
        %{
          executor_ref: executor_ref,
          contract_ref: contract_ref,
          module: route.executor
        }
      end)
      |> Enum.sort_by(&{&1.executor_ref, &1.contract_ref})

    %{
      executors: executor_descriptors,
      broker: describe_broker(broker)
    }
  end

  @doc "Checks whether a broker profile is at least as strong as the declared profile."
  @spec profile_covers?(atom(), atom()) :: boolean()
  def profile_covers?(actual, required) when actual in @profiles and required in @profiles,
    do: profile_rank(actual) >= profile_rank(required)

  def profile_covers?(_actual, _required), do: false

  @doc "Validates the stable descriptor passed from the Sequencer to an executor runner."
  @spec validate_broker_descriptor(term()) :: :ok | {:error, :invalid_broker_descriptor}
  def validate_broker_descriptor(%{ref: ref, profile: profile} = descriptor)
      when map_size(descriptor) == 2 and profile in @profiles do
    case Portable.validate_ref(ref, :broker_ref) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_broker_descriptor}
    end
  end

  def validate_broker_descriptor(_descriptor), do: {:error, :invalid_broker_descriptor}

  @doc "Validates the exact host-only route passed across the Sequencer boundary."
  @spec validate_runtime_route(term()) :: :ok | {:error, term()}
  def validate_runtime_route(
        %{
          broker: broker,
          broker_descriptor: broker_descriptor,
          broker_opts: broker_opts,
          executor: executor,
          executor_opts: executor_opts
        } = route
      )
      when map_size(route) == 5 do
    with :ok <- callback(executor, :execute, 4, :executor),
         :ok <- callback(broker, :checkout, 4, :broker),
         :ok <- runtime_options(broker_opts, :broker_opts),
         :ok <- runtime_options(executor_opts, :executor_opts) do
      validate_broker_descriptor(broker_descriptor)
    end
  end

  def validate_runtime_route(_route), do: {:error, :invalid_execution_route}

  @doc "Invokes a validated executor or broker callback without exposing its failure payload."
  @spec invoke(module(), atom(), [term()]) ::
          {:ok, term()} | {:error, :exception | :exit | :throw}
  def invoke(module, callback, arguments) do
    case Adapter.invoke(module, callback, arguments) do
      {:ok, reply} -> {:ok, reply}
      {:error, {:adapter_callback_exception, _, _, _exception}} -> {:error, :exception}
      {:error, {:adapter_callback_failure, _, _, kind}} -> {:error, kind}
    end
  end

  defp normalize_routes(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn entry, {:ok, routes} ->
      with {:ok, {key, route}} <- normalize_route(entry),
           false <- Map.has_key?(routes, key) do
        {:cont, {:ok, Map.put(routes, key, route)}}
      else
        true -> {:halt, {:error, {:duplicate_executor_route, route_identity(entry)}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_routes(_entries), do: {:error, {:invalid_execution_boundary, :executors}}

  defp normalize_route(module) when is_atom(module), do: normalize_route({module, []})

  defp normalize_route({module, executor_opts}) do
    with :ok <- callback(module, :execute, 4, :executor),
         :ok <- callback(module, :executor_ref, 0, :executor),
         :ok <- callback(module, :contract_ref, 0, :executor),
         {:ok, executor_opts} <- normalize_opts(executor_opts, :executor),
         {:ok, executor_ref} <- static_value(module, :executor_ref, :executor),
         {:ok, contract_ref} <- static_value(module, :contract_ref, :executor),
         :ok <- Portable.validate_ref(executor_ref, :executor_ref),
         :ok <- Portable.validate_ref(contract_ref, :executor_contract_ref) do
      {:ok, {{executor_ref, contract_ref}, %{executor: module, executor_opts: executor_opts}}}
    end
  end

  defp normalize_route(_entry), do: {:error, {:invalid_execution_boundary, :executors}}

  defp normalize_broker(nil, routes) when map_size(routes) == 0, do: {:ok, nil}
  defp normalize_broker(nil, _routes), do: {:error, :execution_broker_required}

  defp normalize_broker(module, routes) when is_atom(module),
    do: normalize_broker({module, []}, routes)

  defp normalize_broker({module, broker_opts}, _routes) do
    with :ok <- callback(module, :checkout, 4, :broker),
         :ok <- callback(module, :ref, 0, :broker),
         :ok <- callback(module, :profile, 0, :broker),
         {:ok, broker_opts} <- normalize_opts(broker_opts, :broker),
         {:ok, ref} <- static_value(module, :ref, :broker),
         {:ok, profile} <- static_value(module, :profile, :broker),
         descriptor = %{ref: ref, profile: profile},
         :ok <- validate_broker_descriptor(descriptor) do
      {:ok, %{broker: module, broker_opts: broker_opts, descriptor: descriptor}}
    end
  end

  defp normalize_broker(_entry, _routes), do: {:error, {:invalid_execution_boundary, :broker}}

  defp normalize_opts(value, boundary) when is_list(value) do
    if Keyword.keyword?(value),
      do: {:ok, value},
      else: {:error, {:invalid_execution_boundary_options, boundary}}
  end

  defp normalize_opts(_value, boundary),
    do: {:error, {:invalid_execution_boundary_options, boundary}}

  defp runtime_options(value, field) when is_list(value) do
    if Keyword.keyword?(value), do: :ok, else: {:error, {:invalid_keyword_options, field}}
  end

  defp runtime_options(_value, field), do: {:error, {:invalid_keyword_options, field}}

  defp callback(module, function, arity, boundary)
       when is_atom(module) and module not in [nil, true, false] do
    case Adapter.validate(module, [{function, arity}]) do
      :ok ->
        :ok

      {:error, {:adapter_module_not_loaded, _module}} ->
        {:error, {boundary, :module_not_loaded}}

      {:error, {:adapter_callback_missing, _module, _function, _arity}} ->
        {:error, {boundary, :callback_missing}}

      {:error, _reason} ->
        {:error, {boundary, :invalid_module}}
    end
  end

  defp callback(_module, _function, _arity, boundary),
    do: {:error, {boundary, :invalid_module}}

  defp static_value(module, function, boundary) do
    case Adapter.invoke(module, function, []) do
      {:ok, value} ->
        case value do
          value when is_binary(value) and value != "" ->
            {:ok, value}

          value when function == :profile and value in @profiles ->
            {:ok, value}

          _invalid ->
            {:error, {boundary, {:invalid_static_value, function}}}
        end

      {:error, {:adapter_callback_exception, _, _, _exception}} ->
        {:error, {boundary, {function, :exception}}}

      {:error, {:adapter_callback_failure, _, _, kind}} ->
        {:error, {boundary, {function, kind}}}
    end
  end

  defp describe_broker(nil), do: nil

  defp describe_broker(%{broker: module, descriptor: descriptor}) do
    %{ref: descriptor.ref, profile: descriptor.profile, module: module}
  end

  defp route_identity({module, _opts}), do: module
  defp route_identity(module), do: module

  defp profile_rank(:development), do: 0
  defp profile_rank(:mediated), do: 1
  defp profile_rank(:isolated), do: 2
end
