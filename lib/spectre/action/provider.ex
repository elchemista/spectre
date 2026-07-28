defmodule Spectre.Action.Provider do
  @moduledoc """
  Contract and safe invocation facade for action providers.

  Providers own discovery and execution. Spectre owns provider registration,
  policy, persistence, idempotency, and the effect lifecycle.
  """

  alias Spectre.Action
  alias Spectre.Action.Provider.Mount
  alias Spectre.Action.Spec

  @type provider_result :: {:ok, term()} | {:error, term()}

  @callback actions(keyword()) ::
              [Spec.t() | map()] | {:ok, [Spec.t() | map()]} | {:error, term()}
  @callback execute(Action.t(), Spectre.Context.t(), keyword()) :: term()
  @callback schema_hash(Action.t(), keyword()) :: String.t() | nil | {:ok, String.t() | nil}

  @optional_callbacks actions: 1, schema_hash: 2

  @doc """
  Returns normalized discovery specs for a mounted provider.
  """
  @spec actions(Mount.t(), :planner | :all) :: {:ok, [Spec.t()]} | {:error, term()}
  def actions(%Mount{} = mount, visibility \\ :planner) do
    cond do
      not Code.ensure_loaded?(mount.module) ->
        {:error, {:action_provider_not_loaded, mount.id, mount.module}}

      function_exported?(mount.module, :actions, 1) ->
        module = mount.module

        with {:ok, specs} <- normalize_specs(module.actions(provider_opts(mount)), mount) do
          {:ok, filter_visibility(specs, visibility)}
        end

      true ->
        {:ok, []}
    end
  rescue
    exception ->
      {:error, {:action_provider_exception, mount.id, :actions, exception.__struct__}}
  catch
    kind, reason ->
      {:error, {:action_provider_failure, mount.id, :actions, kind, reason}}
  end

  @doc """
  Executes one action through its already-resolved provider mount.

  If a planner attached a schema hash, the provider must support schema
  verification and report the same hash before execution.
  """
  @spec execute(Mount.t(), Action.t(), Spectre.Context.t()) :: provider_result()
  def execute(%Mount{id: id} = mount, %Action{via: id} = action, %Spectre.Context{} = ctx) do
    case verify_schema(mount, action) do
      :ok -> call_execute(mount, action, ctx)
      {:error, _reason} = error -> error
    end
  end

  def execute(%Mount{} = mount, %Action{} = action, %Spectre.Context{}),
    do: {:error, {:action_provider_mismatch, action.via, mount.id}}

  @spec verify_schema(Mount.t(), Action.t()) :: :ok | {:error, term()}
  defp verify_schema(%Mount{}, %Action{schema_hash: nil}), do: :ok

  defp verify_schema(%Mount{} = mount, %Action{schema_hash: expected} = action) do
    if Code.ensure_loaded?(mount.module) and function_exported?(mount.module, :schema_hash, 2) do
      module = mount.module

      module.schema_hash(action, provider_opts(mount))
      |> normalize_schema_hash(mount.id, expected)
    else
      mount
      |> current_spec_hash(action)
      |> normalize_schema_hash(mount.id, expected)
    end
  rescue
    exception ->
      {:error, {:action_provider_exception, mount.id, :schema_hash, exception.__struct__}}
  catch
    kind, reason ->
      {:error, {:action_provider_failure, mount.id, :schema_hash, kind, reason}}
  end

  @spec normalize_schema_hash(term(), term(), String.t()) :: :ok | {:error, term()}
  defp normalize_schema_hash({:ok, hash}, id, expected),
    do: normalize_schema_hash(hash, id, expected)

  defp normalize_schema_hash({:error, reason}, id, _expected),
    do: {:error, {:action_schema_verification_failed, id, reason}}

  defp normalize_schema_hash(expected, _id, expected), do: :ok

  defp normalize_schema_hash(actual, id, expected),
    do: {:error, {:action_schema_changed, id, expected, actual}}

  @spec current_spec_hash(Mount.t(), Action.t()) :: String.t() | nil | {:error, term()}
  defp current_spec_hash(%Mount{} = mount, %Action{} = action) do
    case actions(mount, :all) do
      {:ok, specs} ->
        hashes =
          specs
          |> Enum.filter(&Action.matches_ref?({mount.id, &1.name}, action))
          |> Enum.map(& &1.schema_hash)

        if action.schema_hash in hashes, do: action.schema_hash, else: one_or_many(hashes)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec one_or_many([term()]) :: term()
  defp one_or_many([]), do: nil
  defp one_or_many([one]), do: one
  defp one_or_many(many), do: many

  @spec call_execute(Mount.t(), Action.t(), Spectre.Context.t()) :: provider_result()
  defp call_execute(%Mount{} = mount, %Action{} = action, %Spectre.Context{} = ctx) do
    cond do
      not Code.ensure_loaded?(mount.module) ->
        {:error, {:action_provider_not_loaded, mount.id, mount.module}}

      function_exported?(mount.module, :execute, 3) ->
        module = mount.module
        normalize_execute_reply(module.execute(action, ctx, provider_opts(mount)))

      function_exported?(mount.module, :execute, 2) ->
        module = mount.module
        normalize_execute_reply(module.execute(action, ctx))

      true ->
        {:error, {:invalid_action_provider, mount.id, mount.module}}
    end
  end

  @spec normalize_execute_reply(term()) :: provider_result()
  defp normalize_execute_reply({:ok, result}), do: {:ok, result}
  defp normalize_execute_reply({:error, reason}), do: {:error, reason}
  defp normalize_execute_reply(result), do: {:ok, result}

  @spec normalize_specs(term(), Mount.t()) :: {:ok, [Spec.t()]} | {:error, term()}
  defp normalize_specs({:ok, specs}, mount), do: normalize_specs(specs, mount)
  defp normalize_specs({:error, reason}, _mount), do: {:error, reason}

  defp normalize_specs(specs, %Mount{} = mount) when is_list(specs) do
    {:ok,
     Enum.map(specs, fn
       %Spec{via: via} = spec when via == mount.id ->
         spec

       %Spec{} = spec ->
         spec
         |> Map.from_struct()
         |> Map.put(:via, mount.id)
         |> Map.put(:schema_hash, nil)
         |> Spec.new()

       spec when is_map(spec) ->
         spec |> Map.put(:via, mount.id) |> Spec.new()
     end)}
  rescue
    exception ->
      {:error, {:invalid_action_specs, mount.id, exception.__struct__}}
  end

  defp normalize_specs(other, %Mount{} = mount),
    do: {:error, {:invalid_action_specs, mount.id, other}}

  @spec filter_visibility([Spec.t()], :planner | :all) :: [Spec.t()]
  defp filter_visibility(specs, :all), do: specs
  defp filter_visibility(specs, :planner), do: Enum.filter(specs, &Spec.planner_visible?/1)

  defp filter_visibility(_specs, other),
    do: raise(ArgumentError, "invalid action visibility filter: #{inspect(other)}")

  @spec provider_opts(Mount.t()) :: keyword()
  defp provider_opts(%Mount{} = mount),
    do: Keyword.put(mount.opts, :provider_id, mount.id)
end
