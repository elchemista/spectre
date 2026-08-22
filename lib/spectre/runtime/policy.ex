defmodule Spectre.Policy do
  @moduledoc """
  Policy gate evaluator for pending effects.

  A conversation-resolved policy is a temporary deterministic router for one
  pending effect. Externally resolved policies keep normal flow routing active
  and accept only an addressed trusted-host decision.
  """

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Lifecycle
  alias Spectre.Policy.Matcher
  alias Spectre.Policy.Resolution
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
  @type resolution :: {:accept, atom()} | {:reject, atom()} | Resolution.t()

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

  @doc false
  @spec awaiting?(State.t(), String.t() | nil) :: boolean()
  def awaiting?(%State{} = state, run_id), do: State.awaiting_policy?(state, run_id)

  @doc false
  @spec captures_conversation?(State.t(), String.t() | nil) :: boolean()
  def captures_conversation?(%State{} = state, run_id \\ nil) do
    match?(
      %Awaitable{resolver: :conversation},
      State.open_policy_awaitable(state, run_id)
    )
  end

  @doc """
  Resumes the active policy with the user's latest input.
  """
  @spec resume(Input.t(), Spectre.Context.t()) :: {:ok, Result.t()} | {:error, term()}
  def resume(%Input{} = input, %{state: %State{} = state} = ctx) do
    case State.open_policy_awaitable(state, lifecycle_run_id(ctx)) do
      %Awaitable{resolver: :external, id: awaitable_id} ->
        {:error, {:policy_resolution_source_not_allowed, awaitable_id, :external, :conversation}}

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
  def resolve({kind, label}, %Input{} = input, %{state: %State{}} = ctx)
      when kind in [:accept, :reject] and is_atom(label) do
    with {:ok, resolution} <- Resolution.new(kind, label, :host) do
      resolve(resolution, input, ctx)
    end
  end

  def resolve(%Resolution{} = resolution, %Input{} = input, %{state: %State{}} = ctx) do
    resolve_with_awaitable(nil, resolution, input, ctx)
  end

  def resolve(resolution, _input, _ctx), do: {:error, {:invalid_policy_resolution, resolution}}

  @doc false
  @spec resolve(term(), resolution(), Input.t(), Spectre.Context.t() | map()) ::
          {:ok, Result.t()} | {:error, term()}
  def resolve(awaitable_id, {kind, label}, %Input{} = input, %{state: %State{}} = ctx)
      when kind in [:accept, :reject] and is_atom(label) do
    with {:ok, resolution} <- Resolution.new(kind, label, :host) do
      resolve(awaitable_id, resolution, input, ctx)
    end
  end

  def resolve(
        awaitable_id,
        %Resolution{} = resolution,
        %Input{} = input,
        %{state: %State{}} = ctx
      ) do
    resolve_with_awaitable(awaitable_id, resolution, input, ctx)
  end

  def resolve(awaitable_id, resolution, _input, _ctx),
    do: {:error, {:invalid_policy_resolution, awaitable_id, resolution}}

  @spec resolve_with_awaitable(
          term() | nil,
          Resolution.t(),
          Input.t(),
          Spectre.Context.t() | map()
        ) :: {:ok, Result.t()} | {:error, term()}
  defp resolve_with_awaitable(awaitable_id, resolution, input, ctx) do
    tuple = Resolution.to_tuple(resolution)

    with {:ok, policy, awaitable} <- active_policy(ctx, awaitable_id),
         :ok <- validate_resolution_address(awaitable_id, awaitable),
         :ok <- validate_resolution_source(awaitable, resolution),
         :ok <- validate_resolution(policy, tuple),
         {:ok, %Result{} = result} <-
           apply_resolution(policy, awaitable, tuple, input, ctx) do
      result = annotate_resolution_events(result, resolution, awaitable)

      event = %{
        type: :policy_resolved,
        source: resolution.source,
        resolver: awaitable.resolver,
        kind: resolution.kind,
        name: policy_identifier(policy),
        label: resolution.label,
        metadata: resolution.metadata
      }

      {:ok, %{result | events: result.events ++ [event]}}
    end
  end

  @spec validate_resolution_address(term() | nil, Awaitable.t()) ::
          :ok | {:error, term()}
  defp validate_resolution_address(nil, %Awaitable{id: id, resolver: :external}),
    do: {:error, {:external_policy_requires_awaitable_id, id}}

  defp validate_resolution_address(_awaitable_id, %Awaitable{}), do: :ok

  @spec annotate_resolution_events(Result.t(), Resolution.t(), Awaitable.t()) :: Result.t()
  defp annotate_resolution_events(%Result{} = result, resolution, awaitable) do
    events =
      Enum.map(result.events, fn
        %{type: type} = event when type in [:awaitable_accepted, :awaitable_rejected] ->
          event
          |> Map.put(:source, resolution.source)
          |> Map.put(:resolver, awaitable.resolver)

        event ->
          event
      end)

    %{result | events: events}
  end

  @doc """
  Decides whether policy text accepts, rejects, or misses all policy branches.
  """
  @spec decide(t(), String.t()) :: decision()
  def decide(%__MODULE__{} = policy, text) when is_binary(text) do
    case Matcher.match(policy, text) do
      {:ok, %Resolution{} = resolution} -> Resolution.to_tuple(resolution)
      :no_match -> :no_match
    end
  end

  @spec resume_policy(t(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp resume_policy(policy, input, ctx) do
    case Matcher.match(policy, input.text) do
      {:ok, %Resolution{kind: :accept, label: label}} ->
        approve(policy, current_awaitable(ctx), label, input, ctx)

      {:ok, %Resolution{kind: :reject, label: label}} ->
        reject(policy, current_awaitable(ctx), label, input, ctx)

      :no_match ->
        retry(policy, input, ctx)
    end
  end

  @spec approve(t(), Awaitable.t() | nil, atom(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp approve(policy, current, label, input, %{state: state}) do
    with %Awaitable{} <- current,
         {:ok, transition} <- Lifecycle.resolve_policy(state, current.id, :accept, label) do
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
    else
      nil -> {:error, :no_open_policy}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec reject(t(), Awaitable.t() | nil, atom(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp reject(policy, current, label, input, %{state: state}) do
    with %Awaitable{} <- current,
         {:ok, transition} <- Lifecycle.resolve_policy(state, current.id, :reject, label) do
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
    else
      nil -> {:error, :no_open_policy}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec retry(t(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp retry(policy, input, %{state: state} = ctx) do
    current = State.open_policy_awaitable(state, lifecycle_run_id(ctx))
    {:ok, transition} = Lifecycle.apply(state, {:policy_attempt, current.id})
    awaitable = transition.awaitable
    state = transition.to

    Spectre.Telemetry.emit(
      [:policy, :retry],
      %{attempts: awaitable.attempts},
      %{policy: policy_identifier(policy), awaitable_id: awaitable.id},
      ctx.opts
    )

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
  defp cancel_attempts(policy, input, %{state: state} = ctx) do
    command =
      case lifecycle_run_id(ctx) do
        nil -> {:cancel_pending, :policy_attempts_exceeded}
        run_id -> {:cancel_pending, :policy_attempts_exceeded, run_id}
      end

    {:ok, transition} = Lifecycle.apply(state, command)
    state = transition.to
    awaitable = transition.awaitable
    cancelled = List.wrap(transition.effect)

    {:ok,
     %Result{
       input: input,
       state: state,
       effects: cancelled,
       awaitables: List.wrap(awaitable),
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
         | awaitables: current_policy_awaitables(ctx),
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
       awaitables: current_policy_awaitables(ctx),
       events: [%{type: :awaitable_pending, kind: :policy, name: policy_identifier(policy)}]
     }}
  end

  @spec active_policy(Spectre.Context.t() | map(), term() | nil) ::
          {:ok, t(), Awaitable.t()} | {:error, term()}
  defp active_policy(%{agent: agent} = ctx, awaitable_id) do
    with {:ok, %Awaitable{name: policy_name} = awaitable} <-
           addressed_awaitable(ctx, awaitable_id),
         {:ok, %__MODULE__{} = policy} <- fetch_policy(agent, policy_name) do
      {:ok, policy, awaitable}
    end
  end

  @spec fetch_policy(module(), term()) :: {:ok, t()} | {:error, term()}
  defp fetch_policy(agent, policy_name) do
    case find_policy(agent, policy_name) do
      %__MODULE__{} = policy -> {:ok, policy}
      nil -> {:error, {:unknown_policy, policy_name}}
    end
  end

  @spec addressed_awaitable(Spectre.Context.t() | map(), term() | nil) ::
          {:ok, Awaitable.t()} | {:error, term()}
  defp addressed_awaitable(%{state: %State{} = state} = ctx, nil) do
    case State.open_policy_awaitable(state, lifecycle_run_id(ctx)) do
      %Awaitable{} = awaitable -> {:ok, awaitable}
      nil -> {:error, :no_open_policy}
    end
  end

  defp addressed_awaitable(%{state: %State{} = state} = ctx, awaitable_id) do
    case Enum.find(state.awaitables, &(&1.id == awaitable_id)) do
      nil ->
        {:error, {:policy_awaitable_not_found, awaitable_id}}

      %Awaitable{kind: kind} when kind != :policy ->
        {:error, {:policy_awaitable_kind_mismatch, awaitable_id, kind}}

      %Awaitable{status: status} when status != :open ->
        {:error, {:policy_awaitable_not_open, awaitable_id, status}}

      %Awaitable{} = awaitable ->
        case lifecycle_run_id(ctx) do
          nil -> {:ok, awaitable}
          run_id when run_id == awaitable.run_id -> {:ok, awaitable}
          run_id -> {:error, {:policy_awaitable_not_owned, awaitable_id, run_id}}
        end
    end
  end

  @spec validate_resolution_source(Awaitable.t(), Resolution.t()) ::
          :ok | {:error, term()}
  defp validate_resolution_source(%Awaitable{} = awaitable, %Resolution{} = resolution) do
    cond do
      awaitable.resolver == :external and resolution.source == :host ->
        :ok

      awaitable.resolver == :external ->
        {:error,
         {:policy_resolution_source_not_allowed, awaitable.id, :external, resolution.source}}

      awaitable.resolver == :conversation ->
        :ok

      true ->
        {:error, {:invalid_policy_resolver, awaitable.id, awaitable.resolver}}
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

  @spec apply_resolution(
          t(),
          Awaitable.t(),
          resolution(),
          Input.t(),
          Spectre.Context.t() | map()
        ) ::
          {:ok, Result.t()} | {:error, term()}
  defp apply_resolution(policy, awaitable, {:accept, label}, input, ctx),
    do: approve(policy, awaitable, label, input, ctx)

  defp apply_resolution(policy, awaitable, {:reject, label}, input, ctx),
    do: reject(policy, awaitable, label, input, ctx)

  @spec current_awaitable(Spectre.Context.t() | map()) :: Awaitable.t() | nil
  defp current_awaitable(%{state: %State{} = state} = ctx),
    do: State.open_policy_awaitable(state, lifecycle_run_id(ctx))

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
  defp policy_owner(%{agent: agent, state: %State{} = state} = ctx) do
    case State.open_policy_awaitable(state, lifecycle_run_id(ctx)) do
      %Awaitable{name: reference} ->
        scope = Spectre.Definition.policy_scope(reference)
        Spectre.Definition.for_scope!(agent, scope).owner

      nil ->
        agent
    end
  end

  @spec current_policy_awaitables(Spectre.Context.t() | map()) :: [Awaitable.t()]
  defp current_policy_awaitables(%{state: %State{} = state} = ctx) do
    state
    |> State.open_policy_awaitable(lifecycle_run_id(ctx))
    |> List.wrap()
  end

  @spec lifecycle_run_id(Spectre.Context.t() | map()) :: String.t() | nil
  defp lifecycle_run_id(%{opts: opts}) when is_list(opts) do
    if Keyword.get(opts, :instance_run_lifecycle?, false),
      do: Keyword.get(opts, :run_id),
      else: nil
  end

  defp lifecycle_run_id(_ctx), do: nil

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
