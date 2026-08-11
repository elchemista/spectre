defmodule Spectre.Runtime.SkillDispatch do
  @moduledoc """
  Dispatches runtime-authored Skills from the Definition pinned to a Run.

  The dispatcher loads only runtime-origin mounts, checks their closure and
  embedded Definition references, and refuses ambiguous overlap with compiled
  exact routes. A missing governed Surface falls through to the ordinary
  compiled router; invalid governed data fails closed.
  """

  alias Spectre.Context
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Store
  alias Spectre.Flow.Constraint
  alias Spectre.Input
  alias Spectre.Morph.Surface
  alias Spectre.Prompt.Receipt
  alias Spectre.Result
  alias Spectre.Router
  alias Spectre.Router.Support
  alias Spectre.Rule
  alias Spectre.Skill.Runtime
  alias Spectre.Skill.Runtime.Loader
  alias Spectre.Skill.Runtime.Response
  alias Spectre.State

  @type result :: :cont | {:reply, Result.t()} | {:error, term()}

  @doc false
  @spec dispatch(Context.t()) :: result()
  def dispatch(%Context{} = context) do
    store = Keyword.get(context.opts, :instance_definition_store)
    definition_ref = Keyword.get(context.opts, :definition_ref)
    enabled? = Keyword.get(context.opts, :runtime_skill_dispatch?, false)

    if not enabled? or is_nil(store) or is_nil(definition_ref) do
      :cont
    else
      dispatch_pinned(context, store, definition_ref)
    end
  end

  @doc false
  @spec compiled_deterministic_route(module(), State.t(), Input.t()) ::
          {:ok, atom()} | :not_found
  @spec compiled_deterministic_route(
          module(),
          State.t(),
          Input.t(),
          keyword()
        ) ::
          {:ok, atom()} | :not_found
  def compiled_deterministic_route(agent, state, input, opts \\ []) do
    router_opts = Keyword.merge(agent.__spectre_router__(), opts)

    conflict =
      agent
      |> Router.candidate_rules(state)
      |> maybe_interrupt_rules(router_opts)
      |> Constraint.filter_and_order(input)
      |> Support.rules_for(:regex, input)
      |> Enum.find(&Rule.match?(&1, input.text))

    if conflict, do: {:ok, conflict.label}, else: :not_found
  end

  @spec dispatch_pinned(Context.t(), Store.config(), term()) :: result()
  defp dispatch_pinned(context, store, definition_ref) do
    case Loader.load(store, definition_ref, context.agent,
           closure_digest: Keyword.get(context.opts, :closure_digest),
           runtime_only?: true
         ) do
      {:ok, %{runtime: %{mounts: mounts}}} when map_size(mounts) == 0 ->
        :cont

      {:ok, loaded} ->
        with {:ok, skill_context} <- skill_context(context.opts, loaded.surface),
             {:ok, response, _runtime} <-
               Runtime.respond(loaded.runtime, context.input, skill_context,
                 expected_revision: loaded.runtime.revision
               ),
             :ok <- no_compiled_exact_conflict(context) do
          response_result(context, definition_ref, response)
        else
          {:error, :runtime_skill_route_not_found} -> :cont
          {:error, _reason} = error -> error
        end

      # Without a governed Surface, runtime data dispatch has no authority.
      # Continue into the compiled Agent path instead of inventing a fallback.
      {:error, :morph_surface_not_declared} ->
        :cont

      {:error, _reason} = error ->
        error
    end
  end

  @spec response_result(Context.t(), Ref.t() | String.t(), Response.t()) :: result()
  defp response_result(context, definition_ref, %{kind: :reply, output: output} = response)
       when is_binary(output) do
    {:reply,
     %Result{
       input: context.input,
       state: context.state,
       reply_text: output,
       events: [
         %{
           type: :runtime_skill_replied,
           mount_id: response.mount_id,
           route_label: response.route_label
         }
       ],
       metadata: %{
         runtime_skill: %{
           agent_definition_ref: to_string(definition_ref),
           skill_definition_ref: to_string(response.definition_ref),
           mount_id: response.mount_id,
           route_label: response.route_label,
           prompt_receipt: Receipt.to_data(response.prompt_receipt)
         }
       }
     }}
  end

  defp response_result(_context, _definition_ref, %{kind: kind}),
    do: {:error, {:runtime_skill_turn_boundary_unsupported, kind}}

  @spec skill_context(keyword(), Surface.t()) :: {:ok, map()} | {:error, term()}
  defp skill_context(opts, surface) do
    case Keyword.fetch(opts, :skill_context) do
      {:ok, context} when is_map(context) and not is_struct(context) ->
        {:ok, context}

      {:ok, value} ->
        {:error, {:invalid_runtime_skill_context, value}}

      :error ->
        case surface.scope_ceiling do
          [scope] -> {:ok, %{"scope" => scope}}
          scopes -> {:error, {:runtime_skill_context_required, scopes}}
        end
    end
  end

  # Until runtime and compiled candidates share one arbitrator, never let a
  # declarative runtime reply silently override an exact compiled route.
  @spec no_compiled_exact_conflict(Context.t()) :: :ok | {:error, term()}
  defp no_compiled_exact_conflict(context) do
    case compiled_deterministic_route(context.agent, context.state, context.input, context.opts) do
      {:ok, label} -> {:error, {:ambiguous_definition_route, label}}
      :not_found -> :ok
    end
  end

  @spec maybe_interrupt_rules([Rule.t()], keyword()) :: [Rule.t()]
  defp maybe_interrupt_rules(rules, opts) do
    if Keyword.get(opts, :policy_interrupt_only?, false),
      do: Enum.filter(rules, & &1.global?),
      else: rules
  end
end
