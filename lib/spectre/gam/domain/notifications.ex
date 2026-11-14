defmodule Spectre.GAM.Domain.Notifications do
  @moduledoc """
  Ephemeral post-commit invalidations. This process group holds no history or authority.

  Subscribers must read through an authenticated Scope; messages contain only a
  revision hint. Subscriber loss never changes admission or durable commit.
  """
  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{id: __MODULE__, start: {:pg, :start_link, [__MODULE__]}}
  end

  @doc false
  @spec subscribe(binary()) :: {:ok, pid()} | {:error, atom()}
  def subscribe(domain) do
    with notifier when is_pid(notifier) <- Process.whereis(__MODULE__) do
      unless self() in :pg.get_local_members(__MODULE__, domain),
        do: :ok = :pg.join(__MODULE__, domain, self())

      if Process.whereis(__MODULE__) == notifier,
        do: {:ok, notifier},
        else: {:error, :notifications_unavailable}
    else
      _ -> {:error, :notifications_unavailable}
    end
  rescue
    _ -> {:error, :notifications_unavailable}
  catch
    _, _ -> {:error, :notifications_unavailable}
  end

  @doc false
  @spec committed(binary(), non_neg_integer()) :: :ok
  def committed(domain, revision) do
    for pid <- :pg.get_local_members(__MODULE__, domain),
        do: send(pid, {:diagnostics_revision, revision})

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
