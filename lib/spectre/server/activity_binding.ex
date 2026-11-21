defmodule Spectre.Server.ActivityBinding do
  @moduledoc false

  alias Spectre.Integration
  alias Spectre.Server.{Activities, Command, GAM.Managed, Runtime}
  alias Spectre.Stack.Definition

  @spec owner(map(), :existing | :start) :: {:ok, {pid(), reference()} | nil} | {:error, term()}
  def owner(%{activity: %{owner: owner, token: token}}, _mode), do: {:ok, {owner, token}}

  def owner(%{activity_connection: {pid, _token} = connection}, _mode),
    do: {:ok, if(Process.alive?(pid), do: connection)}

  def owner(%{activity_connection: nil}, _mode), do: {:ok, nil}
  def owner(%{managed_owner: pid}, mode) when is_pid(pid), do: Managed.activity_owner(pid, mode)
  def owner(_state, _mode), do: {:ok, nil}

  @spec start(map(), term(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(state, type, args, opts) do
    with :ok <- permit_start(state, type),
         {:ok, binding} <- binding(state.agent, type),
         {:ok, scope} <- effective_scope(state, binding, opts),
         {:ok, {pid, token}} <- owner(state, :start),
         {:ok, ref} <-
           Activities.start(pid, state.active_command, child(state, binding, token, args, scope),
             as: opts[:as],
             parent: if(state.activity, do: state.activity.ref)
           ) do
      {:ok, %{ref: ref, key: opts[:as]}}
    else
      {:ok, nil} -> {:error, :activity_owner_unavailable}
      error -> error
    end
  end

  @spec control(map(), term(), term(), keyword()) :: term()
  def control(state, target, action, opts) do
    case owner(state, :existing) do
      {:ok, {pid, _}} -> Activities.control(pid, target, state.active_command, action, opts)
      {:ok, nil} -> {:error, :unknown_activity}
      error -> error
    end
  end

  @spec connect(map(), :existing | :start) :: map()
  def connect(state, mode) do
    case owner(Map.delete(state, :activity_connection), mode) do
      {:ok, connection} -> Map.put(state, :activity_connection, connection)
      {:error, _} -> Map.put(state, :activity_connection, nil)
    end
  end

  @spec resolve(map(), Command.t()) :: Command.t()
  def resolve(state, %Command{kind: kind, args: [target | rest]} = command)
      when kind in [:signal_activity, :cancel_activity] do
    {target, opts} =
      with {:ok, {pid, _}} <- owner(state, :existing),
           {:ok, %{ref: ref} = entry} <- Activities.view(pid, target),
           true <- can_control?(state.activity, entry) do
        {ref, Keyword.put_new(command.opts, :if_revision, entry.revision)}
      else
        _ -> {"unknown-activity", command.opts}
      end

    %{command | args: [target | rest], opts: opts}
  end

  def resolve(_state, command), do: command

  defp can_control?(nil, _entry), do: true
  defp can_control?(%{ref: ref}, %{parent: ref}), do: true
  defp can_control?(_activity, _entry), do: false

  @spec authorize(map(), {Command.t(), term()}) :: {Command.t(), term()}
  def authorize(%{activity: %{scope: scope}}, {%Command{kind: :propose, opts: opts}, nil})
      when scope != :all do
    command = %Command{
      kind: :tool_rejected,
      args: [{:error, :activity_tool_not_allowed}],
      opts: [on_result: Keyword.get(opts, :on_result, :propose)]
    }

    {command, nil}
  end

  def authorize(_state, pair), do: pair

  @spec public(map()) :: map() | nil
  def public(%{activity: %{} = activity}), do: Map.take(activity, [:ref, :key, :revision])
  def public(_state), do: nil

  @spec report(map(), term()) :: :ok
  def report(%{activity: %{owner: owner, ref: ref}}, event),
    do: Activities.report(owner, ref, event)

  def report(_state, _event), do: :ok

  @spec presentation(map(), binary()) ::
          {:ok, pid(), reference(), non_neg_integer()} | {:error, term()} | :error | {:ok, nil}
  def presentation(state, ref) do
    with {:ok, {pid, _}} <- owner(state, :existing), do: Activities.presentation(pid, ref)
  end

  @spec allowed_tool?(map(), term()) :: boolean()
  def allowed_tool?(%{activity: %{scope: scope}}, ref), do: scope == :all or ref in scope
  def allowed_tool?(_state, _ref), do: true

  @spec portable_control_opts?(keyword()) :: boolean()
  def portable_control_opts?(opts),
    do:
      Keyword.keyword?(opts) and Keyword.keys(opts) -- [:if_revision] == [] and
        Enum.all?(opts, fn {:if_revision, revision} -> is_integer(revision) and revision >= 0 end)

  defp permit_start(state, type) do
    with :ok <- permit_host(state.opts[:activities], type), do: permit_child(state.activity, type)
  end

  defp permit_child(nil, _type), do: :ok
  defp permit_child(%{children: true}, _type), do: :ok

  defp permit_child(%{children: types}, type) when is_list(types) do
    if type in types, do: :ok, else: {:error, :activity_children_not_allowed}
  end

  defp permit_child(_activity, _type), do: {:error, :activity_children_not_allowed}

  defp permit_host(nil, _type), do: :ok

  defp permit_host(allowed, type) when is_list(allowed) do
    if type in allowed, do: :ok, else: {:error, :activity_not_allowed}
  end

  defp permit_host(_allowed, _type), do: {:error, :activity_not_allowed}

  defp binding(agent, type) do
    with {:ok, %{stack: stack}} when not is_nil(stack) <- Spectre.Definition.fetch(agent),
         {:ok, %{module: mod} = binding} <- Definition.activity(stack, type),
         true <- Code.ensure_loaded?(mod) and function_exported?(mod, :__spectre_activity__, 0) do
      {:ok, binding}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_activity_binding}
    end
  end

  defp effective_scope(state, binding, request) do
    parent =
      if state.activity,
        do: state.activity.scope,
        else: Keyword.get(state.opts, :activity_tools, :all)

    scopes = [
      parent,
      Keyword.get(binding.options, :tools, :all),
      Keyword.get(request, :scope, :all)
    ]

    if Enum.all?(scopes, &Integration.tool_scope?/1) do
      scope = Enum.reduce(scopes, :all, &intersect/2)
      validate_requirements(scope, Keyword.get(binding.options, :requires, []))
    else
      {:error, :invalid_activity_tool_scope}
    end
  end

  defp validate_requirements(:all, _required), do: {:ok, :all}

  defp validate_requirements(scope, required) do
    case required -- scope do
      [] -> {:ok, scope}
      missing -> {:error, {:activity_required_tools_outside_scope, missing}}
    end
  end

  defp child(state, binding, token, args, scope) do
    children =
      if state.activity, do: false, else: Keyword.get(binding.options, :allow_children, false)

    owner = if state.activity, do: state.activity.managed, else: state.managed_owner

    activity = %{
      args: args,
      token: token,
      scope: scope,
      children: children,
      managed: owner,
      ready: false,
      paused: false,
      deferred: []
    }

    opts =
      state.opts
      |> Keyword.take([
        :activities,
        :services,
        :stack_runtime,
        :checkpoint,
        :payload_store,
        :max_steps,
        :worker_timeout
      ])
      |> Keyword.merge(
        agent: state.agent,
        server: binding.module,
        identity: state.identity,
        consumer: state.consumer,
        session_generation: state.submission_epoch,
        activity: activity,
        gam: {Managed, [server: owner, control: token]}
      )

    {Runtime, opts}
  end

  defp intersect(:all, scope), do: scope
  defp intersect(scope, :all), do: scope

  defp intersect(left, right) when is_list(left) and is_list(right),
    do: Enum.filter(left, &(&1 in right))

  defp intersect(_left, _right), do: []
end
