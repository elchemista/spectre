defmodule Spectre.GAM.Domain.Admission.Fence do
  @moduledoc false

  # Called only by the Domain sequencer. A fence write and the ledger append
  # of a new admission share the same synchronous owner and cannot overlap.
  # The fence store survives loss of that owner and retries the same transition.
  alias Spectre.GAM.Domain.Sequencer.State

  @type origin :: %{ref: binary(), revision: non_neg_integer()}
  @type transition :: %{
          ref: binary(),
          revision: non_neg_integer(),
          transition_id: binary(),
          kind: :revise | :cancel
        }

  @spec register(State.t(), reference(), binary()) :: :ok | {:error, term()}
  def register(state, token, ref) when is_binary(ref) and byte_size(ref) > 0 do
    key = key(state, ref)

    with {:ok, store} <- authorized_store(state, token) do
      case call(store, :put_new, [key, %{revision: 0, transition_id: nil, kind: :start}]) do
        {:ok, _version} -> :ok
        {:error, :exists} -> current(state, token, %{ref: ref, revision: 0})
        {:error, _} = error -> error
      end
    end
  end

  def register(_state, _token, _ref), do: {:error, :invalid_activity_ref}

  @spec retire(State.t(), reference(), binary()) :: :ok | {:error, term()}
  def retire(state, token, ref) when is_binary(ref) and byte_size(ref) > 0 do
    key = key(state, ref)

    with {:ok, store} <- authorized_store(state, token),
         {:ok, %{revision: version}} <- fetch(store, key) do
      call(store, :delete, [key, version])
    else
      {:error, :unknown_activity} -> :ok
      {:error, _} = error -> error
    end
  end

  def retire(_state, _token, _ref), do: {:error, :invalid_activity_ref}

  @spec advance(State.t(), reference(), transition()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def advance(state, token, %{ref: ref, revision: revision, transition_id: id, kind: kind})
      when is_binary(ref) and byte_size(ref) > 0 and is_integer(revision) and revision >= 0 and
             is_binary(id) and byte_size(id) > 0 and kind in [:revise, :cancel] do
    with {:ok, store} <- authorized_store(state, token),
         key = key(state, ref),
         {:ok, entry} <- fetch(store, key) do
      apply_transition(store, key, entry, revision, %{
        revision: revision + 1,
        transition_id: id,
        kind: kind
      })
    end
  end

  def advance(_state, _token, _transition), do: {:error, :invalid_activity_transition}

  @spec authenticate(State.t(), reference(), origin()) :: :ok | {:error, term()}
  def authenticate(state, token, %{ref: ref, revision: revision})
      when is_binary(ref) and byte_size(ref) > 0 and is_integer(revision) and revision >= 0 do
    with {:ok, _store} <- authorized_store(state, token), do: :ok
  end

  def authenticate(_state, _token, _origin), do: {:error, :invalid_activity_origin}

  @spec validate(State.t(), map()) :: :ok | {:error, term()}
  def validate(state, %{activity: {token, origin}}), do: current(state, token, origin)
  def validate(_state, _request), do: :ok

  @spec current(State.t(), reference(), origin()) :: :ok | {:error, term()}
  def current(state, token, %{ref: ref, revision: expected} = origin) do
    with :ok <- authenticate(state, token, origin),
         {:ok, store} <- authorized_store(state, token),
         {:ok, entry} <- fetch(store, key(state, ref)) do
      case entry.value do
        %{revision: ^expected, kind: kind} when kind in [:start, :revise] -> :ok
        _ -> {:error, :superseded}
      end
    end
  end

  def current(_state, _token, _origin), do: {:error, :invalid_activity_origin}

  defp apply_transition(_store, _key, %{value: value}, _revision, value),
    do: {:ok, value.revision}

  defp apply_transition(_store, _key, %{value: %{transition_id: id}}, _revision, %{
         transition_id: id
       }),
       do: {:error, :activity_transition_conflict}

  defp apply_transition(
         store,
         key,
         %{revision: version, value: %{revision: revision, kind: previous}},
         revision,
         value
       )
       when previous in [:start, :revise] do
    case call(store, :compare_and_swap, [key, version, value]) do
      {:ok, _version} -> {:ok, value.revision}
      {:error, _} = error -> error
    end
  end

  defp apply_transition(_store, _key, _entry, _revision, _value), do: {:error, :superseded}

  defp authorized_store(%State{activity_fence: {token, store}}, token) when is_reference(token),
    do: {:ok, store}

  defp authorized_store(_state, _token), do: {:error, :untrusted_activity_transport}

  defp key(state, ref), do: {:spectre_activity_fence, state.projection.domain_ref, ref}

  defp fetch(store, key) do
    case call(store, :fetch, [key]) do
      {:ok, %{revision: version, value: %{revision: revision, transition_id: _, kind: kind}}} =
          entry
      when is_integer(version) and version > 0 and is_integer(revision) and revision >= 0 and
             kind in [:start, :revise, :cancel] ->
        entry

      :not_found ->
        {:error, :unknown_activity}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_activity_fence}
    end
  end

  defp call({module, reference}, operation, args) do
    apply(module, operation, [reference | args])
  rescue
    _ -> {:error, :activity_fence_store_unavailable}
  catch
    :exit, _ -> {:error, :activity_fence_store_unavailable}
  end
end
