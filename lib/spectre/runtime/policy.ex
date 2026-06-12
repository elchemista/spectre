defmodule Spectre.Policy do
  @moduledoc """
  Policy gate evaluator for pending actions.
  """

  alias Spectre.{Awaiting, Input, Result, State}

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
  def resume(%Input{} = input, %{state: %State{awaiting: %Awaiting{policy: policy_name}}} = ctx) do
    case find_policy(ctx.agent, policy_name) do
      %__MODULE__{} = policy -> resume_policy(policy, input, ctx)
      nil -> {:error, {:unknown_policy, policy_name}}
    end
  end

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
  defp approve(policy, label, input, ctx) do
    state = State.clear_awaiting(ctx.state)

    case Spectre.ActionExecutor.execute_pending(state, %{ctx | state: state}, policy: policy.name) do
      {:ok, %Result{} = result} ->
        {:ok,
         %{
           result
           | input: input,
             events: [%{type: :policy_accepted, label: label} | result.events]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reject(t(), atom(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()}
  defp reject(_policy, label, input, ctx) do
    state =
      ctx.state
      |> State.clear_pending()
      |> State.trace(%{type: :policy_rejected, label: label, at: DateTime.utc_now()})

    {:ok,
     %Result{
       input: input,
       state: state,
       reply_text: "",
       events: [%{type: :policy_rejected, label: label}]
     }}
  end

  @spec retry(t(), Input.t(), Spectre.Context.t()) :: {:ok, Result.t()} | {:error, term()}
  defp retry(policy, input, %{state: %{awaiting: awaiting} = state} = ctx) do
    awaiting = Awaiting.increment(awaiting)
    state = %{state | awaiting: awaiting}

    if exceeded_attempts?(policy, awaiting) do
      finish_attempts(policy, input, %{ctx | state: state})
    else
      reply_otherwise(policy, input, %{ctx | state: state})
    end
  end

  @spec exceeded_attempts?(t(), Awaiting.t()) :: boolean()
  defp exceeded_attempts?(%__MODULE__{max_attempts: nil}, _awaiting), do: false

  defp exceeded_attempts?(%__MODULE__{max_attempts: max}, %Awaiting{attempts: attempts}),
    do: attempts >= max

  @spec finish_attempts(t(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp finish_attempts(%__MODULE__{then: :cancel_pending}, input, ctx) do
    state = State.cancel_pending(ctx.state)

    {:ok,
     %Result{
       input: input,
       state: state,
       events: [%{type: :policy_attempts_exceeded}]
     }}
  end

  defp finish_attempts(%__MODULE__{then: function}, input, ctx)
       when is_atom(function) and not is_nil(function) do
    Spectre.Runner.run_function(function, input, ctx)
  end

  defp finish_attempts(_policy, input, ctx) do
    {:ok,
     %Result{
       input: input,
       state: State.cancel_pending(ctx.state),
       events: [%{type: :policy_attempts_exceeded}]
     }}
  end

  @spec reply_otherwise(t(), Input.t(), Spectre.Context.t()) ::
          {:ok, Result.t()} | {:error, term()}
  defp reply_otherwise(%__MODULE__{otherwise: {:ask, prompt}}, input, ctx) do
    Spectre.Runner.ask(prompt, input, ctx, policy_prompt?: true)
  end

  defp reply_otherwise(_policy, input, ctx) do
    {:ok,
     %Result{
       input: input,
       state: ctx.state,
       events: [%{type: :policy_no_match}]
     }}
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
