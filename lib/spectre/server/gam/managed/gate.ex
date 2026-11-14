defmodule Spectre.Server.GAM.Managed.Gate do
  @moduledoc false
  use GenServer

  @doc false
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config)

  @doc false
  @spec authenticate(pid(), binary()) :: {:ok, map()} | {:error, atom()}
  def authenticate(server, token), do: GenServer.call(server, {:authenticate, token})

  @doc false
  @spec show(pid(), map(), pid()) :: :ok | {:error, atom()}
  def show(server, material, worker), do: GenServer.call(server, {:show, material, worker})

  @doc false
  @spec presented(pid(), binary(), pid()) :: :ok | {:error, atom()}
  def presented(server, ref, caller), do: GenServer.call(server, {:presented, ref, caller})

  @doc false
  @spec bind_deadline(pid(), binary(), integer() | nil | :infinity, binary() | nil) ::
          :ok | {:error, atom()}
  def bind_deadline(server, ref, deadline, show_ref \\ nil),
    do: GenServer.call(server, {:bind_deadline, ref, deadline, show_ref})

  @doc false
  @spec close_show(pid(), binary()) :: :ok
  def close_show(server, show_ref), do: GenServer.call(server, {:close_show, show_ref})

  @doc false
  @spec authorize(pid(), binary(), atom(), pid()) :: {:ok, binary()} | {:error, atom()}
  def authorize(server, ref, decision, caller),
    do: GenServer.call(server, {:authorize, ref, decision, caller})

  @doc false
  @spec authorize_input(pid(), binary(), binary(), pid()) :: {:ok, binary()} | {:error, atom()}
  def authorize_input(server, ref, text, caller),
    do: GenServer.call(server, {:authorize_input, ref, text, caller})

  @doc false
  @spec consume(pid(), binary(), atom(), binary() | nil, binary() | nil) :: :ok | {:error, atom()}
  def consume(server, ref, stance, proof, source_digest \\ nil),
    do: GenServer.call(server, {:consume, ref, stance, proof, source_digest})

  @impl true
  def init(config), do: {:ok, Map.merge(config, %{shows: %{}, proofs: %{}})}

  @impl true
  def handle_call({:authenticate, token}, _from, state) do
    reply = if token == state.token, do: {:ok, state.auth}, else: {:error, :unauthenticated}
    {:reply, reply, state}
  end

  def handle_call({:show, material, worker}, _from, state) do
    state = prune(state)
    ref = material["presentation_ref"]

    show = %{
      worker: worker,
      shown: false,
      authorized: false,
      deadline_bound: false,
      show_ref: nil,
      expires_at: System.system_time(:millisecond) + state.show_timeout
    }

    cond do
      not is_pid(state.consumer) ->
        {:reply, {:error, :presentation_consumer_unavailable}, state}

      Map.has_key?(state.shows, ref) ->
        {:reply, {:error, :presentation_already_pending}, state}

      map_size(state.shows) >= 256 ->
        {:reply, {:error, :presentation_capacity_exceeded}, state}

      true ->
        send(state.consumer, {Spectre.Server.GAM.Managed, state.owner, {:presentation, material}})
        {:reply, :ok, %{state | shows: Map.put(state.shows, ref, show)}}
    end
  end

  def handle_call({:presented, ref, caller}, {runtime, _}, state) do
    case Map.get(state.shows, ref) do
      %{shown: false, worker: worker, expires_at: deadline} = show ->
        if runtime == state.runtime and caller == state.consumer and
             System.system_time(:millisecond) <= deadline do
          send(worker, {:spectre_managed_presented, ref})

          {:reply, :ok,
           %{
             state
             | shows:
                 Map.put(state.shows, ref, %{
                   show
                   | shown: true
                 })
           }}
        else
          {:reply, {:error, :presentation_not_authorized}, state}
        end

      _ ->
        {:reply, {:error, :presentation_not_pending}, state}
    end
  end

  def handle_call({:bind_deadline, ref, deadline, show_ref}, {worker, _}, state)
      when is_integer(deadline) or deadline in [nil, :infinity] do
    deadline = if is_nil(deadline), do: :infinity, else: deadline

    case Map.get(state.shows, ref) do
      %{shown: true, deadline_bound: true, expires_at: ^deadline} ->
        {:reply, :ok, state}

      %{shown: true, worker: ^worker, deadline_bound: false} = show ->
        bound = %{show | deadline_bound: true, expires_at: deadline, show_ref: show_ref}
        {:reply, :ok, %{state | shows: Map.put(state.shows, ref, bound)}}

      _ ->
        {:reply, {:error, :presentation_deadline_not_authorized}, state}
    end
  end

  def handle_call({:close_show, show_ref}, _from, state) do
    refs = for {ref, %{show_ref: ^show_ref}} <- state.shows, do: ref
    shows = Map.drop(state.shows, refs)
    proofs = Map.reject(state.proofs, fn {_, proof} -> proof.ref in refs end)
    {:reply, :ok, %{state | shows: shows, proofs: proofs}}
  end

  def handle_call({:authorize, ref, decision, caller}, {runtime, _}, state) do
    state = prune(state)

    with true <- runtime == state.runtime and caller == state.consumer,
         true <- decision in [:confirm, :reject],
         %{shown: true, deadline_bound: true, expires_at: deadline} = show <-
           Map.get(state.shows, ref) do
      issue_proof(state, ref, show, %{
        kind: :decision,
        stance: if(decision == :confirm, do: :supports, else: :contradicts),
        expires_at: deadline
      })
    else
      _ -> {:reply, {:error, :consent_transport_not_authorized}, state}
    end
  end

  def handle_call({:authorize_input, ref, text, caller}, {runtime, _}, state) do
    state = prune(state)

    with true <- runtime == state.runtime and caller == state.consumer,
         true <- is_binary(text) and byte_size(text) > 0,
         %{shown: true, deadline_bound: true, expires_at: deadline} = show <-
           Map.get(state.shows, ref) do
      digest = Base.encode16(:crypto.hash(:sha256, text), case: :lower)
      issue_proof(state, ref, show, %{kind: :input, source_digest: digest, expires_at: deadline})
    else
      _ -> {:reply, {:error, :consent_transport_not_authorized}, state}
    end
  end

  def handle_call({:consume, ref, stance, proof, source_digest}, _from, state) do
    state = prune(state)

    case Map.get(state.proofs, proof) do
      %{ref: ^ref, kind: :decision, stance: ^stance} ->
        consumed(state, ref, proof)

      %{ref: ^ref, kind: :input, source_digest: ^source_digest}
      when is_binary(source_digest) and stance in [:supports, :contradicts] ->
        consumed(state, ref, proof)

      _ ->
        {:reply, {:error, :consent_transport_proof_required}, state}
    end
  end

  @spec issue_proof(map(), binary(), map(), map()) :: {:reply, {:ok, binary()}, map()}
  defp issue_proof(state, ref, show, value) do
    proof = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    value = Map.put(value, :ref, ref)

    proofs =
      state.proofs |> Map.reject(fn {_, old} -> old.ref == ref end) |> Map.put(proof, value)

    {:reply, {:ok, proof},
     %{state | proofs: proofs, shows: Map.put(state.shows, ref, %{show | authorized: true})}}
  end

  @spec consumed(map(), binary(), binary()) :: {:reply, :ok, map()}
  defp consumed(state, ref, proof),
    do:
      {:reply, :ok,
       %{state | proofs: Map.delete(state.proofs, proof), shows: Map.delete(state.shows, ref)}}

  @impl true
  def format_status(status) do
    state = status.state

    %{
      status
      | state: %{
          pending_presentations: map_size(state.shows),
          pending_decisions: map_size(state.proofs)
        }
    }
  end

  @spec expired?(integer() | :infinity, integer()) :: boolean()
  defp expired?(:infinity, _now), do: false
  defp expired?(deadline, now), do: deadline <= now

  @spec prune(map()) :: map()
  defp prune(state) do
    now = System.system_time(:millisecond)

    %{
      state
      | shows: Map.reject(state.shows, fn {_, value} -> expired?(value.expires_at, now) end),
        proofs: Map.reject(state.proofs, fn {_, value} -> expired?(value.expires_at, now) end)
    }
  end
end
