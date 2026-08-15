defmodule Spectre.Action.Provider do
  @moduledoc """
  Contract and safe invocation facade for action providers.

  Providers own discovery and execution. Spectre owns provider registration,
  policy, persistence, idempotency, and the effect lifecycle.

  Discovery through `actions/1` must be side-effect free. Runtime planning and
  read-only diagnostics may call it without starting provider resources.
  """

  alias Spectre.Action
  alias Spectre.Action.Provider.Mount
  alias Spectre.Action.Schema
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
    with :ok <- verify_schema(mount, action),
         :ok <- validate_arguments(mount, action) do
      call_execute(mount, action, ctx)
    end
  end

  def execute(%Mount{} = mount, %Action{} = action, %Spectre.Context{}),
    do: {:error, {:action_provider_mismatch, action.via, mount.id}}

  @doc "Validates arguments against the exact provider spec selected for an action."
  @spec validate_arguments(Mount.t(), Action.t()) :: :ok | {:error, term()}
  def validate_arguments(%Mount{} = mount, %Action{} = action) do
    with {:ok, spec} <- action_spec(mount, action) do
      case spec do
        nil -> :ok
        %Spec{} -> Schema.validate(spec.schema, action.args)
      end
    end
  end

  @doc false
  @spec legacy_schema_free_local?(Mount.t()) :: boolean()
  def legacy_schema_free_local?(%Mount{
        id: :local,
        module: Spectre.Action.Provider.Local,
        opts: opts
      }) do
    case Keyword.get(opts, :module) do
      module when is_atom(module) and not is_nil(module) ->
        Code.ensure_loaded?(module) and not function_exported?(module, :__spectre_actions__, 0)

      _other ->
        false
    end
  end

  def legacy_schema_free_local?(%Mount{}), do: false

  @spec action_spec(Mount.t(), Action.t()) :: {:ok, Spec.t() | nil} | {:error, term()}
  defp action_spec(%Mount{} = mount, %Action{} = action) do
    case actions(mount, :all) do
      {:ok, specs} -> select_action_spec(specs, mount, action)
      {:error, {:action_provider_not_loaded, _id, _module} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:action_schema_unavailable, mount.id, reason}}
    end
  end

  defp select_action_spec(specs, mount, action) do
    candidates = Enum.filter(specs, &Action.matches_ref?({mount.id, &1.name}, action))

    selected =
      case action.schema_hash do
        hash when is_binary(hash) -> Enum.filter(candidates, &(&1.schema_hash == hash))
        nil -> candidates
      end

    case selected do
      [spec] ->
        {:ok, spec}

      [] ->
        missing_action_spec(mount, action)

      _multiple ->
        {:error, {:ambiguous_action_argument_schema, mount.id, action.name}}
    end
  end

  defp missing_action_spec(%Mount{id: :local} = mount, action) do
    if legacy_schema_free_local?(mount) do
      # `actions MyApp.Actions` predates provider discovery. Keep that trusted,
      # locally mounted boundary compatible while requiring a catalog for every
      # discoverable or external model-planned action.
      {:ok, nil}
    else
      {:error, {:action_argument_schema_unavailable, mount.id, action.name}}
    end
  end

  defp missing_action_spec(mount, action)
       when not is_nil(action.schema_hash) or not is_nil(action.planned_by),
       do: {:error, {:action_argument_schema_unavailable, mount.id, action.name}}

  # Providers predating discovery remain usable for deterministic DSL actions.
  # Model-planned actions are rejected by the clause above.
  defp missing_action_spec(_mount, _action), do: {:ok, nil}

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
