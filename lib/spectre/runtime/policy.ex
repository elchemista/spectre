defmodule Spectre.Policy do
  @moduledoc """
  Policy gate evaluator for pending effects.

  A policy is a temporary deterministic router for one pending effect. While a
  policy is active, Spectre ignores normal flow routing and interprets the next
  user turn as approval, rejection, or retry.
  """

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Lifecycle
  alias Spectre.Result
  alias Spectre.State

  defstruct [
    :name,
    :reference,
    :scope,
    :owner,
    :request,
    accepts: [],
    rejects: [],
    otherwise: nil,
    max_attempts: nil,
    then: nil
  ]

  @type decision :: {:accept, atom()} | {:reject, atom()} | :no_match
  @type resolution :: {:accept, atom()} | {:reject, atom()}

  @type t :: %__MODULE__{
          name: atom(),
          reference: term(),
          scope: Spectre.Definition.scope(),
          owner: module() | nil,
          request: atom() | String.t() | nil,
          accepts: [map()],
          rejects: [map()],
          otherwise: {:ask, atom() | String.t()} | nil,
          max_attempts: pos_integer() | nil,
          then: atom() | nil
        }

  @doc """
  Builds a policy struct from compiled DSL metadata.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct(__MODULE__, Map.take(attrs, fields()))

  @doc """
  Returns true when the state is waiting on a policy response.
  """
  @spec awaiting?(State.t()) :: boolean()
  def awaiting?(%State{} = state), do: State.awaiting_policy?(state)

  @doc """
  Resumes the active policy with the user's latest input.
  """
  @spec resume(Input.t(), Spectre.Context.t()) :: {:ok, Result.t()} | {:error, term()}
  def resume(%Input{} = input, %{state: %State{} = state} = ctx) do
    case State.open_policy_awaitable(state) do
      %Awaitable{name: policy_name} ->
        case find_policy(ctx.agent, policy_name) do
          %__MODULE__{} = policy -> resume_policy(policy, input, ctx)
          nil -> {:error, {:unknown_policy, policy_name}}
        end

      nil ->
        {:error, :no_open_policy}
    end
  end

  @doc """
  Resolves the active policy from a trusted host decision without matching
  synthetic user text.

  The label must exist in the policy's corresponding accept/reject branches.
  This is useful when an application already has durable proof that a policy is
  satisfied. Callers should use `Spectre.resolve_policy/4` so the resulting
  state is persisted before execution.
  """
  @spec resolve(resolution(), Input.t(), Spectre.Context.t() | map()) ::
          {:ok, Result.t()} | {:error, term()}
  def resolve({kind, label} = resolution, %Input{} = input, %{state: %State{}} = ctx)
      when kind in [:accept, :reject] and is_atom(label) do
    with {:ok, policy} <- active_policy(ctx),
         :ok <- validate_resolution(policy, resolution),
         {:ok, %Result{} = result} <- apply_resolution(policy, resolution, input, ctx) do
      event = %{
        type: :policy_resolved,
        source: :host,
        kind: kind,
        name: policy_identifier(policy),
        label: label
      }

      {:ok, %{result | events: result.events ++ [event]}}
    end
  end

  def resolve(resolution, _input, _ctx), do: {:error, {:invalid_policy_resolution, resolution}}

  @doc """
  Decides whether policy text accepts, rejects, or misses all policy branches.
  """
  @spec decide(t(), String.t()) :: decision()
  def decide(%__MODULE__{} = policy, text) when is_binary(text) do
    cond do
      label = match_branch(policy.accepts, text) -> {:accept, label}
      label = match_branch(policy.rejects, text) -> {:reject, label}
      true -> :no_match
    end
  end

  @spec resume_policy(t(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp resume_policy(policy, input, ctx) do
    case decide(policy, input.text) do
      {:accept, label} -> approve(policy, label, input, ctx)
      {:reject, label} -> reject(policy, label, input, ctx)
      :no_match -> retry(policy, input, ctx)
    end
  end

  @spec approve(t(), atom(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp approve(policy, label, input, %{state: state}) do
    with {:ok, transition} <- Lifecycle.resolve_policy(state, :accept, label) do
      approved = transition.effect
      awaitable = transition.awaitable

      {:ok,
       %Result{
         input: input,
         state: transition.to,
         reply_text: "",
         effects: [approved],
         awaitables: [awaitable],
         events: [
           %{
             type: :awaitable_accepted,
             kind: :policy,
             name: policy_identifier(policy),
             label: label
           },
           %{
             type: :effect_approved,
             kind: approved.kind,
             name: approved.name,
             owner: approved.owner,
             scope: approved.scope,
             effect_id: approved.id,
             idempotency_key: Effect.idempotency_key(approved)
           }
         ]
       }}
    end
  end

  @spec reject(t(), atom(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()}
  defp reject(policy, label, input, %{state: state}) do
    {:ok, transition} = Lifecycle.resolve_policy(state, :reject, label)
    cancelled = transition.effect

    {:ok,
     %Result{
       input: input,
       state: transition.to,
       reply_text: "",
       effects: [cancelled],
       awaitables: [transition.awaitable],
       events: [
         %{
           type: :awaitable_rejected,
           kind: :policy,
           name: policy_identifier(policy),
           label: label
         },
         %{
           type: :effect_cancelled,
           kind: :action,
           name: cancelled.name,
           owner: cancelled.owner,
           scope: cancelled.scope,
           effect_id: cancelled.id,
           reason: {:policy_rejected, label}
         }
       ]
     }}
  end

  @spec retry(t(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp retry(policy, input, %{state: state} = ctx) do
    awaitable = state |> State.open_policy_awaitable() |> Awaitable.increment()
    state = State.replace_awaitable(state, awaitable)

    if exceeded_attempts?(policy, awaitable) do
      finish_attempts(policy, input, %{ctx | state: state})
    else
      reply_otherwise(policy, input, %{ctx | state: state})
    end
  end

  @spec exceeded_attempts?(t(), Awaitable.t()) :: boolean()
  defp exceeded_attempts?(%__MODULE__{max_attempts: nil}, _awaitable), do: false

  defp exceeded_attempts?(%__MODULE__{max_attempts: max}, %Awaitable{attempts: attempts}),
    do: attempts >= max

  @spec finish_attempts(t(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp finish_attempts(%__MODULE__{then: :cancel_pending} = policy, input, ctx) do
    cancel_attempts(policy, input, ctx)
  end

  defp finish_attempts(%__MODULE__{then: function}, input, ctx)
       when is_atom(function) and not is_nil(function) do
    opts = Keyword.put(ctx.opts, :handler_owner, policy_owner(ctx))
    Spectre.Runner.run_function(function, input, %{ctx | opts: opts})
  end

  defp finish_attempts(%__MODULE__{} = policy, input, ctx) do
    cancel_attempts(policy, input, ctx)
  end

  @spec cancel_attempts(t(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()}
  defp cancel_attempts(policy, input, %{state: state}) do
    awaitable = state |> State.open_policy_awaitable() |> Awaitable.cancel()

    cancelled =
      state.pending_effects |> Enum.map(&Spectre.Effect.cancel(&1, :policy_attempts_exceeded))

    state =
      state
      |> State.replace_awaitable(awaitable)
      |> State.clear_pending()
      |> record_resolved_effects(cancelled)

    {:ok,
     %Result{
       input: input,
       state: state,
       effects: cancelled,
       awaitables: [awaitable],
       events: [
         %{type: :awaitable_cancelled, kind: :policy, name: policy_identifier(policy)}
         | Enum.map(cancelled, &cancelled_event(&1, :policy_attempts_exceeded))
       ]
     }}
  end

  @spec cancelled_event(Effect.t(), term()) :: map()
  defp cancelled_event(%Effect{} = effect, reason) do
    %{
      type: :effect_cancelled,
      kind: effect.kind,
      name: effect.name,
      owner: effect.owner,
      scope: effect.scope,
      effect_id: effect.id,
      reason: reason
    }
  end

  @spec reply_otherwise(t(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp reply_otherwise(%__MODULE__{otherwise: {:ask, prompt}} = policy, input, ctx) do
    prompt_opts = [
      policy_prompt?: true,
      policy: policy_identifier(policy),
      prompt_scope: policy.scope,
      prompt_owner: policy.owner
    ]

    with {:ok, %Result{} = result} <- Spectre.Runner.ask(prompt, input, ctx, prompt_opts) do
      {:ok,
       %{
         result
         | awaitables: ctx.state.awaitables,
           events: [
             %{type: :awaitable_pending, kind: :policy, name: policy_identifier(policy)}
             | result.events
           ]
       }}
    end
  end

  defp reply_otherwise(policy, input, ctx) do
    {:ok,
     %Result{
       input: input,
       state: ctx.state,
       awaitables: ctx.state.awaitables,
       events: [%{type: :awaitable_pending, kind: :policy, name: policy_identifier(policy)}]
     }}
  end

  @spec record_resolved_effects(State.t(), [Spectre.Effect.t()]) :: State.t()
  defp record_resolved_effects(%State{} = state, effects) do
    %{state | planned_effects: Enum.take(state.planned_effects, -31) ++ effects}
  end

  @spec match_branch([map()], String.t()) :: atom() | nil
  defp match_branch(branches, text) do
    Enum.find_value(branches, fn branch ->
      regexes = branch |> Map.get(:regex, []) |> List.wrap()

      if Enum.any?(regexes, &Regex.match?(&1, text)) do
        Map.fetch!(branch, :label)
      end
    end)
  end

  @spec active_policy(Spectre.Context.t() | map()) :: {:ok, t()} | {:error, term()}
  defp active_policy(%{agent: agent, state: %State{} = state}) do
    case State.open_policy_awaitable(state) do
      %Awaitable{name: policy_name} ->
        case find_policy(agent, policy_name) do
          %__MODULE__{} = policy -> {:ok, policy}
          nil -> {:error, {:unknown_policy, policy_name}}
        end

      nil ->
        {:error, :no_open_policy}
    end
  end

  @spec validate_resolution(t(), resolution()) :: :ok | {:error, term()}
  defp validate_resolution(%__MODULE__{} = policy, {kind, label}) do
    branches = if kind == :accept, do: policy.accepts, else: policy.rejects

    if Enum.any?(branches, &(Map.get(&1, :label) == label)) do
      :ok
    else
      {:error, {:unknown_policy_resolution_label, policy_identifier(policy), kind, label}}
    end
  end

  @spec apply_resolution(t(), resolution(), Input.t(), Spectre.Context.t() | map()) ::
          {:ok, Result.t()} | {:error, term()}
  defp apply_resolution(policy, {:accept, label}, input, ctx),
    do: approve(policy, label, input, ctx)

  defp apply_resolution(policy, {:reject, label}, input, ctx),
    do: reject(policy, label, input, ctx)

  @spec find_policy(module(), term()) :: t() | nil
  defp find_policy(agent, name) do
    case Spectre.Definition.policy(agent, name) do
      {:ok, policy, scope} ->
        definition = Spectre.Definition.for_scope!(agent, scope)

        policy
        |> Map.put(:reference, Spectre.Definition.policy_ref(scope, policy.name))
        |> Map.put(:scope, scope)
        |> Map.put(:owner, definition.owner)
        |> new()

      {:error, _reason} ->
        nil
    end
  end

  @spec policy_identifier(t()) :: term()
  defp policy_identifier(%__MODULE__{reference: nil, name: name}), do: name
  defp policy_identifier(%__MODULE__{reference: reference}), do: reference

  @spec policy_owner(Spectre.Context.t() | map()) :: module()
  defp policy_owner(%{agent: agent, state: %State{} = state}) do
    case State.open_policy_awaitable(state) do
      %Awaitable{name: reference} ->
        scope = Spectre.Definition.policy_scope(reference)
        Spectre.Definition.for_scope!(agent, scope).owner

      nil ->
        agent
    end
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
