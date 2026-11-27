defmodule Spectre.Server.Session do
  @moduledoc false

  alias ExGAM.Canonical.Value
  alias Spectre.Server.Store.{Binding, Disk, Port}
  alias Spectre.Server.TaskGuard

  @enforce_keys [:base_options, :pointer, :domain]
  defstruct [:base_options, :pointer, :domain, :generation, :revision, mode: :configured]

  @type t :: %__MODULE__{
          base_options: keyword(),
          pointer: :memory | {:disk, binary(), term()} | {:store, term(), term()},
          domain: binary(),
          generation: binary() | nil,
          revision: pos_integer() | nil,
          mode: :configured | :memory
        }

  @doc false
  @spec restore(keyword()) :: {:ok, keyword(), t()} | {:error, term()}
  def restore(opts) do
    case Keyword.get(opts, :session) do
      %__MODULE__{} = session ->
        base =
          Keyword.merge(session.base_options, Keyword.take(opts, [:runtime, :runtime_control]))

        session = %{session | base_options: base}

        effective =
          Keyword.merge(effective_options(session), Keyword.take(opts, [:bootstrap_owner]))

        effective =
          if session.mode == :configured,
            do: Keyword.merge(effective, Keyword.take(opts, [:store])),
            else: effective

        {:ok, effective, session}

      nil ->
        restore_configured(Keyword.delete(opts, :session))

      _ ->
        {:error, :invalid_server_session}
    end
  end

  defp restore_configured(opts) do
    domain =
      Keyword.get(
        opts,
        :domain,
        "managed:" <> Value.digest!(%{agent: opts[:agent], identity: opts[:identity]})
      )

    with true <- is_binary(domain) and domain != "",
         {:ok, pointer} <- pointer(opts, domain),
         {:ok, generation, revision} <- read_pointer(pointer) do
      session = %__MODULE__{
        base_options: opts,
        pointer: pointer,
        generation: generation,
        revision: revision,
        domain: session_domain(domain, generation)
      }

      {:ok, effective_options(session), session}
    else
      false -> {:error, :invalid_managed_domain}
      error -> error
    end
  end

  @doc false
  @spec prepare(t(), :configured | :memory) :: {:ok, t(), keyword()} | {:error, term()}
  def prepare(%__MODULE__{} = current, mode) when mode in [:configured, :memory] do
    generation = Spectre.Identity.uuid7()

    candidate = %{
      current
      | generation: generation,
        domain: session_domain(base_domain(current), generation),
        mode: mode
    }

    {:ok, candidate, Keyword.put(effective_options(candidate), :session, candidate)}
  end

  def prepare(_, _), do: {:error, :invalid_server_session_mode}

  @doc false
  @spec activate(t()) :: {:ok, t()} | {:error, term()}
  def activate(%__MODULE__{mode: :memory} = session), do: {:ok, session}
  def activate(%__MODULE__{pointer: :memory} = session), do: {:ok, session}

  def activate(%__MODULE__{generation: generation} = session) when is_binary(generation) do
    value = %{version: 1, generation: generation}

    result =
      with_store(session.pointer, fn store, key ->
        if session.revision,
          do: Port.compare_and_swap(store, key, session.revision, value),
          else: Port.put_new(store, key, value)
      end)

    case result do
      {:ok, revision} -> {:ok, %{session | revision: revision}}
      {:error, reason} when reason in [:exists, :conflict] -> {:error, :session_conflict}
      error -> error
    end
  end

  def activate(_), do: {:error, :invalid_server_session}

  @doc false
  @spec activation_recorded?(t(), binary()) :: boolean()
  def activation_recorded?(%__MODULE__{pointer: pointer}, generation) when is_binary(generation),
    do: match?({:ok, ^generation, _}, read_pointer(pointer))

  @doc false
  @spec runtime_options(t(), keyword()) :: keyword()
  def runtime_options(%__MODULE__{mode: :memory}, opts),
    do: Keyword.drop(opts, [:checkpoint, :checkpoint_domain, :payload_store])

  def runtime_options(%__MODULE__{} = session, opts) do
    opts = Keyword.delete(opts, :checkpoint_domain)

    case Keyword.fetch(Keyword.get(session.base_options, :options, []), :checkpoint) do
      :error ->
        Keyword.delete(opts, :checkpoint)

      {:ok, checkpoint} ->
        Keyword.put(opts, :checkpoint, checkpoint(checkpoint, session.generation))
    end
  end

  defp effective_options(%__MODULE__{} = session) do
    opts = Keyword.put(session.base_options, :domain, session.domain)
    options = runtime_options(session, Keyword.get(opts, :options, []))
    opts = Keyword.put(opts, :options, options)

    case session.mode do
      :memory ->
        opts
        |> Keyword.put(:storage, :ephemeral)
        |> Keyword.put(:store, nil)
        |> Keyword.delete(:payload_store)

      :configured ->
        storage = Keyword.get(session.base_options, :storage, :ephemeral)
        Keyword.put(opts, :storage, storage(storage, session.generation))
    end
  end

  defp base_domain(session) do
    Keyword.get(
      session.base_options,
      :domain,
      "managed:" <>
        Value.digest!(%{
          agent: session.base_options[:agent],
          identity: session.base_options[:identity]
        })
    )
  end

  defp session_domain(domain, nil), do: domain
  defp session_domain(domain, generation), do: domain <> ":session:" <> generation

  defp storage({:disk, path}, generation) when is_binary(generation),
    do: {:disk, Path.join([path, "sessions", generation])}

  defp storage(storage, _generation), do: storage

  defp checkpoint(checkpoint, nil), do: checkpoint
  defp checkpoint(checkpoint, _) when checkpoint in [nil, false], do: checkpoint
  defp checkpoint({store, key}, generation), do: {store, {:spectre_session, key, generation}}

  defp checkpoint({module, store, key}, generation),
    do: {module, store, {:spectre_session, key, generation}}

  defp pointer(opts, domain) do
    key = {:spectre_server_session, domain}

    case Keyword.get(opts, :storage, :ephemeral) do
      :ephemeral ->
        {:ok, :memory}

      {:disk, path} when is_binary(path) ->
        {:ok, {:disk, Path.join(path, "session.store"), key}}

      selection when selection == :ledger or elem(selection, 0) == :ledger ->
        case Binding.configured(opts) do
          {:ok, nil} -> {:error, :managed_ledger_requires_coordination_store}
          {:ok, store} -> {:ok, {:store, store, key}}
          error -> error
        end

      _ ->
        {:error, :invalid_managed_storage}
    end
  end

  defp read_pointer(:memory), do: {:ok, nil, nil}

  defp read_pointer({:disk, path, _key} = pointer) do
    case File.stat(path) do
      {:ok, _} -> read_stored_pointer(pointer)
      {:error, :enoent} -> {:ok, nil, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_pointer(pointer), do: read_stored_pointer(pointer)

  defp read_stored_pointer(pointer), do: pointer |> with_store(&Port.fetch/2) |> decode_pointer()

  defp decode_pointer(:not_found), do: {:ok, nil, nil}

  defp decode_pointer({:ok, %{revision: revision, value: %{version: 1, generation: generation}}})
       when is_integer(revision) and revision > 0 do
    if valid_generation?(generation),
      do: {:ok, generation, revision},
      else: {:error, :invalid_server_session}
  end

  defp decode_pointer({:error, _} = error), do: error
  defp decode_pointer(_), do: {:error, :invalid_server_session}

  defp valid_generation?(generation)
       when is_binary(generation) and byte_size(generation) > 0 and byte_size(generation) <= 128,
       do: String.match?(generation, ~r/\A[a-zA-Z0-9-]+\z/)

  defp valid_generation?(_), do: false

  defp with_store({:store, store, key}, callback),
    do: invoke_store(fn -> callback.(store, key) end)

  defp with_store({:disk, path, key}, callback) do
    invoke_store(fn -> open_disk_store(path, key, callback) end)
  end

  defp open_disk_store(path, key, callback) do
    case Disk.start_link(path: path) do
      {:ok, pid} -> use_disk_store(pid, key, callback)
      error -> error
    end
  end

  defp use_disk_store(pid, key, callback) do
    case TaskGuard.start(self(), pid) do
      {:ok, guard} ->
        use_guarded_disk_store(pid, guard, key, callback)

      error ->
        GenServer.stop(pid, :normal)
        error
    end
  end

  defp use_guarded_disk_store(pid, guard, key, callback) do
    Process.unlink(pid)

    try do
      callback.({Disk, pid}, key)
    after
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
      TaskGuard.stop(guard)
    end
  end

  defp invoke_store(callback) do
    callback.()
  rescue
    _ -> {:error, :session_store_unavailable}
  catch
    :exit, _ -> {:error, :session_store_unavailable}
  end
end
