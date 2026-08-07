defmodule Spectre.Instance.Conversation do
  @moduledoc false

  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Run
  alias Spectre.Run.Boundary
  alias Spectre.Run.Value

  @doc """
  Resolves the Run at a policy boundary that owns the supplied input.

  Matches on exact conversation reference first, then falls back to the
  origin conversation when the input has no source. Multiple candidates are
  an explicit ambiguity instead of a silent pick.
  """
  @spec policy_owner(InstanceState.t(), term(), keyword()) ::
          {:ok, Run.t()} | :none | {:error, term()}
  def policy_owner(%InstanceState{} = data, input, opts) do
    policies =
      data.runs
      |> Map.values()
      |> Enum.filter(&policy_boundary?/1)
      |> Enum.sort_by(& &1.id)

    origin_conversation_id =
      first_present([
        Keyword.get(opts, :origin_conversation_id),
        Keyword.get(opts, :conversation_id),
        input_conversation_id(input)
      ])

    conversation_ref = conversation_key(input, origin_conversation_id)
    origin_conversation_ref = origin_conversation_key(origin_conversation_id)
    source_missing? = conversation_source_missing?(input)

    matches =
      Enum.filter(
        policies,
        &policy_origin_matches?(
          &1,
          conversation_ref,
          origin_conversation_ref,
          source_missing?
        )
      )

    select_policy_owner(matches, policies, origin_conversation_id)
  end

  @doc "Records one started conversation keyed by its stable token."
  @spec record_conversation(InstanceState.t(), Run.t(), keyword()) :: InstanceState.t()
  def record_conversation(%InstanceState{} = data, %Run{} = run, opts) do
    origin_conversation_id =
      first_present([
        Keyword.get(opts, :origin_conversation_id),
        input_conversation_id(run.input)
      ])

    case conversation_key(run.input, origin_conversation_id) do
      nil ->
        data

      key ->
        source = input_source(run.input)
        current = Map.get(data.conversations, key, %{count: 0})

        conversation =
          current
          |> Map.put(:key, key)
          |> Map.put(:channel, source_field(source, :kind))
          |> Map.put(:mount, source_field(source, :mount))
          |> Map.put(:last_run_id, run.id)
          |> Map.update!(:count, &(&1 + 1))

        %{data | conversations: Map.put(data.conversations, key, conversation)}
    end
  end

  @doc "Builds the portable conversation token for an input, or nil."
  @spec conversation_key(term(), term()) :: String.t() | nil
  def conversation_key(_input, nil), do: nil

  def conversation_key(input, conversation_id) do
    source = input_source(input)

    value = {
      source_field(source, :kind),
      source_field(source, :mount),
      conversation_id
    }

    case Value.validate(value, [:instance, :conversation]) do
      :ok -> Value.token("conversation", value)
      {:error, _reason} -> nil
    end
  end

  @doc "Builds the portable origin-conversation token, or nil."
  @spec origin_conversation_key(term()) :: String.t() | nil
  def origin_conversation_key(nil), do: nil

  def origin_conversation_key(conversation_id) do
    case Value.validate(conversation_id, [:instance, :origin_conversation]) do
      :ok -> Value.token("origin-conversation", conversation_id)
      {:error, _reason} -> nil
    end
  end

  @doc "Extracts the conversation id declared by the input source, if any."
  @spec input_conversation_id(term()) :: term()
  def input_conversation_id(input),
    do: input |> input_source() |> source_field(:conversation_id)

  @doc "Returns the first non-nil value."
  @spec first_present([term()]) :: term()
  def first_present(values), do: Enum.find(values, &(not is_nil(&1)))

  defp policy_origin_matches?(
         %Run{metadata: metadata},
         conversation_ref,
         origin_conversation_ref,
         source_missing?
       ) do
    exact? =
      not is_nil(conversation_ref) and
        Map.get(metadata, :conversation_ref) == conversation_ref

    fallback? =
      source_missing? and not is_nil(origin_conversation_ref) and
        Map.get(metadata, :origin_conversation_ref) == origin_conversation_ref

    exact? or fallback?
  end

  defp select_policy_owner([%Run{} = run], _policies, _origin), do: {:ok, run}

  defp select_policy_owner([_first, _second | _rest] = matches, _policies, _origin),
    do: {:error, {:ambiguous_instance_policy, Enum.map(matches, & &1.id)}}

  defp select_policy_owner([], _policies, origin) when not is_nil(origin), do: :none
  defp select_policy_owner([], [%Run{} = run], nil), do: {:ok, run}

  defp select_policy_owner([], [_first, _second | _rest] = policies, nil),
    do: {:error, {:ambiguous_instance_policy, Enum.map(policies, & &1.id)}}

  defp select_policy_owner([], [], nil), do: :none

  defp policy_boundary?(%Run{
         status: :boundary,
         cursor: :policy,
         waiting: %Boundary{kind: :needs}
       }),
       do: true

  defp policy_boundary?(_run), do: false

  defp conversation_source_missing?(input) do
    source = input_source(input)
    is_nil(source_field(source, :kind)) and is_nil(source_field(source, :mount))
  end

  defp input_source(input) when is_map(input),
    do: Map.get(input, :source, Map.get(input, "source"))

  defp input_source(_input), do: nil

  defp source_field(source, key) when is_map(source),
    do: Map.get(source, key, Map.get(source, Atom.to_string(key)))

  defp source_field(_source, _key), do: nil
end
