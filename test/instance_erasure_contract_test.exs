defmodule SpectreInstanceErasureContractTest.Store do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore

  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Instance.Erasure.Status

  def start_link, do: Agent.start_link(fn -> %{} end)

  def seed(server, ref, checkpoint) do
    {:ok, report} = Foundation.verify_instance_checkpoint(checkpoint, ref)
    Agent.update(server, &Map.put(&1, ref.key, {:checkpoint, report.revision, checkpoint}))
  end

  def seed_alias(server, ref, checkpoint, revision) do
    Agent.update(server, &Map.put(&1, ref.key, {:checkpoint, revision, checkpoint}))
  end

  def seed_erased(server, ref, status) do
    Agent.update(server, &Map.put(&1, ref.key, {:erased, status}))
  end

  def entry(server, ref), do: Agent.get(server, &Map.get(&1, ref.key))

  @impl true
  def load(ref, opts) do
    opts
    |> Keyword.fetch!(:server)
    |> Agent.get(fn entries ->
      case Map.get(entries, ref.key) do
        {:checkpoint, _revision, checkpoint} -> {:ok, checkpoint}
        {:erased, _status} -> :not_found
        nil -> :not_found
      end
    end)
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    server = Keyword.fetch!(opts, :server)

    Agent.get_and_update(server, fn entries ->
      case Map.get(entries, ref.key) do
        nil when expected == 0 ->
          {:ok, Map.put(entries, ref.key, {:checkpoint, revision, checkpoint})}

        {:checkpoint, ^expected, current} when current == checkpoint ->
          {:ok, entries}

        {:checkpoint, ^expected, _current} ->
          {:ok, Map.put(entries, ref.key, {:checkpoint, revision, checkpoint})}

        {:erased, _status} ->
          {{:error, :instance_erased}, entries}

        _other ->
          {{:error, :checkpoint_conflict}, entries}
      end
    end)
  end

  @impl true
  def erase(ref, request, opts) do
    server = Keyword.fetch!(opts, :server)

    Agent.get_and_update(server, fn entries ->
      case Map.get(entries, ref.key) do
        {:erased, _status} ->
          {{:ok, :already_erased}, entries}

        nil when is_nil(request.expected_revision) and is_nil(request.checkpoint_digest) ->
          {:ok, status} = Status.from_request(request, request.requested_at)
          {{:ok, :erased}, Map.put(entries, ref.key, {:erased, status})}

        {:checkpoint, revision, checkpoint} ->
          erase_checkpoint(entries, ref, request, revision, checkpoint)

        _other ->
          {{:error, :checkpoint_identity_mismatch}, entries}
      end
    end)
  end

  defp erase_checkpoint(entries, ref, request, revision, checkpoint) do
    {:ok, report} = Foundation.verify_instance_checkpoint(checkpoint)

    if revision == request.expected_revision and report.digest == request.checkpoint_digest do
      {:ok, status} = Status.from_request(request, request.requested_at)
      {{:ok, :erased}, Map.put(entries, ref.key, {:erased, status})}
    else
      {{:error, :checkpoint_identity_mismatch}, entries}
    end
  end

  @impl true
  def erasure_status(ref, opts) do
    opts
    |> Keyword.fetch!(:server)
    |> Agent.get(fn entries ->
      case Map.get(entries, ref.key) do
        {:erased, status} -> {:ok, status}
        _other -> :not_erased
      end
    end)
  end
end

defmodule SpectreInstanceErasureContractTest.FaultStore do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore

  alias Spectre.Instance.Erasure.Request
  alias Spectre.Instance.Erasure.Status
  alias SpectreInstanceErasureContractTest.Store

  def reset_roles(server) do
    Agent.update(server, &Map.delete(&1, {__MODULE__, :refs}))
  end

  @impl true
  def load(ref, opts) do
    mode = Keyword.fetch!(opts, :mode)
    role = role(ref, opts)

    case {mode, role, Store.entry(server(opts), ref)} do
      {:load_error, _role, _entry} ->
        {:error, :load_offline}

      {:inconsistent, _role, _entry} ->
        {:ok, "checkpoint-still-present"}

      {:invalid_checkpoint, _role, _entry} ->
        {:ok, "invalid-checkpoint"}

      {:readback_present, _role, {:erased, _status}} ->
        {:ok, "checkpoint-still-present"}

      {:race_write_invalid_checkpoint, :race, {:checkpoint, 2, _checkpoint}} ->
        {:ok, "invalid-checkpoint"}

      _other ->
        Store.load(ref, opts)
    end
  end

  @impl true
  def compare_and_swap(ref, checkpoint, expected, revision, opts) do
    mode = Keyword.fetch!(opts, :mode)
    role = role(ref, opts)

    case {mode, role, Store.entry(server(opts), ref)} do
      {:write_error, _role, _entry} ->
        {:error, :write_rejected}

      {:accept_post_erasure, _role, {:erased, _status}} ->
        :ok

      {:ambiguous_post_erasure, _role, {:erased, _status}} ->
        {:error, {:ambiguous, :write_unknown}}

      {:race_multiple_winners, :race, {:checkpoint, _revision, _checkpoint}} ->
        :ok

      {:race_no_winner, :race, {:checkpoint, _revision, _checkpoint}} ->
        {:error, :write_lost}

      {mode, :race, {:checkpoint, _revision, _checkpoint}}
      when mode in [
             :race_erase_wins_generic,
             :race_erase_readback_error,
             :race_exact_readback_error
           ] ->
        Process.sleep(25)

        if mode == :race_exact_readback_error,
          do: {:error, :instance_erased},
          else: {:error, :write_lost}

      _other ->
        Store.compare_and_swap(ref, checkpoint, expected, revision, opts)
    end
  end

  @impl true
  def erase(ref, request, opts) do
    mode = Keyword.fetch!(opts, :mode)
    role = role(ref, opts)
    erase_mode(mode, role, ref, request, opts)
  end

  defp erase_mode(:erase_error, _role, _ref, _request, _opts),
    do: {:error, :erase_rejected}

  defp erase_mode(:erase_neighbors, :present, ref, request, opts) do
    case Store.erase(ref, request, opts) do
      {:ok, :erased} = result ->
        Agent.update(server(opts), &drop_neighbor_entries(&1, ref.key))

        result

      other ->
        other
    end
  end

  defp erase_mode({:erase_only, stable_key}, _role, %{key: key}, _request, _opts)
       when key != stable_key,
       do: {:error, :second_key_rejected}

  defp erase_mode(mode, :race, _ref, _request, _opts)
       when mode in [:race_write_wins, :race_write_invalid_checkpoint, :race_write_status_error],
       do: {:error, :erase_lost}

  defp erase_mode(:race_ambiguous_loser, :race, _ref, _request, _opts),
    do: {:error, {:ambiguous, :erase_unknown}}

  defp erase_mode(:race_no_winner, :race, _ref, _request, _opts), do: {:error, :erase_lost}

  defp erase_mode(:race_multiple_winners, :race, _ref, _request, _opts), do: {:ok, :erased}

  defp erase_mode(mode, :race, ref, request, opts)
       when mode in [:race_erase_wins_generic, :race_erase_readback_error] do
    Process.sleep(10)
    Store.erase(ref, request, opts)
  end

  defp erase_mode(:already_erased_reply, _role, ref, request, opts) do
    case Store.erase(ref, request, opts) do
      {:ok, :erased} -> {:ok, :already_erased}
      other -> other
    end
  end

  defp erase_mode(:race_slow_erase, :race, _ref, _request, _opts) do
    Process.sleep(100)
    {:error, :erase_lost}
  end

  defp erase_mode(_mode, _role, ref, request, opts), do: Store.erase(ref, request, opts)

  defp drop_neighbor_entries(entries, target_key) do
    Map.filter(entries, fn {key, _value} ->
      key == target_key or key == {__MODULE__, :refs}
    end)
  end

  @impl true
  def erasure_status(ref, opts) do
    mode = Keyword.fetch!(opts, :mode)
    role = role(ref, opts)
    erasure_status_mode(mode, role, ref, opts)
  end

  defp erasure_status_mode(:status_error, _role, _ref, _opts),
    do: {:error, :status_offline}

  defp erasure_status_mode(:inconsistent, _role, ref, _opts), do: status(ref)

  defp erasure_status_mode(:marker_missing, _role, _ref, _opts), do: :not_erased

  defp erasure_status_mode(:marker_mismatch, _role, ref, opts) do
    case Store.erasure_status(ref, opts) do
      {:ok, status} -> {:ok, %{status | erasure_id: status.erasure_id <> "-foreign"}}
      other -> other
    end
  end

  defp erasure_status_mode(mode, :race, ref, opts)
       when mode in [:race_erase_readback_error, :race_exact_readback_error] do
    case Store.entry(server(opts), ref) do
      {:erased, _status} -> :not_erased
      _other -> Store.erasure_status(ref, opts)
    end
  end

  defp erasure_status_mode(:race_write_status_error, :race, ref, opts) do
    case Store.entry(server(opts), ref) do
      {:checkpoint, 2, _checkpoint} -> {:error, :status_offline}
      _other -> Store.erasure_status(ref, opts)
    end
  end

  defp erasure_status_mode(_mode, _role, ref, opts), do: Store.erasure_status(ref, opts)

  defp role(ref, opts) do
    Agent.get_and_update(server(opts), fn entries ->
      key = {__MODULE__, :refs}
      refs = Map.get(entries, key, [])

      case Enum.find_index(refs, &(&1 == ref.key)) do
        nil ->
          updated = refs ++ [ref.key]
          {role_for(length(updated)), Map.put(entries, key, updated)}

        index ->
          {role_for(index + 1), entries}
      end
    end)
  end

  defp role_for(1), do: :present
  defp role_for(2), do: :neighbor
  defp role_for(3), do: :absent
  defp role_for(4), do: :race
  defp role_for(_index), do: :other

  defp status(ref) do
    {:ok, request} =
      Request.new(ref,
        erasure_id: "fault-store-marker",
        expected_revision: nil,
        checkpoint_digest: nil,
        owner_fencing_token: 1,
        requested_at: 1
      )

    Status.from_request(request, 1)
  end

  defp server(opts), do: Keyword.fetch!(opts, :server)
end

defmodule SpectreInstanceErasureContractTest.UnsupportedStore do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def load(_ref, _opts), do: :not_found

  @impl true
  def compare_and_swap(_ref, _checkpoint, _expected, _revision, _opts), do: :ok
end

defmodule SpectreInstanceErasureContractTest.UnsupportedMaintenanceOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  @impl true
  def claim(ref, _opts) do
    Lease.new(
      owner_id: "unsupported-maintenance",
      fencing_token: System.unique_integer([:positive, :monotonic]),
      issued_at: 0,
      metadata: %{instance_key: ref.key}
    )
  end

  @impl true
  def validate(ref, lease, _opts) do
    if lease.metadata.instance_key == ref.key,
      do: :ok,
      else: {:error, :instance_mismatch}
  end
end

defmodule SpectreInstanceErasureContractTest.SupersededMaintenanceOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  @impl true
  def claim(ref, opts), do: issue(ref, opts)

  @impl true
  def claim_maintenance(ref, :erasure, opts) do
    Process.put({__MODULE__, ref.key}, 0)
    issue(ref, opts)
  end

  @impl true
  def validate(ref, _lease, _opts) do
    key = {__MODULE__, ref.key}
    validations = Process.get(key, 0)
    Process.put(key, validations + 1)

    if validations == 0, do: :ok, else: {:error, :lease_superseded}
  end

  defp issue(ref, opts) do
    token = Keyword.get(opts, :minimum_fencing_token, 0) + 1

    Lease.new(
      owner_id: "superseded-maintenance",
      fencing_token: token,
      issued_at: token,
      metadata: %{instance_key: ref.key}
    )
  end
end

defmodule SpectreInstanceErasureContractTest.MaintenanceOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  def start_link, do: Agent.start_link(fn -> %{next: 0, current: %{}} end)

  @impl true
  def claim(ref, opts) do
    server = Keyword.fetch!(opts, :server)
    issue(server, ref, Keyword.get(opts, :minimum_fencing_token, 0), true)
  end

  @impl true
  def claim_maintenance(ref, :erasure, opts) do
    server = Keyword.fetch!(opts, :server)
    issue(server, ref, Keyword.get(opts, :minimum_fencing_token, 0), false)
  end

  @impl true
  def validate(ref, lease, opts) do
    opts
    |> Keyword.fetch!(:server)
    |> Agent.get(fn state ->
      if Map.get(state.current, ref.key) == lease.fencing_token,
        do: :ok,
        else: {:error, :lease_superseded}
    end)
  end

  @impl true
  def release(ref, lease, opts) do
    opts
    |> Keyword.fetch!(:server)
    |> Agent.update(fn state ->
      if Map.get(state.current, ref.key) == lease.fencing_token,
        do: %{state | current: Map.delete(state.current, ref.key)},
        else: state
    end)

    :ok
  end

  defp issue(server, ref, minimum, supersede?) do
    Agent.get_and_update(server, fn state ->
      case Map.get(state.current, ref.key) do
        nil -> issue_lease(state, ref, minimum)
        _token when supersede? -> issue_lease(state, ref, minimum)
        _token -> {{:error, :instance_already_owned}, state}
      end
    end)
  end

  defp issue_lease(state, ref, minimum) do
    token = max(state.next + 1, minimum + 1)

    lease =
      Lease.new!(
        owner_id: "maintenance-owner-#{token}",
        fencing_token: token,
        issued_at: token,
        metadata: %{instance_key: ref.key}
      )

    next = %{state | next: token, current: Map.put(state.current, ref.key, token)}
    {{:ok, lease}, next}
  end
end

defmodule SpectreInstanceErasureContractTest.MutatingMaintenanceOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease
  alias SpectreInstanceErasureContractTest.Store

  @impl true
  def claim(ref, opts), do: issue(ref, opts)

  @impl true
  def claim_maintenance(ref, :erasure, opts) do
    Store.seed(Keyword.fetch!(opts, :server), ref, Keyword.fetch!(opts, :replacement))
    issue(ref, opts)
  end

  @impl true
  def validate(ref, lease, _opts) do
    if lease.metadata.instance_key == ref.key,
      do: :ok,
      else: {:error, :instance_mismatch}
  end

  @impl true
  def release(_ref, _lease, _opts), do: :ok

  defp issue(ref, opts) do
    token = Keyword.get(opts, :minimum_fencing_token, 0) + 1

    Lease.new(
      owner_id: "mutating-maintenance",
      fencing_token: token,
      issued_at: token,
      metadata: %{instance_key: ref.key}
    )
  end
end

defmodule SpectreInstanceErasureContractTest.AgentDefinition do
  @moduledoc false

  use Spectre.Agent, id: :instance_erasure_contract_agent
end

defmodule SpectreInstanceErasureContractTest do
  use ExUnit.Case, async: false

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.CheckpointStore.ErasureConformance
  alias Spectre.Instance.Erasure.Proof
  alias Spectre.Instance.Erasure.Request
  alias Spectre.Instance.Erasure.Status
  alias Spectre.Instance.Ref
  alias Spectre.Instance.Registry, as: InstanceRegistry

  alias SpectreInstanceErasureContractTest.AgentDefinition
  alias SpectreInstanceErasureContractTest.FaultStore
  alias SpectreInstanceErasureContractTest.MaintenanceOwner
  alias SpectreInstanceErasureContractTest.MutatingMaintenanceOwner
  alias SpectreInstanceErasureContractTest.Store
  alias SpectreInstanceErasureContractTest.SupersededMaintenanceOwner
  alias SpectreInstanceErasureContractTest.UnsupportedMaintenanceOwner
  alias SpectreInstanceErasureContractTest.UnsupportedStore

  setup do
    server = start_supervised!({Agent, fn -> %{} end})

    %{store: {Store, server: server}, server: server}
  end

  test "offline erasure marks stable and legacy keys and is idempotent", context do
    subject = "erasure-present-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)
    {:ok, legacy_ref} = Ref.legacy(ref)
    checkpoint = checkpoint(ref)
    Store.seed(context.server, ref, checkpoint)

    assert {:ok,
            %Proof{
              scope: :configured_instance_data,
              outcome: :erased,
              instance_key: instance_key,
              keys: keys
            }} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               confirm: ref.key,
               now: 1_000
             )

    assert instance_key == ref.key

    assert [
             %{kind: :stable, prior_state: :present, outcome: :erased},
             %{kind: :legacy, prior_state: :absent, outcome: :erased}
           ] = Enum.map(keys, &Map.drop(&1, [:marker_digest]))

    assert :not_found = CheckpointStore.load(context.store, ref, [])
    assert :not_found = CheckpointStore.load(context.store, legacy_ref, [])

    assert {:ok, %Status{instance_key: stable_key}} =
             CheckpointStore.erasure_status(context.store, ref, [])

    assert {:ok, %Status{instance_key: legacy_key}} =
             CheckpointStore.erasure_status(context.store, legacy_ref, [])

    assert stable_key == ref.key
    assert legacy_key == legacy_ref.key

    assert {:error, :instance_erased} =
             CheckpointStore.persist(context.store, ref, checkpoint, 0, 1, [])

    assert {:ok, %Proof{outcome: :already_erased, keys: retry_keys}} =
             Spectre.erase_instance(ref, ref.subject,
               checkpoint_store: context.store,
               confirm: ref.key,
               now: 2_000
             )

    assert Enum.all?(retry_keys, &(&1.outcome == :already_erased))
  end

  test "an erasure marker prevents the Instance from being summoned again", context do
    subject = "erasure-boot-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)

    assert {:ok, %Proof{outcome: :erased}} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               confirm: ref.key,
               now: 10
             )

    previous_trap = Process.flag(:trap_exit, true)

    try do
      assert {:error, :instance_erased} =
               Spectre.summon(
                 agent: AgentDefinition,
                 subject: subject,
                 checkpoint_store: context.store
               )
    after
      Process.flag(:trap_exit, previous_trap)
    end
  end

  test "stable and legacy aliases sharing one checkpoint are verified once", context do
    subject = "erasure-alias-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)
    {:ok, legacy_ref} = Ref.legacy(ref)
    checkpoint = checkpoint(ref)
    Store.seed(context.server, ref, checkpoint)
    Store.seed_alias(context.server, legacy_ref, checkpoint, 0)

    assert {:ok, %Proof{outcome: :erased, keys: keys}} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               confirm: ref.key,
               now: 10
             )

    assert Enum.map(keys, &{&1.kind, &1.prior_state}) == [stable: :present, legacy: :present]
  end

  test "portable AgentRefs without source hints erase only their stable key", context do
    agent_ref = Spectre.AgentRef.from_id("portable-erasure-agent")
    subject = "portable-erasure-subject"
    ref = Ref.new(agent_ref, subject)

    assert {:ok, %Proof{outcome: :erased, keys: [%{kind: :stable}]}} =
             Spectre.erase_instance(agent_ref, subject,
               checkpoint_store: context.store,
               owner: Spectre.Instance.Owner.Local,
               confirm: ref.key,
               now: 10
             )
  end

  test "exact confirmation is required before store or ownership callbacks", context do
    subject = "erasure-confirm-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)
    checkpoint = checkpoint(ref)
    Store.seed(context.server, ref, checkpoint)

    assert {:error, :instance_erasure_confirmation_required} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               confirm: true
             )

    assert {:checkpoint, 0, ^checkpoint} = Store.entry(context.server, ref)
  end

  test "a live local Instance is never terminated by erasure", context do
    subject = "erasure-live-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)

    assert {:ok, instance} =
             Spectre.summon(
               agent: AgentDefinition,
               subject: subject,
               checkpoint_store: context.store
             )

    assert {:error, :instance_active} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               confirm: ref.key
             )

    assert Process.alive?(instance)
    GenServer.stop(instance)
  end

  test "erasure fails closed when store or Owner lacks the required capability", context do
    subject = "erasure-capability-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)

    assert {:error, {:checkpoint_store_erasure_unsupported, UnsupportedStore, :erase, 3}} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: UnsupportedStore,
               confirm: ref.key
             )

    assert {:error, {:instance_owner_maintenance_unsupported, UnsupportedMaintenanceOwner}} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               owner: UnsupportedMaintenanceOwner,
               confirm: ref.key
             )
  end

  test "maintenance ownership refuses rather than supersedes a live remote lease", context do
    {:ok, owner_server} = MaintenanceOwner.start_link()

    on_exit(fn ->
      if Process.alive?(owner_server), do: Agent.stop(owner_server)
    end)

    subject = "erasure-owner-live-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)
    owner = {MaintenanceOwner, server: owner_server}

    assert {:ok, _normalized, lease} = Spectre.Instance.Owner.claim(owner, ref)

    assert {:error, :instance_already_owned} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               owner: owner,
               confirm: ref.key
             )

    assert :ok = Spectre.Instance.Owner.validate(owner, ref, lease)
    assert :ok = Spectre.Instance.Owner.release(owner, ref, lease)

    assert {:ok, %Proof{outcome: :erased}} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               owner: owner,
               confirm: ref.key
             )
  end

  test "erasure revalidates maintenance ownership immediately before mutation", context do
    subject = "erasure-owner-superseded-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)

    assert {:error, {:owner_fence_lost, :instance_erasure, :lease_superseded}} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               owner: SupersededMaintenanceOwner,
               confirm: ref.key
             )

    assert :not_erased = CheckpointStore.erasure_status(context.store, ref, [])
  end

  test "erasure rejects a checkpoint changed while acquiring maintenance ownership", context do
    subject = "erasure-toctou-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)
    initial = checkpoint(ref, :initial)
    replacement = checkpoint(ref, :replacement)
    Store.seed(context.server, ref, initial)

    assert {:error, :instance_erasure_checkpoint_changed} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               owner:
                 {MutatingMaintenanceOwner, server: context.server, replacement: replacement},
               confirm: ref.key
             )

    assert {:checkpoint, 0, ^replacement} = Store.entry(context.server, ref)
    assert :not_erased = CheckpointStore.erasure_status(context.store, ref, [])
  end

  test "an existing marker raises the maintenance fencing floor and keeps a mixed proof erased",
       context do
    {:ok, owner_server} = MaintenanceOwner.start_link()
    subject = "erasure-floor-#{System.unique_integer([:positive])}"
    ref = Ref.new(AgentDefinition, subject)

    {:ok, request} =
      Request.new(ref,
        erasure_id: "prior-erasure",
        expected_revision: nil,
        checkpoint_digest: nil,
        owner_fencing_token: 73,
        requested_at: 1
      )

    {:ok, status} = Status.from_request(request, 1)
    Store.seed_erased(context.server, ref, status)

    assert {:ok,
            %Proof{
              outcome: :erased,
              owner_fencing_token: token,
              keys: [
                %{kind: :stable, outcome: :already_erased},
                %{kind: :legacy, outcome: :erased}
              ]
            }} =
             Spectre.erase_instance(AgentDefinition, subject,
               checkpoint_store: context.store,
               owner: {MaintenanceOwner, server: owner_server},
               confirm: ref.key,
               now: 2
             )

    assert token > 73
    Agent.stop(owner_server)
  end

  test "a supplied Ref remains bound to the exact supplied Subject", context do
    ref = Ref.new(AgentDefinition, "erasure-subject-a")

    assert {:error, :instance_erasure_subject_mismatch} =
             Spectre.erase_instance(ref, "erasure-subject-b",
               checkpoint_store: context.store,
               confirm: ref.key
             )
  end

  test "the adapter-neutral erasure conformance gate exercises races and markers", context do
    ref =
      Ref.new(
        AgentDefinition,
        "erasure-conformance-#{System.unique_integer([:positive])}"
      )

    assert {:ok,
            %{
              contract_version: 1,
              present_erasure: :verified,
              absent_erasure: :verified,
              idempotency: :verified,
              neighbor_isolation: :verified,
              post_erasure_write: :rejected,
              race: race,
              marker_digest: marker_digest
            }} = ErasureConformance.run(context.store, ref)

    assert race in [:erase_won, :write_won]
    assert byte_size(marker_digest) == 64
  end

  test "erasure rejects invalid input and inconsistent adapter observations", context do
    assert {:error, :invalid_instance_erasure_options} =
             Spectre.Instance.Erasure.run(AgentDefinition, "invalid-options", :invalid)

    assert {:error, :invalid_instance_erasure_options} =
             Spectre.Instance.Erasure.run(AgentDefinition, "invalid-keyword", [:invalid])

    assert {:error, :invalid_instance_erasure_identity} =
             Spectre.Instance.Erasure.run(nil, "invalid-identity", [])

    assert {:error, :invalid_instance_erasure_identity} =
             Spectre.Instance.Erasure.run(AgentDefinition, %Spectre.Subject{id: ""}, [])

    ref = Ref.new(AgentDefinition, "invalid-configuration")

    assert {:error, {:invalid_instance_erasure_option, :opts}} =
             Spectre.erase_instance(AgentDefinition, ref.subject,
               opts: :invalid,
               confirm: ref.key
             )

    for {mode, expected} <- [
          {:inconsistent, :instance_erasure_store_inconsistent},
          {:status_error, :instance_erasure_status_failed},
          {:load_error, :instance_erasure_load_failed},
          {:invalid_checkpoint, :instance_erasure_checkpoint_invalid}
        ] do
      ref = Ref.new(AgentDefinition, "erasure-observation-#{mode}")

      assert {:error, reason} =
               Spectre.erase_instance(AgentDefinition, ref.subject,
                 checkpoint_store: {FaultStore, server: context.server, mode: mode},
                 confirm: ref.key
               )

      assert reason |> Tuple.to_list() |> hd() == expected
    end
  end

  test "erasure verifies mutation read-back and reports partial completion", context do
    cases = [
      {:erase_error, :instance_checkpoint_erase_failed},
      {:readback_present, :instance_checkpoint_erase_failed},
      {:marker_missing, :instance_checkpoint_erase_failed},
      {:marker_mismatch, :instance_checkpoint_erase_failed}
    ]

    Enum.each(cases, fn {mode, expected} ->
      ref = Ref.new(AgentDefinition, "erasure-mutation-#{mode}")

      assert {:error, reason} =
               Spectre.erase_instance(AgentDefinition, ref.subject,
                 checkpoint_store: {FaultStore, server: context.server, mode: mode},
                 confirm: ref.key,
                 erasure_id: "erasure-mutation-#{mode}",
                 now: 10
               )

      assert elem(reason, 0) == expected
    end)

    ref = Ref.new(AgentDefinition, "erasure-partial")

    assert {:error,
            {:ambiguous,
             {:instance_erasure_partial, [:stable],
              {:instance_checkpoint_erase_failed, :legacy, :second_key_rejected}}}} =
             Spectre.erase_instance(AgentDefinition, ref.subject,
               checkpoint_store:
                 {FaultStore, server: context.server, mode: {:erase_only, ref.key}},
               confirm: ref.key,
               erasure_id: "erasure-partial",
               now: 10
             )

    already_ref = Ref.new(AgentDefinition, "erasure-already-reply")

    assert {:ok, %Proof{outcome: :already_erased}} =
             Spectre.erase_instance(AgentDefinition, already_ref.subject,
               checkpoint_store:
                 {FaultStore, server: context.server, mode: :already_erased_reply},
               confirm: already_ref.key,
               erasure_id: "erasure-already-reply",
               now: 10
             )
  end

  test "erasure conformance diagnoses mutation and race contract violations", context do
    phase_failures = [
      {:write_error, :present_create, :write_rejected},
      {:erase_error, :present_erase, :erase_rejected},
      {:readback_present, :present_readback, :checkpoint_still_present},
      {:marker_missing, :present_readback, :marker_missing},
      {:marker_mismatch, :present_readback, :marker_mismatch},
      {:accept_post_erasure, :post_erasure_write, :write_accepted},
      {:ambiguous_post_erasure, :post_erasure_write, :ambiguous_rejection},
      {:erase_neighbors, :neighbor_isolation, :neighbor_erased}
    ]

    Enum.each(phase_failures, fn {mode, phase, code} ->
      FaultStore.reset_roles(context.server)
      ref = Ref.new(AgentDefinition, "erasure-conformance-failure-#{mode}")
      store = {FaultStore, server: context.server, mode: mode}

      assert {:error, {:checkpoint_store_erasure_conformance_failed, ^phase, ^code}} =
               ErasureConformance.run(store, ref)
    end)

    race_cases = [
      {:race_write_wins, {:ok, :write_won}},
      {:race_write_invalid_checkpoint, {:error, :write_readback_mismatch}},
      {:race_write_status_error, {:error, :write_readback_mismatch}},
      {:race_erase_wins_generic, {:ok, :erase_won}},
      {:race_ambiguous_loser, {:error, :ambiguous_erase_loser}},
      {:race_multiple_winners, {:error, :multiple_winners}},
      {:race_no_winner, {:error, :no_winner}},
      {:race_erase_readback_error, {:error, :marker_missing}},
      {:race_exact_readback_error, {:error, :marker_missing}},
      {:race_slow_erase, {:error, :invalid_outcomes}}
    ]

    Enum.each(race_cases, fn {mode, expected} ->
      FaultStore.reset_roles(context.server)
      ref = Ref.new(AgentDefinition, "erasure-conformance-race-#{mode}")
      store = {FaultStore, server: context.server, mode: mode}
      opts = if mode == :race_slow_erase, do: [timeout: 10], else: []

      case expected do
        {:ok, race} ->
          assert {:ok, %{race: ^race}} = ErasureConformance.run(store, ref, opts)

        {:error, code} ->
          phase =
            if mode in [:race_erase_readback_error, :race_exact_readback_error],
              do: :race_erase_readback,
              else: :race

          assert {:error, {:checkpoint_store_erasure_conformance_failed, ^phase, ^code}} =
                   ErasureConformance.run(store, ref, opts)
      end
    end)

    FaultStore.reset_roles(context.server)
    occupied_ref = Ref.new(AgentDefinition, "erasure-conformance-occupied")
    Store.seed(context.server, occupied_ref, checkpoint(occupied_ref))

    assert {:error,
            {:checkpoint_store_erasure_conformance_failed, :present_initial, :reference_not_empty}} =
             ErasureConformance.run(
               {FaultStore, server: context.server, mode: :healthy},
               occupied_ref
             )
  end

  test "maintenance reservations expose active, maintenance, lost, and unavailable states" do
    ref = Ref.new(AgentDefinition, "erasure-registry-reservation")
    registry = Spectre.Instance.Registry

    assert {:ok, token} = InstanceRegistry.reserve(ref, :erasure, registry)
    assert {:error, :instance_in_maintenance} = InstanceRegistry.lookup_ref(ref, registry)

    assert {:error, :instance_in_maintenance} =
             InstanceRegistry.lookup(AgentDefinition, ref.subject, registry)

    assert {:error, :instance_in_maintenance} =
             InstanceRegistry.ensure_started(:unused, AgentDefinition, ref.subject,
               registry: registry
             )

    assert {:error, :instance_in_maintenance} = InstanceRegistry.reserve(ref, :erasure, registry)

    assert {:error, :instance_maintenance_reservation_lost} =
             InstanceRegistry.release_reservation(ref, make_ref(), registry)

    assert :ok = InstanceRegistry.release_reservation(ref, token, registry)

    assert {:error, :instance_maintenance_reservation_lost} =
             InstanceRegistry.release_reservation(ref, token, registry)

    assert {:error, :instance_registry_unavailable} =
             InstanceRegistry.reserve(ref, :erasure, :missing_instance_registry)

    assert {:error, :instance_registry_unavailable} =
             InstanceRegistry.release_reservation(ref, make_ref(), :missing_instance_registry)

    assert {:ok, _owner} = Registry.register(registry, ref.key, :active_instance)
    assert {:error, :instance_active} = InstanceRegistry.reserve(ref, :erasure, registry)
    assert :ok = Registry.unregister(registry, ref.key)
  end

  defp checkpoint(ref, marker \\ nil) do
    {:ok, canonical} =
      Canonical.new(%{
        flow: %Spectre.State{conversation_id: ref.key},
        work: %{},
        vigil: %{},
        directive: %{},
        control: %{},
        correlations: %{instance_key: ref.key, erasure_fixture: marker},
        events: %{records: [], ids: %{}}
      })

    {:ok, encoded} = Codec.encode_json(canonical)
    encoded
  end
end
