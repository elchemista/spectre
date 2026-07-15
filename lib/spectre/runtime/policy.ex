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
  alias Spectre.Result
  alias Spectre.State

  defstruct [
    :name,
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
        name: policy.name,
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
    case State.open_policy_awaitable(state) do
      nil ->
        {:error, :no_open_policy}

      %Awaitable{} = open ->
        with {:ok, state, approved} <-
               State.approve_pending_effect(state, open.subject_id) do
          awaitable = Awaitable.accept(open, label)

          state =
            state
            |> State.replace_awaitable(awaitable)
            |> State.clear_open_awaitables()
            |> State.trace(%{
              type: :awaitable_accepted,
              kind: :policy,
              name: policy.name,
              label: label,
              subject_id: open.subject_id,
              at: DateTime.utc_now()
            })

          {:ok,
           %Result{
             input: input,
             state: state,
             reply_text: "",
             effects: [approved],
             awaitables: [awaitable],
             events: [
               %{type: :awaitable_accepted, kind: :policy, name: policy.name, label: label},
               %{
                 type: :effect_approved,
                 kind: approved.kind,
                 name: approved.name,
                 effect_id: approved.id,
                 idempotency_key: Effect.idempotency_key(approved)
               }
             ]
           }}
        end
    end
  end

  @spec reject(t(), atom(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()}
  defp reject(policy, label, input, %{state: state}) do
    awaitable = state |> State.open_policy_awaitable() |> Awaitable.reject(label)

    cancelled =
      state.pending_effects |> Enum.map(&Spectre.Effect.cancel(&1, {:policy_rejected, label}))

    state =
      state
      |> State.replace_awaitable(awaitable)
      |> State.clear_pending()
      |> record_resolved_effects(cancelled)
      |> State.trace(%{
        type: :awaitable_rejected,
        kind: :policy,
        name: policy.name,
        label: label,
        at: DateTime.utc_now()
      })

    {:ok,
     %Result{
       input: input,
       state: state,
       reply_text: "",
       effects: cancelled,
       awaitables: [awaitable],
       events: [
         %{type: :awaitable_rejected, kind: :policy, name: policy.name, label: label},
         %{type: :effect_cancelled, kind: :action, reason: {:policy_rejected, label}}
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
    Spectre.Runner.run_function(function, input, ctx)
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
         %{type: :awaitable_cancelled, kind: :policy, name: policy.name},
         %{type: :effect_cancelled, kind: :action, reason: :policy_attempts_exceeded}
       ]
     }}
  end

  @spec reply_otherwise(t(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp reply_otherwise(%__MODULE__{otherwise: {:ask, prompt}} = policy, input, ctx) do
    with {:ok, %Result{} = result} <- Spectre.Runner.ask(prompt, input, ctx, policy_prompt?: true) do
      {:ok,
       %{
         result
         | awaitables: ctx.state.awaitables,
           events: [%{type: :awaitable_pending, kind: :policy, name: policy.name} | result.events]
       }}
    end
  end

  defp reply_otherwise(policy, input, ctx) do
    {:ok,
     %Result{
       input: input,
       state: ctx.state,
       awaitables: ctx.state.awaitables,
       events: [%{type: :awaitable_pending, kind: :policy, name: policy.name}]
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
      {:error, {:unknown_policy_resolution_label, policy.name, kind, label}}
    end
  end

  @spec apply_resolution(t(), resolution(), Input.t(), Spectre.Context.t() | map()) ::
          {:ok, Result.t()} | {:error, term()}
  defp apply_resolution(policy, {:accept, label}, input, ctx),
    do: approve(policy, label, input, ctx)

  defp apply_resolution(policy, {:reject, label}, input, ctx),
    do: reject(policy, label, input, ctx)

  @spec find_policy(module(), atom()) :: t() | nil
  defp find_policy(agent, name) do
    agent.__spectre_policies__()
    |> Map.get(name)
    |> case do
      nil -> nil
      policy -> new(policy)
    end
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
