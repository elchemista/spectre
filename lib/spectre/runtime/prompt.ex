defmodule Spectre.Prompt do
  @moduledoc """
  Prompt resolver, renderer, and typed composition boundary.

  A base `ask` prompt is represented as the task section of a
  `Spectre.Prompt.Plan`. Agent, Skill, Flow, and handler `inject` declarations
  resolve into typed fragments before the plan is serialized for the current
  string-based LLM adapter.
  """

  alias Spectre.Definition
  alias Spectre.Prompt.Operation
  alias Spectre.Prompt.Plan
  alias Spectre.Provider.Call

  @default_max_fragment_bytes 64_000
  @default_max_prompt_bytes 256_000

  @doc """
  Resolves, composes, and renders a prompt for a model-backed turn.

      {:ok, text} = Spectre.Prompt.render(MyAgent, :welcome, ctx)
  """
  @spec render(module(), atom() | String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def render(agent, prompt, ctx, opts \\ []) do
    with {:ok, %Plan{} = plan} <- build(agent, prompt, ctx, opts) do
      {:ok, plan.rendered}
    end
  end

  @doc false
  @spec render_asset(module(), atom() | String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def render_asset(agent, prompt, ctx, opts \\ []) do
    scope = prompt_scope(ctx, opts)
    do_render_asset(agent, prompt, ctx, Keyword.put(opts, :prompt_scope, scope))
  end

  @doc """
  Builds the fully resolved prompt plan used by a model call.
  """
  @spec build(module(), atom() | String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def build(agent, prompt, ctx, opts \\ []) do
    scope = prompt_scope(ctx, opts)
    opts = Keyword.put(opts, :prompt_scope, scope)

    with {:ok, base_task} <- do_render_asset(agent, prompt, ctx, opts),
         {:ok, operations, scopes} <- prompt_operations(agent, ctx, opts, scope),
         :ok <- validate_operation_ids(operations),
         {:ok, resolutions} <- resolve_operations(agent, operations, ctx, opts),
         {:ok, plan} <- Plan.compose(base_task, resolutions, scopes),
         :ok <- validate_plan_size(plan, opts) do
      {:ok, plan}
    end
  end

  @doc """
  Resolves a prompt name or relative path under the active definition's prompt
  root.

  Policy prompts are looked up under `policies/<policy>/<prompt>.text.heex`.
  Resolved paths must remain inside the configured root.
  """
  @spec resolve(module(), atom() | String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve(agent, prompt, ctx, opts \\ []) do
    scope = prompt_scope(ctx, opts)

    with {:ok, root} <- Definition.prompt_root(agent, scope),
         {:ok, relative} <- relative_prompt(prompt, ctx, opts),
         {:ok, path} <- contained_path(root, relative) do
      if File.regular?(path), do: {:ok, path}, else: {:error, {:missing_prompt, path}}
    end
  end

  @spec do_render_asset(module(), atom() | String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp do_render_asset(agent, prompt, ctx, opts) do
    with {:ok, path} <- resolve(agent, prompt, ctx, opts),
         {:ok, text} <- File.read(path) do
      {:ok, eval_heexish(text, assigns(ctx, opts), path)}
    end
  rescue
    exception ->
      {:error, {:prompt_render_exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:prompt_render_failure, kind, reason}}
  end

  @spec relative_prompt(atom() | String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp relative_prompt(prompt, ctx, opts) do
    policy = Keyword.get(opts, :policy) || active_policy(ctx)
    policy_name = Definition.policy_name(policy)

    cond do
      Keyword.get(opts, :policy_prompt?) && policy_name && is_atom(prompt) ->
        {:ok, Path.join(["policies", to_string(policy_name), "#{prompt}.text.heex"])}

      is_atom(prompt) ->
        {:ok, "#{prompt}.text.heex"}

      is_binary(prompt) ->
        {:ok, prompt}

      true ->
        {:error, {:invalid_prompt, prompt}}
    end
  end

  @spec contained_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  defp contained_path(root, relative) when is_binary(root) and is_binary(relative) do
    expanded_root = Path.expand(root)
    path = Path.expand(relative, expanded_root)

    with true <- inside_root?(path, expanded_root),
         {:ok, canonical_root} <- canonical_path(expanded_root),
         {:ok, canonical_path} <- canonical_path(path),
         true <- inside_root?(canonical_path, canonical_root) do
      {:ok, canonical_path}
    else
      false -> {:error, {:prompt_outside_root, path, expanded_root}}
      {:error, _reason} = error -> error
    end
  end

  @spec inside_root?(String.t(), String.t()) :: boolean()
  defp inside_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  @spec canonical_path(String.t(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  defp canonical_path(path, hops \\ 0)

  defp canonical_path(path, hops) when hops <= 40 do
    case Path.split(Path.expand(path)) do
      [root | components] -> resolve_path_components(root, components, hops)
      [] -> {:ok, Path.expand(path)}
    end
  end

  defp canonical_path(path, _hops), do: {:error, {:too_many_prompt_symlinks, path}}

  @spec resolve_path_components(String.t(), [String.t()], non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_path_components(current, [], _hops), do: {:ok, Path.expand(current)}

  defp resolve_path_components(current, [component | rest], hops) do
    candidate = Path.join(current, component)

    case File.read_link(candidate) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(candidate))

        target = Enum.reduce(rest, target, &Path.join(&2, &1))
        canonical_path(target, hops + 1)

      {:error, :einval} ->
        resolve_path_components(candidate, rest, hops)

      {:error, :enoent} ->
        {:ok, Enum.reduce(rest, candidate, &Path.join(&2, &1)) |> Path.expand()}

      {:error, reason} ->
        {:error, {:prompt_path_resolution_failed, candidate, reason}}
    end
  end

  @spec prompt_operations(
          module(),
          Spectre.Context.t() | map(),
          keyword(),
          Definition.scope()
        ) :: {:ok, [Operation.t()], [term()]} | {:error, term()}
  defp prompt_operations(agent, ctx, opts, scope) do
    definition_operations = Definition.injections(agent, scope)
    route = Map.get(ctx, :route)
    flow_operations = if match?(%Spectre.Route{}, route), do: route.injections, else: []

    handler_scope =
      if match?(%Spectre.Route{}, route),
        do: {:handler, scope, route.label},
        else: {:handler, scope, :direct}

    try do
      runtime_operations = Operation.normalize(Keyword.get(opts, :runtime_inject), :runtime)

      handler_operations =
        Operation.normalize(
          Keyword.get(opts, :handler_inject, Keyword.get(opts, :inject)),
          handler_scope
        )

      operations =
        runtime_operations ++ definition_operations ++ flow_operations ++ handler_operations

      {:ok, operations,
       scope_path(scope, runtime_operations, flow_operations, handler_operations)}
    rescue
      exception in ArgumentError ->
        {:error, {:invalid_prompt_operation, Exception.message(exception)}}
    end
  end

  @spec scope_path(Definition.scope(), [Operation.t()], [Operation.t()], [Operation.t()]) ::
          [term()]
  defp scope_path(scope, runtime_operations, flow_operations, handler_operations) do
    []
    |> append_operation_scopes(runtime_operations)
    |> Kernel.++([:agent])
    |> maybe_append_scope(scope)
    |> append_operation_scopes(flow_operations)
    |> append_operation_scopes(handler_operations)
    |> Enum.uniq()
  end

  @spec maybe_append_scope([term()], Definition.scope()) :: [term()]
  defp maybe_append_scope(scopes, :agent), do: scopes
  defp maybe_append_scope(scopes, scope), do: scopes ++ [scope]

  @spec append_operation_scopes([term()], [Operation.t()]) :: [term()]
  defp append_operation_scopes(scopes, operations) do
    scopes ++ Enum.map(operations, & &1.scope)
  end

  @spec resolve_operations(module(), [Operation.t()], Spectre.Context.t() | map(), keyword()) ::
          {:ok, [Plan.resolution()]} | {:error, term()}
  defp resolve_operations(agent, operations, ctx, opts) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, resolutions} ->
      case resolve_operation(agent, operation, ctx, opts) do
        {:ok, resolution} -> {:cont, {:ok, resolutions ++ [resolution]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec resolve_operation(module(), Operation.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, Plan.resolution()} | {:error, term()}
  defp resolve_operation(agent, %Operation{} = operation, ctx, opts) do
    started_at = System.monotonic_time()

    with false <- protected_policy_task?(operation, opts),
         {:ok, active?} <- evaluate_condition(operation, ctx, opts),
         {:active, true} <- {:active, active?},
         {:ok, content} <- resolve_source(agent, operation, ctx, opts),
         :ok <- validate_fragment_size(content, operation, opts) do
      {:ok,
       %{
         operation: operation,
         status: :applied,
         content: content,
         metadata: %{bytes: byte_size(content), duration_us: elapsed_us(started_at)}
       }}
    else
      true ->
        {:ok,
         %{
           operation: operation,
           status: :skipped,
           reason: :protected_policy_prompt,
           metadata: %{duration_us: elapsed_us(started_at)}
         }}

      {:active, false} ->
        {:ok,
         %{
           operation: operation,
           status: :skipped,
           reason: :condition_false,
           metadata: %{duration_us: elapsed_us(started_at)}
         }}

      {:error, reason} ->
        operation_failure(operation, reason, started_at)
    end
  end

  @spec operation_failure(Operation.t(), term(), integer()) ::
          {:ok, Plan.resolution()} | {:error, term()}
  defp operation_failure(%Operation{required?: true} = operation, reason, _started_at),
    do: {:error, {:prompt_operation_failed, operation.id, reason}}

  defp operation_failure(%Operation{} = operation, reason, started_at) do
    {:ok,
     %{
       operation: operation,
       status: :skipped,
       reason: reason,
       metadata: %{duration_us: elapsed_us(started_at)}
     }}
  end

  @spec protected_policy_task?(Operation.t(), keyword()) :: boolean()
  defp protected_policy_task?(%Operation{target: :task}, opts),
    do: Keyword.get(opts, :policy_prompt?, false) == true

  defp protected_policy_task?(%Operation{}, _opts), do: false

  @spec validate_operation_ids([Operation.t()]) :: :ok | {:error, term()}
  defp validate_operation_ids(operations) do
    duplicate =
      operations
      |> Enum.group_by(&{&1.scope, &1.id})
      |> Enum.find(fn {_key, scoped} -> length(scoped) > 1 end)

    case duplicate do
      nil -> :ok
      {{scope, id}, _operations} -> {:error, {:duplicate_prompt_operation, scope, id}}
    end
  end

  @spec evaluate_condition(Operation.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  defp evaluate_condition(%Operation{condition: nil}, _ctx, _opts), do: {:ok, true}

  defp evaluate_condition(%Operation{condition: condition} = operation, ctx, opts) do
    Call.run(
      :prompt,
      fn -> condition |> invoke(ctx, operation) |> normalize_condition_reply() end,
      Keyword.put(opts, :purpose, :prompt_condition)
    )
  end

  @spec resolve_source(module(), Operation.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  defp resolve_source(agent, %Operation{source: {:prompt, prompt}} = operation, ctx, opts) do
    scope = definition_scope(operation.scope)

    asset_opts =
      opts
      |> Keyword.delete(:inject)
      |> Keyword.put(:prompt_scope, scope)
      |> Keyword.put(:policy_prompt?, false)
      |> Keyword.delete(:policy)

    do_render_asset(agent, prompt, ctx, asset_opts)
  end

  defp resolve_source(
         _agent,
         %Operation{source: {:provider, module, function}} = operation,
         ctx,
         opts
       ) do
    Call.run(
      :prompt,
      fn -> {module, function} |> invoke(ctx, operation) |> normalize_content_reply() end,
      Keyword.put(opts, :purpose, :prompt_context)
    )
  end

  @spec invoke({module(), atom()} | function(), Spectre.Context.t() | map(), Operation.t()) ::
          term()
  defp invoke({module, function}, ctx, operation) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, function, 2) -> apply(module, function, [ctx, operation.opts])
      function_exported?(module, function, 1) -> apply(module, function, [ctx])
      function_exported?(module, function, 0) -> apply(module, function, [])
      true -> {:error, {:undefined_prompt_provider, module, function}}
    end
  end

  defp invoke(function, ctx, operation) when is_function(function, 2),
    do: function.(ctx, operation.opts)

  defp invoke(function, ctx, _operation) when is_function(function, 1), do: function.(ctx)
  defp invoke(function, _ctx, _operation) when is_function(function, 0), do: function.()

  @spec normalize_condition_reply(term()) :: {:ok, boolean()} | {:error, term()}
  defp normalize_condition_reply({:ok, value}) when is_boolean(value), do: {:ok, value}
  defp normalize_condition_reply(value) when is_boolean(value), do: {:ok, value}
  defp normalize_condition_reply({:error, reason}), do: {:error, reason}

  defp normalize_condition_reply(other),
    do: {:error, {:invalid_prompt_condition_reply, reply_shape(other)}}

  @spec normalize_content_reply(term()) :: {:ok, String.t()} | {:error, term()}
  defp normalize_content_reply({:ok, content}) when is_binary(content), do: {:ok, content}
  defp normalize_content_reply(content) when is_binary(content), do: {:ok, content}
  defp normalize_content_reply({:error, reason}), do: {:error, reason}

  defp normalize_content_reply(other),
    do: {:error, {:invalid_prompt_provider_reply, reply_shape(other)}}

  @spec validate_fragment_size(String.t(), Operation.t(), keyword()) :: :ok | {:error, term()}
  defp validate_fragment_size(content, operation, opts) do
    max_bytes =
      Keyword.get(
        operation.opts,
        :max_bytes,
        Keyword.get(opts, :inject_max_bytes, @default_max_fragment_bytes)
      )

    if is_integer(max_bytes) and max_bytes > 0 and byte_size(content) <= max_bytes do
      :ok
    else
      {:error, {:prompt_fragment_too_large, byte_size(content), max_bytes}}
    end
  end

  @spec validate_plan_size(Plan.t(), keyword()) :: :ok | {:error, term()}
  defp validate_plan_size(%Plan{} = plan, opts) do
    max_bytes = Keyword.get(opts, :prompt_max_bytes, @default_max_prompt_bytes)
    bytes = byte_size(plan.rendered)

    if is_integer(max_bytes) and max_bytes > 0 and bytes <= max_bytes do
      :ok
    else
      {:error, {:prompt_too_large, bytes, max_bytes}}
    end
  end

  @spec definition_scope(term()) :: Definition.scope()
  defp definition_scope(:agent), do: :agent
  defp definition_scope({:skill, _mount_id} = scope), do: scope
  defp definition_scope({:flow, scope, _flow}), do: scope
  defp definition_scope({:handler, scope, _label}), do: scope
  defp definition_scope(_scope), do: :agent

  @spec prompt_scope(Spectre.Context.t() | map(), keyword()) :: Definition.scope()
  defp prompt_scope(ctx, opts) do
    Keyword.get(opts, :prompt_scope) ||
      case Map.get(ctx, :route) do
        %Spectre.Route{scope: scope} -> scope
        _route -> Definition.policy_scope(Keyword.get(opts, :policy) || active_policy(ctx))
      end
  end

  @spec active_policy(Spectre.Context.t() | map()) :: term()
  defp active_policy(%{state: %Spectre.State{} = state}) do
    case Spectre.State.open_policy_awaitable(state) do
      %Spectre.Awaitable{name: policy} -> policy
      nil -> nil
    end
  end

  defp active_policy(_ctx), do: nil

  @spec assigns(Spectre.Context.t() | map(), keyword()) :: map()
  defp assigns(%{input: input, state: state} = ctx, opts) do
    base =
      ctx
      |> Map.get(:assigns, %{})
      |> Map.merge(%{
        input: input,
        state: state,
        ctx: ctx,
        recent_chat: Keyword.get(opts, :recent_chat, Map.get(ctx, :recent_chat, "none")),
        memory: Map.get(ctx, :memory)
      })

    Map.merge(base, Keyword.get(opts, :assigns, %{}))
  end

  @spec eval_heexish(String.t(), map(), String.t()) :: String.t()
  defp eval_heexish(text, assigns, file) do
    text
    |> rewrite_assigns()
    |> EEx.eval_string([assigns: assigns], file: file)
  end

  @spec rewrite_assigns(String.t()) :: String.t()
  defp rewrite_assigns(text) do
    Regex.replace(~r/<%(=)?(.*?)%>/s, text, fn _full, equals, code ->
      marker = if equals == "=", do: "<%=", else: "<%"
      "#{marker}#{rewrite_assigns_in_code(code)}%>"
    end)
  end

  @spec rewrite_assigns_in_code(String.t()) :: String.t()
  defp rewrite_assigns_in_code(code) do
    Regex.replace(~r/@([a-zA-Z_][a-zA-Z0-9_]*)/, code, fn _full, key ->
      "Map.get(var!(assigns), :#{key})"
    end)
  end

  @spec elapsed_us(integer()) :: non_neg_integer()
  defp elapsed_us(started_at) do
    started_at
    |> then(&(System.monotonic_time() - &1))
    |> System.convert_time_unit(:native, :microsecond)
  end

  @spec reply_shape(term()) :: atom() | {:tuple, non_neg_integer()} | {:struct, module()}
  defp reply_shape(value) when is_binary(value), do: :binary
  defp reply_shape(value) when is_atom(value), do: :atom
  defp reply_shape(value) when is_list(value), do: :list
  defp reply_shape(%{__struct__: module}), do: {:struct, module}
  defp reply_shape(value) when is_map(value), do: :map
  defp reply_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp reply_shape(_value), do: :other
end
