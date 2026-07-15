defmodule Spectre.ActionPlanner do
  @moduledoc """
  Optional SpectreKinetic planning boundary.

  Spectre delegates Action Language extraction and planning to SpectreKinetic.
  This module intentionally does not parse AL locally.

  The boundary matters because AL planning is a tool-selection concern, while
  Spectre owns only the conversation runtime and action safety gates.
  """

  alias Spectre.Effect

  @doc """
  Scans an LLM reply for AL blocks and returns visible text plus staged effects.

      {:ok, %{reply_text: text, effects: effects}} =
        Spectre.ActionPlanner.plan_response(model_reply, actions_module: MyApp.Actions)
  """
  @spec plan_response(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def plan_response(text, opts \\ []) when is_binary(text) do
    scan = scan_response(text)

    if scan.entries == [] do
      {:ok, %{reply_text: scan.clean_text, effects: []}}
    else
      kinetic_plan_response(text, scan, opts)
    end
  end

  @doc """
  Plans a single AL block without executing it.

      {:ok, effect} = Spectre.ActionPlanner.plan("DELETE ACCOUNT", actions_module: MyApp.Actions)
  """
  @spec plan(String.t(), keyword()) :: {:ok, Effect.t()} | {:error, term()}
  def plan(al, opts \\ []) when is_binary(al) do
    with {:ok, action} <- kinetic_plan(al, opts),
         action <- prefer_exact_al_tool(action, al, opts),
         :ok <- validate_planned_action(action, 0) do
      {:ok, Effect.stage(action)}
    end
  end

  @doc """
  Cleans a model reply using Kinetic extraction when available.

      visible_text = Spectre.ActionPlanner.clean_reply(model_reply)
  """
  @spec clean_reply(String.t()) :: String.t()
  def clean_reply(text) when is_binary(text), do: scan_response(text).clean_text

  @spec kinetic_plan_response(String.t(), map(), keyword()) ::
          {:ok, %{reply_text: String.t(), effects: [Effect.t()]}} | {:error, term()}
  defp kinetic_plan_response(text, scan, opts) do
    kinetic = kinetic_module()

    with true <- Code.ensure_loaded?(kinetic),
         {:ok, runtime} <- kinetic_runtime(opts),
         # credo:disable-for-next-line Credo.Check.Refactor.Apply
         {:ok, chain} <- apply(kinetic, :plan_chain, [runtime, text, plan_opts(opts)]),
         {:ok, actions} <- planned_actions(chain),
         actions <- Enum.map(actions, &prefer_exact_al_tool(&1, action_al(&1), opts)),
         :ok <- validate_planned_actions(actions) do
      effects = Enum.map(actions, &Effect.stage/1)
      {:ok, %{reply_text: scan.clean_text, effects: effects}}
    else
      false -> {:error, :spectre_kinetic_not_loaded}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec planned_actions(term()) :: {:ok, [map() | struct()]} | {:error, term()}
  defp planned_actions(%{actions: actions}) when is_list(actions), do: {:ok, actions}
  defp planned_actions(other), do: {:error, {:invalid_action_chain, other}}

  @spec validate_planned_actions([map() | struct()]) :: :ok | {:error, term()}
  defp validate_planned_actions(actions) do
    actions
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {action, index}, :ok ->
      case validate_planned_action(action, index) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec validate_planned_action(map() | struct(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp validate_planned_action(action, index) when is_map(action) do
    status = action_value(action, :status)
    selected_tool = action_value(action, :selected_tool)
    args = action_value(action, :args)

    cond do
      action_value(action, :halted?) == true ->
        {:error, {:action_plan_halted, index, status}}

      status not in [:ok, "ok"] ->
        {:error, {:action_plan_not_executable, index, status}}

      not is_binary(selected_tool) or String.trim(selected_tool) == "" ->
        {:error, {:action_plan_missing_tool, index}}

      not is_map(args) ->
        {:error, {:invalid_action_args, index, args}}

      true ->
        :ok
    end
  end

  defp validate_planned_action(action, index),
    do: {:error, {:invalid_planned_action, index, action}}

  @spec action_al(map() | struct()) :: String.t() | nil
  defp action_al(action), do: action_value(action, :al)

  @spec action_value(map() | struct(), atom()) :: term()
  defp action_value(action, key) when is_map(action) do
    Map.get(action, key) || Map.get(action, Atom.to_string(key))
  end

  @spec kinetic_plan(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp kinetic_plan(al, opts) do
    kinetic = kinetic_module()

    with true <- Code.ensure_loaded?(kinetic),
         {:ok, runtime} <- kinetic_runtime(opts) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(kinetic, :plan, [runtime, al, plan_opts(opts)])
    else
      false -> {:error, :spectre_kinetic_not_loaded}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec kinetic_runtime(keyword()) :: {:ok, term()} | {:error, term()}
  defp kinetic_runtime(opts) do
    cond do
      runtime = Keyword.get(opts, :runtime) ->
        {:ok, runtime}

      runtime = Application.get_env(:spectre, :spectre_kinetic_runtime) ->
        {:ok, runtime}

      configured_path(:compiled_registry) ->
        load_runtime([compiled_registry: configured_path(:compiled_registry)], opts)

      configured_path(:registry_json) ->
        load_runtime([registry_json: configured_path(:registry_json)], opts)

      Keyword.get(opts, :actions_module) ->
        load_extracted_actions_runtime(opts)

      true ->
        load_runtime([], opts)
    end
  end

  @spec load_runtime(keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  defp load_runtime(runtime_opts, opts) do
    if function_exported?(kinetic_module(), :load_runtime, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(kinetic_module(), :load_runtime, [runtime_opts(runtime_opts, opts)])
    else
      {:error, :spectre_kinetic_not_loaded}
    end
  end

  @spec load_extracted_actions_runtime(keyword()) :: {:ok, term()} | {:error, term()}
  defp load_extracted_actions_runtime(opts) do
    actions_module = Keyword.fetch!(opts, :actions_module)

    with {:ok, actions} <- extract_actions(actions_module),
         {:ok, path} <- write_temp_registry(actions, actions_module) do
      load_runtime([registry_json: path], opts)
    end
  end

  @spec extract_actions(module()) :: {:ok, [map()]} | {:error, term()}
  defp extract_actions(actions_module) do
    extractor = Module.concat(["SpectreKinetic.Tool.Extractor"])

    if Code.ensure_loaded?(extractor) and function_exported?(extractor, :extract_module, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(extractor, :extract_module, [actions_module])
    else
      {:error, :spectre_kinetic_extractor_not_loaded}
    end
  end

  @spec write_temp_registry([map()], module()) :: {:ok, String.t()} | {:error, term()}
  defp write_temp_registry(actions, actions_module) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{actions_module |> inspect() |> String.replace(".", "_")}_spectre_actions_#{System.unique_integer([:positive])}.json"
      )

    case Jason.encode(%{"actions" => actions}) do
      {:ok, json} -> write_registry(path, json)
      {:error, reason} -> {:error, {:registry_encode_failed, reason}}
    end
  end

  @spec write_registry(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp write_registry(path, json) do
    case File.write(path, json) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec scan_response(String.t()) :: %{clean_text: String.t(), entries: [map()]}
  defp scan_response(text) do
    kinetic = kinetic_module()

    if Code.ensure_loaded?(kinetic) and function_exported?(kinetic, :extract_al_scan, 1) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(kinetic, :extract_al_scan, [text])
    else
      %{clean_text: String.trim(text), entries: []}
    end
  end

  @spec kinetic_module() :: module()
  defp kinetic_module, do: Module.concat(["SpectreKinetic"])

  @spec plan_opts(keyword()) :: keyword()
  defp plan_opts(opts) do
    Keyword.take(opts, [
      :slots,
      :top_k,
      :tool_threshold,
      :mapping_threshold,
      :tool_selection_fallback,
      :fallback_top_k,
      :fallback_margin,
      :classifiers
    ])
  end

  @spec runtime_opts(keyword(), keyword()) :: keyword()
  defp runtime_opts(runtime_opts, opts) do
    opts
    |> Keyword.take([:encoder_model_dir, :tool_threshold, :mapping_threshold, :top_k])
    |> Keyword.merge(runtime_opts)
    |> Keyword.put_new(:classifiers, default_classifiers(opts))
  end

  @spec default_classifiers(keyword()) :: list()
  defp default_classifiers(opts) do
    Keyword.get(opts, :classifiers) ||
      Application.get_env(:spectre, :spectre_kinetic_classifiers) ||
      Application.get_env(:spectre_kinetic, :classifiers) ||
      []
  end

  @spec configured_path(atom()) :: String.t() | nil
  defp configured_path(key) do
    value = Application.get_env(:spectre_kinetic, key) || System.get_env(env_name(key))
    if is_binary(value) and File.exists?(value), do: value
  end

  @spec env_name(atom()) :: String.t()
  defp env_name(:compiled_registry), do: "SPECTRE_KINETIC_COMPILED_REGISTRY"
  defp env_name(:registry_json), do: "SPECTRE_KINETIC_REGISTRY_JSON"

  @spec prefer_exact_al_tool(struct() | map(), String.t() | nil, keyword()) :: struct() | map()
  defp prefer_exact_al_tool(plan, nil, _opts), do: plan

  defp prefer_exact_al_tool(plan, al, opts) do
    case exact_tool_id(al, opts) do
      nil -> plan
      selected_tool -> Map.put(plan, :selected_tool, selected_tool)
    end
  end

  @spec exact_tool_id(String.t(), keyword()) :: String.t() | nil
  defp exact_tool_id(al, opts) do
    actions_module = Keyword.get(opts, :actions_module)
    normalized = normalize_al(al)

    if is_nil(actions_module) do
      nil
    else
      actions_module
      |> spectre_tools()
      |> Enum.find(&(normalize_al(&1.al) == normalized))
      |> case do
        nil -> nil
        tool -> "Elixir.#{inspect(actions_module)}.#{tool.function}/#{tool.arity}"
      end
    end
  end

  @spec spectre_tools(module()) :: [map()]
  defp spectre_tools(actions_module) do
    actions_module.__spectre_tools__()
  rescue
    _exception -> []
  catch
    _kind, _reason -> []
  end

  @spec normalize_al(String.t()) :: String.t()
  defp normalize_al(al) do
    al
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
end
