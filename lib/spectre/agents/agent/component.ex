defmodule Spectre.Agent.Component do
  @moduledoc false

  alias Spectre.Agent.{Publication, Wiring}
  alias Spectre.{Governance, Instance, Portable}

  @doc "Validates wiring before opening a promised Scope; never closes it on startup failure."
  def start(instance, kind, name, opts) when kind in [:worker, :vigil] do
    with {:ok, attrs} <-
           Portable.normalize_attrs(
             opts,
             [:input, :opening, :definition, :adapters, :bindings, :state, :supervisor],
             :component_start
           ),
         {:ok, parent, module, code_ref} <- Instance.component(instance, kind, name),
         :ok <- pinned_component(module, code_ref),
         {:ok, supervisor} <- Map.fetch(attrs, :supervisor),
         :ok <- available_supervisor(supervisor),
         {:ok, input} <- Map.fetch(attrs, :input),
         {:ok, definition} <- Map.fetch(attrs, :definition),
         {:ok, _plan, _children} <- Publication.verify(module, definition),
         {:ok, _wiring} <- Wiring.resolve(module, Map.get(attrs, :adapters, [])),
         {:ok, opening} <-
           Portable.normalize_attrs(
             Map.get(attrs, :opening),
             [:context, :attributes, :candidate, :options],
             :component_opening
           ),
         # Use the same pure builder as open_scope: it binds the parent and
         # authenticated child context before validating a promised opening.
         {:ok, candidate} <-
           Governance.open_scope(
             parent,
             opening[:context],
             opening[:attributes],
             opening[:candidate]
           ),
         true <- candidate.consequence["scope_open"]["kind"] === scope_kind(kind),
         {:ok, scope} <-
           Spectre.open_scope(
             parent,
             opening[:context],
             opening[:attributes],
             opening[:candidate],
             Map.get(opening, :options, [])
           ) do
      config = [
        scope: scope,
        definition: definition,
        adapters: Map.get(attrs, :adapters, []),
        bindings: Map.get(attrs, :bindings, %{}),
        state: Map.get(attrs, :state, %{})
      ]

      start_opened(supervisor, module, config, scope, input)
    else
      :error -> {:error, :missing_component_start_options}
      false -> {:error, :component_scope_kind_mismatch}
      {:error, _} = error -> error
    end
  end

  def start(_instance, _kind, _name, _opts), do: {:error, :invalid_component_kind}

  defp pinned_component(module, expected) do
    if Publication.code_ref(module) === expected,
      do: :ok,
      else: {:error, :component_code_changed}
  end

  defp available_supervisor(server) do
    case GenServer.whereis(server) do
      pid when is_pid(pid) -> :ok
      _missing -> {:error, :component_supervisor_unavailable}
    end
  rescue
    ArgumentError -> {:error, :invalid_component_supervisor}
  end

  defp start_opened(supervisor, module, config, scope, input) do
    case DynamicSupervisor.start_child(supervisor, {module, config}) do
      {:ok, pid} ->
        case Instance.turn(pid, input) do
          {:ok, _turn} ->
            {:ok, pid}

          {:error, reason} ->
            {:error, {:component_initial_turn_failed, pid, Spectre.Scope.ref(scope), reason}}
        end

      {:error, reason} ->
        {:error, {:component_start_failed_after_opening, Spectre.Scope.ref(scope), reason}}

      :ignore ->
        {:error, {:component_start_ignored_after_opening, Spectre.Scope.ref(scope)}}
    end
  catch
    :exit, _reason ->
      {:error, {:component_supervisor_unavailable_after_opening, Spectre.Scope.ref(scope)}}
  end

  defp scope_kind(:worker), do: :work
  defp scope_kind(:vigil), do: :vigil
end
