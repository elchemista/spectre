defmodule Spectre.Server.GAM.Effect do
  @moduledoc """
  Resolves closed Stack execution registrations for the managed GAM bridge.

  Resolution verifies the Agent's immutable installation references. The
  resulting contract digest covers the registration and installation, including
  the action schema. It is checked again immediately before an admitted attempt.
  This module neither creates authority nor performs admission.
  """

  alias Spectre.GAM.Canonical.Value, as: CanonicalValue
  alias Spectre.Stack.{Binding, Definition, Effects, Value}

  @type t :: %{
          required(:host_operation) => atom() | binary() | tuple(),
          required(:adapter) => module(),
          required(:operation) => atom() | binary(),
          required(:side_effect) => :none | :idempotent | :reconcilable | :non_idempotent,
          required(:material) => :arguments,
          required(:partition) => [atom()],
          required(:schema_hash) => binary() | nil,
          required(:config) => map(),
          required(:installation) => Spectre.Stack.Installation.t(),
          required(:contract_ref) => binary(),
          optional(atom()) => term()
        }
  @type result :: {:ok, term()} | {:error, :failed | :definitive_no_effect | :ambiguous, term()}

  @doc "Returns the registered effects in an Agent's selected Stack."
  @spec catalog(module()) :: {:ok, map()} | {:error, term()}
  def catalog(agent) do
    with {:ok, definition} <- Spectre.Definition.fetch(agent),
         stack when not is_nil(stack) <- definition.stack,
         {:ok, stack} <- Definition.fetch(stack) do
      Enum.reduce_while(stack.installations, {:ok, %{}}, &collect_installation(agent, &1, &2))
    else
      nil -> {:error, :agent_has_no_stack}
      {:error, _} = error -> error
    end
  end

  @doc "Resolves an operation to its explicitly registered execution adapter."
  @spec resolve(module(), term(), map(), map()) :: {:ok, t()} | {:error, term()}
  def resolve(agent, operation, metadata \\ %{}, _context \\ %{}) do
    with {:ok, catalog} <- catalog(agent),
         {:ok, effect} <- fetch_effect(catalog, operation),
         :ok <- validate_metadata(effect, metadata),
         :ok <- adapter_available(effect.adapter) do
      {:ok, Map.put(effect, :host_operation, operation)}
    end
  end

  @doc "Executes a frozen admitted effect through its registered adapter, without retry."
  @spec execute(t(), map(), map()) :: result()
  def execute(effect, args, context) when is_map(effect) and is_map(args) and is_map(context) do
    with {:ok, current} <- resolve(context.agent, effect.host_operation),
         true <- current.contract_ref == effect.contract_ref,
         :ok <- CanonicalValue.validate(args),
         :ok <- identity_available(effect.partition, context) do
      invoke(effect, args, context)
    else
      false -> {:error, :definitive_no_effect, :effect_contract_changed}
      {:error, reason} -> {:error, :definitive_no_effect, reason}
    end
  end

  def execute(_effect, _args, _context),
    do: {:error, :definitive_no_effect, :invalid_effect_execution}

  @spec collect_installation(module(), Spectre.Stack.Installation.t(), {:ok, map()}) ::
          {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp collect_installation(agent, installation, {:ok, effects}) do
    with {:ok, installation} <- Binding.installation(agent, installation.id),
         {:ok, entries} <- registrations(installation),
         :ok <- unique_operations(effects, entries) do
      {:cont, {:ok, Map.merge(effects, entries)}}
    else
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @spec registrations(Spectre.Stack.Installation.t()) :: {:ok, map()} | {:error, term()}
  defp registrations(installation) do
    entries = installation.adapters |> Map.get(:effects, %{}) |> Effects.validate!()

    Enum.reduce_while(entries, {:ok, %{}}, fn {operation, descriptor}, {:ok, effects} ->
      case resolved_schema(descriptor, installation) do
        {:ok, descriptor} ->
          digest = Value.digest(%{installation: installation.digest, descriptor: descriptor})

          effect =
            Map.merge(descriptor, %{
              host_operation: operation,
              installation: installation,
              contract_ref: "spectre:effect:" <> digest
            })

          {:cont, {:ok, Map.put(effects, operation, effect)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  rescue
    error in ArgumentError -> {:error, {:invalid_effect_registration, Exception.message(error)}}
  end

  @spec unique_operations(map(), map()) :: :ok | {:error, term()}
  defp unique_operations(existing, entries) do
    case Enum.find(Map.keys(entries), &Map.has_key?(existing, &1)) do
      nil -> :ok
      duplicate -> {:error, {:duplicate_effect_operation, duplicate}}
    end
  end

  @spec resolved_schema(map(), Spectre.Stack.Installation.t()) :: {:ok, map()} | {:error, term()}
  defp resolved_schema(descriptor, installation) do
    adapter = descriptor.adapter

    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :effect_schema, 2) do
      case adapter.effect_schema(descriptor.operation, %{
             config: descriptor.config,
             installation: installation
           }) do
        {:ok, hash} when is_binary(hash) and byte_size(hash) > 0 ->
          {:ok, Map.put(descriptor, :schema_hash, hash)}

        {:error, reason} ->
          {:error, reason}

        _ ->
          {:error, :invalid_effect_schema}
      end
    else
      {:ok, descriptor}
    end
  end

  @spec fetch_effect(map(), term()) :: {:ok, t()} | {:error, term()}
  defp fetch_effect(catalog, {{:skill, _mount}, provider, name}),
    do: fetch_effect(catalog, {provider, name})

  defp fetch_effect(catalog, operation) do
    case Map.fetch(catalog, operation) do
      {:ok, effect} -> {:ok, effect}
      :error -> {:error, {:unregistered_effect, operation}}
    end
  end

  @spec validate_metadata(t(), map()) :: :ok | {:error, term()}
  defp validate_metadata(effect, metadata) when is_map(metadata) do
    case Map.get(metadata, :schema_hash) do
      nil -> :ok
      hash when hash == effect.schema_hash -> :ok
      _ -> {:error, :effect_schema_mismatch}
    end
  end

  defp validate_metadata(_effect, _metadata), do: {:error, :invalid_effect_metadata}

  @spec adapter_available(module()) :: :ok | {:error, term()}
  defp adapter_available(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :execute_effect, 3),
      do: :ok,
      else: {:error, {:effect_adapter_unavailable, adapter}}
  end

  @spec identity_available([atom()], map()) :: :ok | {:error, term()}
  defp identity_available(partition, context) do
    identity = Map.get(context, :identity, %{})

    case Enum.find(partition, fn
           :flow -> is_nil(Map.get(context, :current_flow))
           field -> is_nil(Map.get(identity, field))
         end) do
      nil -> :ok
      field -> {:error, {:effect_identity_required, field}}
    end
  end

  @spec invoke(t(), map(), map()) :: result()
  defp invoke(effect, args, context) do
    adapter_context =
      context
      |> Map.take([:agent, :identity, :command_id, :skill, :activity, :input, :current_flow])
      |> Map.put(
        :options,
        Keyword.take(Map.get(context, :options, []), [:stack_runtime, :namespace])
      )
      |> Map.put(:installation, effect.installation)
      |> Map.put(:effect_config, effect.config)
      |> Map.put(:effect_schema_hash, effect.schema_hash)

    normalize_result(effect.adapter.execute_effect(effect.operation, args, adapter_context))
  rescue
    _ -> {:error, :ambiguous, :effect_adapter_exception}
  catch
    _, _ -> {:error, :ambiguous, :effect_adapter_failure}
  end

  @spec normalize_result(term()) :: result()
  defp normalize_result({:ok, receipt}) do
    if CanonicalValue.validate(receipt) == :ok,
      do: {:ok, receipt},
      else: {:error, :ambiguous, :effect_receipt_not_portable}
  end

  defp normalize_result({:error, status, reason})
       when status in [:failed, :definitive_no_effect, :ambiguous] do
    if CanonicalValue.validate(reason) == :ok,
      do: {:error, status, reason},
      else: {:error, status, :effect_error_details_unavailable}
  end

  defp normalize_result(_), do: {:error, :ambiguous, :invalid_effect_adapter_result}
end
