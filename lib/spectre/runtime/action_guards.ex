defmodule Spectre.ActionGuards do
  @moduledoc """
  Runs `before_action` guards right before an action capability is invoked.

  Guards are the host-state veto point of the action lifecycle: routing has
  already selected the handler, planning has already staged the effect, and
  any protecting policy has already been satisfied. A guard can still stop
  execution because of state only the application can see — an open draft, a
  role restriction, a quota — and turn the pending effect into a plain reply
  instead of a capability call.

  A guard callback receives `(action, ctx)` and returns:

    * `:allow` (or `:ok`) — execution proceeds
    * `{:suppress, reply_text}` — the pending effect is cancelled without
      invoking the capability; the turn resolves as a reply with that text
    * `{:error, reason}` — execution fails closed

  Guards apply to `:action` effects only and run in declaration order; the
  first non-`:allow` outcome wins.
  """

  alias Spectre.Action
  alias Spectre.Effect
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure

  @type outcome :: :allow | {:suppress, String.t()} | {:error, term()}

  @doc """
  Runs every matching guard for the effect and returns the first veto.

      :allow = Spectre.ActionGuards.check(effect, ctx, [])
  """
  @spec check(Effect.t(), Spectre.Context.t() | map(), keyword()) :: outcome()
  def check(%Effect{kind: :action} = effect, ctx, opts) do
    case guards_for(ctx, effect) do
      [] ->
        :allow

      guards ->
        action = Action.from_effect(effect)
        run_guards(guards, action, ctx, opts)
    end
  end

  def check(%Effect{}, _ctx, _opts), do: :allow

  @spec guards_for(Spectre.Context.t() | map(), Effect.t()) :: [map()]
  defp guards_for(ctx, effect) do
    case agent(ctx) do
      nil ->
        []

      agent ->
        agent
        |> Spectre.Definition.before_actions()
        |> Enum.filter(&guard_matches?(&1, effect))
    end
  end

  @spec agent(Spectre.Context.t() | map()) :: module() | nil
  defp agent(%{agent: agent}) when is_atom(agent) and not is_nil(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_definition__, 0) do
      agent
    end
  end

  defp agent(_ctx), do: nil

  @spec guard_matches?(map(), Effect.t()) :: boolean()
  defp guard_matches?(%{action: :all}, _effect), do: true

  defp guard_matches?(%{action: action}, %Effect{} = effect),
    do: Action.matches_ref?(action, effect)

  @spec run_guards([map()], Action.t(), Spectre.Context.t() | map(), keyword()) :: outcome()
  defp run_guards(guards, action, ctx, opts) do
    Enum.reduce_while(guards, :allow, fn guard, :allow ->
      case run_guard(guard, action, ctx, opts) do
        :allow -> {:cont, :allow}
        outcome -> {:halt, outcome}
      end
    end)
  end

  @spec run_guard(map(), Action.t(), Spectre.Context.t() | map(), keyword()) :: outcome()
  defp run_guard(guard, action, ctx, opts) do
    call_opts =
      ctx
      |> ctx_opts(opts)
      |> Call.adapter_opts()
      |> Keyword.put(:purpose, :before_action)

    case Call.run(
           :hook,
           fn -> invoke_guard(guard, action, ctx) |> normalize_outcome() end,
           call_opts
         ) do
      {:ok, :allow} -> :allow
      {:ok, {:suppress, text}} -> {:suppress, text}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ctx_opts(Spectre.Context.t() | map(), keyword()) :: keyword()
  defp ctx_opts(%{opts: ctx_opts}, opts) when is_list(ctx_opts), do: Keyword.merge(ctx_opts, opts)
  defp ctx_opts(_ctx, opts), do: opts

  @spec invoke_guard(map(), Action.t(), Spectre.Context.t() | map()) :: term()
  defp invoke_guard(%{run: {module, function}}, action, ctx)
       when is_atom(module) and is_atom(function) do
    Code.ensure_loaded(module)

    cond do
      function_exported?(module, function, 2) -> apply(module, function, [action, ctx])
      function_exported?(module, function, 1) -> apply(module, function, [action])
      true -> {:error, {:invalid_before_action_guard, {module, function}}}
    end
  end

  defp invoke_guard(%{run: function}, action, ctx) when is_function(function, 2),
    do: function.(action, ctx)

  defp invoke_guard(%{run: function}, action, _ctx) when is_function(function, 1),
    do: function.(action)

  defp invoke_guard(%{run: run}, _action, _ctx),
    do: {:error, {:invalid_before_action_guard, run}}

  @spec normalize_outcome(term()) :: {:ok, :allow | {:suppress, String.t()}} | {:error, term()}
  defp normalize_outcome(:allow), do: {:ok, :allow}
  defp normalize_outcome(:ok), do: {:ok, :allow}
  defp normalize_outcome({:suppress, text}) when is_binary(text), do: {:ok, {:suppress, text}}
  defp normalize_outcome({:error, reason}), do: {:error, reason}
  defp normalize_outcome(other), do: {:error, Failure.invalid_reply(:hook, other)}
end
