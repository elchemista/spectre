defmodule Spectre.Server.Skills do
  @moduledoc """
  Supervised mounted Skill runtimes sharing their Agent's automatic GAM integration.

  A Skill with a `server:` binding gets an independent `Spectre.Server.Runtime`.
  Declarative mounts without a binding continue dispatching to the Agent server.
  Child coordination checkpoints are namespaced under the Agent checkpoint;
  the GAM ledger and its authority remain shared, never copied.
  The root passes its existing GAM connection to every child. Mount restrictions
  can narrow operation access but create no Domain or new grant. Proposal
  provenance and lifecycle changes enter the shared ledger; pending intentions
  and their exact consent correlation remain local to each runtime.
  """
  use Supervisor

  alias Spectre.Server.{Checkpoint, Command, Runtime}

  @doc false
  @spec start_link(map()) :: Supervisor.on_start()
  def start_link(state), do: Supervisor.start_link(__MODULE__, state)

  @impl true
  def init(state) do
    children =
      Enum.map(mounts(state.agent), fn mount ->
        %{id: mount.id, start: {Runtime, :start_link, [options(state, mount)]}}
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  @spec mounts(module()) :: [Spectre.Skill.Mount.t()]
  def mounts(agent) do
    if function_exported?(agent, :__spectre_skills__, 0) do
      Enum.filter(agent.__spectre_skills__(), & &1.module.__spectre_server__())
    else
      []
    end
  end

  @doc false
  @spec lookup(pid() | nil, term()) :: {:ok, pid()} | {:error, atom()}
  def lookup(nil, _id), do: {:error, :skill_not_running}

  def lookup(supervisor, id) do
    case Enum.find(Supervisor.which_children(supervisor), &(elem(&1, 0) == id)) do
      {^id, pid, _, _} when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :unknown_skill}
      _ -> {:error, :skill_restarting}
    end
  catch
    :exit, _ -> {:error, :skill_supervisor_unavailable}
  end

  @doc false
  @spec stop(pid() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, _ -> :ok
  end

  @doc false
  @spec preview?(term()) :: boolean()
  def preview?({:preview, _, _, _}), do: true
  def preview?({:preview_end, _, _, _}), do: true
  def preview?(_event), do: false

  @doc false
  @spec input(pid() | nil, term(), term(), keyword()) :: {:ok, binary()} | {:error, term()}
  def input(supervisor, id, input, opts \\ []) do
    with {:ok, pid} <- lookup(supervisor, id) do
      Spectre.Server.input(pid, input, opts)
    end
  catch
    :exit, reason -> {:error, {:skill_unavailable, reason}}
  end

  @doc false
  @spec dispatch(pid() | nil, term(), binary(), term(), map() | nil) ::
          {:delegated, map()} | {:error, term()} | {:skill_unknown, map()}
  def dispatch(supervisor, mount, invocation, input, dispatch) do
    with :ok <- validate_input(input),
         {:ok, pid} <- lookup(supervisor, mount),
         {:ok, interaction} <-
           GenServer.call(pid, {Runtime, :skill_input, invocation, input, dispatch}, :infinity) do
      {:delegated, %{skill: mount, interaction: interaction}}
    end
  catch
    :exit, reason -> {:skill_unknown, %{skill: mount, interaction: invocation, reason: reason}}
  end

  @doc false
  @spec authorize({Command.t(), term()}, map()) :: {Command.t(), term()}
  def authorize({%Command{kind: :propose, args: [operation, _]} = command, origin}, state) do
    case Keyword.get(state.opts, :skill) do
      nil ->
        {command, origin}

      %{governed: allowed, bindings: bindings} ->
        operation = Map.get(bindings, operation, operation)

        if operation in allowed do
          [_, args] = command.args
          {%{command | args: [operation, args]}, origin}
        else
          {%Command{
             kind: :tool_rejected,
             args: [{:error, {:skill_operation_not_allowed, operation}}],
             opts: Keyword.put_new(command.opts, :on_result, :propose)
           }, origin}
        end
    end
  end

  def authorize(command, _state), do: command

  @doc false
  @spec routing(map(), map() | nil) :: map()
  def routing(state, event) do
    routing = if event, do: event.routing, else: %{}

    case Keyword.get(state.opts, :skill) do
      nil ->
        routing

      %{id: id, module: module} ->
        scope = {:skill, id}
        route = Map.get(routing, :route) || %Spectre.Route{owner: module, scope: scope}
        Map.merge(routing, %{route: route, scope: scope})
    end
  end

  @doc false
  @spec local_key(term(), keyword()) :: term()
  def local_key({{scope, flow}, label}, opts) do
    if Keyword.get(opts, :runtime_scope) == scope, do: {flow, label}, else: {{scope, flow}, label}
  end

  def local_key(key, _opts), do: key

  @spec options(map(), Spectre.Skill.Mount.t()) :: keyword()
  defp options(state, mount) do
    allowed = Keyword.get(mount.opts, :governed, Map.values(mount.bindings))

    unless is_list(allowed),
      do: raise(ArgumentError, "Skill governed: must list host operation references")

    skill = %{id: mount.id, module: mount.module, governed: allowed, bindings: mount.bindings}
    checkpoint = checkpoint(Keyword.get(state.opts, :checkpoint), mount.id)
    options = state.opts |> Keyword.get(:skill_options, %{}) |> Map.new() |> Map.get(mount.id, [])
    options = Keyword.merge(mount.opts, Keyword.take(options, [:init_arg, :assigns]))

    state.opts
    |> Keyword.drop([:name, :subject, :id, :private, :init_arg, :prompt_root])
    |> Keyword.put(:agent, state.agent)
    |> Keyword.put(:server, mount.module.__spectre_server__())
    |> Keyword.put(:consumer, state.runtime_pid)
    |> Keyword.put(:skill_parent, {state.runtime_pid, state.control})
    |> Keyword.put(:skill, skill)
    |> Keyword.put(:runtime_scope, {:skill, mount.id})
    |> Keyword.put(:identity, state.identity)
    |> Keyword.put(
      :assigns,
      Map.merge(state.assigns, Map.new(Keyword.get(options, :assigns, [])))
    )
    |> Keyword.put(:init_arg, Keyword.get(options, :init_arg))
    |> Keyword.put(:checkpoint, checkpoint)
    |> Keyword.put(
      :checkpoint_domain,
      if(state.managed_owner,
        do: {state.managed_owner, Spectre.Server.GAM.Managed.info(state.managed_owner).domain},
        else: nil
      )
    )
    |> Keyword.put(:gam, state.gam)
  end

  @doc false
  def refresh_checkpoint(opts) do
    case opts[:checkpoint_domain] do
      {owner, original} ->
        if Spectre.Server.GAM.Managed.info(owner).domain == original do
          opts
        else
          current = Spectre.Server.GAM.Managed.runtime_checkpoint(owner)
          Keyword.put(opts, :checkpoint, checkpoint(current, opts[:skill].id))
        end

      nil ->
        opts
    end
  end

  @spec checkpoint(term(), term()) :: term()
  @doc false
  def checkpoint(nil, _id), do: nil
  def checkpoint({store, key}, id), do: {store, {:spectre_skill, key, id}}
  def checkpoint({module, store, key}, id), do: {module, store, {:spectre_skill, key, id}}

  @doc false
  @spec validate_input(term()) :: :ok | {:error, term()}
  def validate_input(input) do
    input = Spectre.Input.new(input)
    with :ok <- Spectre.Input.validate(input), do: Checkpoint.validate_value(input)
  end
end
