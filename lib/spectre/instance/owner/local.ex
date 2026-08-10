defmodule Spectre.Instance.Owner.Local do
  @moduledoc """
  Single-owner lease adapter paired with `Spectre.Instance.Registry`.

  This adapter makes no multi-node claim. Its monotonic token is scoped to the
  current VM and is safe only while the local Registry remains the canonical
  owner. Distributed deployments must configure their own
  `Spectre.Instance.Owner` adapter.
  """

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref

  @impl true
  def claim(%Ref{} = ref, opts) do
    now = System.system_time(:millisecond)

    Lease.new(
      owner_id: Keyword.get(opts, :owner_id, "local:" <> ref.key),
      fencing_token:
        Keyword.get(opts, :fencing_token, System.unique_integer([:positive, :monotonic])),
      issued_at: now,
      expires_at: Keyword.get(opts, :expires_at),
      metadata: %{instance_key: ref.key, scope: :single_owner_local}
    )
  end

  @impl true
  def validate(%Ref{} = ref, %Lease{} = lease, opts) do
    now = Keyword.get(opts, :now, System.system_time(:millisecond))

    cond do
      Map.get(lease.metadata, :instance_key) != ref.key ->
        {:error, :owner_lease_instance_mismatch}

      not Lease.current?(lease, now) ->
        {:error, :owner_lease_expired}

      true ->
        :ok
    end
  end

  @impl true
  def release(_ref, _lease, _opts), do: :ok
end
