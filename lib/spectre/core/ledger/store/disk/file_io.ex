defmodule Spectre.Ledger.Store.Disk.FileIO do
  @moduledoc false

  # Physical operations only: no Store state, ETS ownership, append admission
  # or governed semantics. In particular, a failed sync/close cannot prove that
  # a write was absent. Tail truncation remains an explicit policy of Disk.
  @doc "Appends and syncs a complete frame, including a new directory entry; uncertain writes stay ambiguous."
  @spec append(String.t(), String.t(), binary()) :: :ok | {:error, term()}
  def append(directory, domain_ref, frame) do
    path = path(directory, domain_ref)

    with {:ok, directory_sync_required?} <- directory_sync_required?(path) do
      case :file.open(String.to_charlist(path), [:raw, :binary, :append]) do
        {:ok, io} ->
          result = write_and_sync(io, frame)
          close_result = :file.close(io)

          confirm_frame_sync(result, close_result, directory_sync_required?, directory)

        {:error, reason} ->
          {:error, {:ledger_disk_open_failed, reason}}
      end
    end
  end

  defp confirm_frame_sync(:ok, :ok, false, _directory), do: :ok

  defp confirm_frame_sync(:ok, :ok, true, directory) do
    case sync_directory(directory) do
      :ok -> :ok
      {:error, _reason} -> {:error, :ambiguous}
    end
  end

  defp confirm_frame_sync(_write, _close, _required, _directory), do: {:error, :ambiguous}

  @spec write_and_sync(:file.io_device(), binary()) :: :ok | {:error, term()}
  defp write_and_sync(io, frame) do
    with :ok <- :file.write(io, frame) do
      :file.sync(io)
    end
  end

  @doc "Reads exactly the bounded body length, distinguishing an incomplete tail from an I/O error."
  @spec read_body(:file.io_device(), pos_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:incomplete, term()} | {:error, term()}
  def read_body(io, length, offset) do
    case :file.read(io, length) do
      {:ok, encoded} when byte_size(encoded) == length -> {:ok, encoded}
      {:ok, _partial} -> {:incomplete, {:ledger_frame_body, offset}}
      :eof -> {:incomplete, {:ledger_frame_body, offset}}
      {:error, reason} -> {:error, {:ledger_disk_read_failed, offset, reason}}
    end
  end

  @doc "Reads an indexed frame without changing a shared file position."
  @spec pread(String.t(), String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | {:error, term()}
  def pread(directory, domain_ref, offset, size) do
    path = path(directory, domain_ref)

    case :file.open(String.to_charlist(path), [:raw, :binary, :read]) do
      {:ok, io} ->
        try do
          case :file.pread(io, offset, size) do
            {:ok, frame} when byte_size(frame) === size -> {:ok, frame}
            other -> {:error, {:ledger_disk_frame_read_failed, offset, other}}
          end
        after
          :file.close(io)
        end

      {:error, reason} ->
        {:error, {:ledger_disk_open_failed, reason}}
    end
  end

  @doc "Maps the opaque Domain reference to its stable filename without exposing it as a path."
  @spec path(String.t(), String.t()) :: String.t()
  def path(directory, domain_ref) do
    filename =
      domain_ref
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> Kernel.<>(".ledger")

    Path.join(directory, filename)
  end

  @doc "Creates and verifies the directory, syncing its ancestry before the Store acquires ownership."
  @spec ensure_directory(String.t()) :: :ok | {:error, term()}
  def ensure_directory(directory) do
    with :ok <- File.mkdir_p(directory),
         {:ok, %File.Stat{type: :directory}} <- File.stat(directory),
         :ok <- sync_directory_chain(directory) do
      :ok
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_ledger_disk_path_type, type}}
      {:error, reason} -> {:error, {:ledger_disk_directory_failed, reason}}
    end
  end

  @spec directory_sync_required?(String.t()) :: {:ok, boolean()} | {:error, term()}
  defp directory_sync_required?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size == 0}
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_ledger_disk_file_type, type}}
      {:error, :enoent} -> {:ok, true}
      {:error, reason} -> {:error, {:ledger_disk_stat_failed, reason}}
    end
  end

  @doc "Repeats file and directory durability barriers before recovered entries become a trusted prefix."
  @spec durability_barrier(String.t(), String.t()) :: :ok | {:error, term()}
  def durability_barrier(path, directory) do
    with :ok <- sync_file(path) do
      sync_directory(directory)
    end
  end

  @spec sync_file(String.t()) :: :ok | {:error, term()}
  defp sync_file(path) do
    case :file.open(String.to_charlist(path), [:raw, :binary, :read, :write]) do
      {:ok, io} ->
        sync_result = :file.sync(io)
        close_result = :file.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:ledger_disk_sync_failed, reason}}
          {_sync, {:error, reason}} -> {:error, {:ledger_disk_close_failed, reason}}
          _invalid -> {:error, :invalid_ledger_disk_sync_reply}
        end

      {:error, reason} ->
        {:error, {:ledger_disk_open_failed, reason}}
    end
  end

  @spec sync_directory_chain(String.t()) :: :ok | {:error, term()}
  defp sync_directory_chain(directory) do
    directory
    |> directory_chain()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case sync_directory(path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec directory_chain(String.t()) :: [String.t()]
  defp directory_chain(directory) do
    Stream.unfold(directory, fn
      nil ->
        nil

      current ->
        parent = Path.dirname(current)

        if parent == current,
          do: {current, nil},
          else: {current, parent}
    end)
    |> Enum.to_list()
  end

  @spec sync_directory(String.t()) :: :ok | {:error, term()}
  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :directory]) do
      {:ok, io} ->
        sync_result = :file.sync(io)
        close_result = :file.close(io)

        case {sync_result, close_result} do
          {:ok, :ok} -> :ok
          {{:error, reason}, _close} -> {:error, {:ledger_disk_directory_sync_failed, reason}}
          {_sync, {:error, reason}} -> {:error, {:ledger_disk_directory_close_failed, reason}}
          _invalid -> {:error, :invalid_ledger_disk_directory_sync_reply}
        end

      {:error, reason} ->
        {:error, {:ledger_disk_directory_open_failed, reason}}
    end
  end
end
