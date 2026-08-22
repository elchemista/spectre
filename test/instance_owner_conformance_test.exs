defmodule SpectreInstanceOwnerConformanceTest.DistributedOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  def start_link do
    Agent.start_link(fn -> %{next: 0, current: %{}} end)
  end

  @impl true
  def claim(ref, opts) do
    server = Keyword.fetch!(opts, :server)
    minimum = Keyword.get(opts, :minimum_fencing_token, 0)

    Agent.get_and_update(server, fn state ->
      token = max(state.next + 1, minimum + 1)

      lease =
        Lease.new!(
          owner_id: "distributed-owner-#{token}",
          fencing_token: token,
          issued_at: token,
          metadata: %{instance_key: ref.key}
        )

      {{:ok, lease}, %{state | next: token, current: Map.put(state.current, ref.key, token)}}
    end)
  end

  @impl true
  def validate(ref, lease, opts) do
    server = Keyword.fetch!(opts, :server)

    Agent.get(server, fn state ->
      cond do
        Map.get(lease.metadata, :instance_key) != ref.key ->
          {:error, :instance_mismatch}

        Map.get(state.current, ref.key) != lease.fencing_token ->
          {:error, :lease_superseded}

        true ->
          :ok
      end
    end)
  end

  @impl true
  def release(ref, lease, opts) do
    server = Keyword.fetch!(opts, :server)

    Agent.update(server, fn state ->
      if Map.get(state.current, ref.key) == lease.fencing_token,
        do: %{state | current: Map.delete(state.current, ref.key)},
        else: state
    end)

    :ok
  end
end

defmodule SpectreInstanceOwnerConformanceTest.NonSupersedingOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  @impl true
  def claim(ref, opts) do
    minimum = Keyword.get(opts, :minimum_fencing_token, 0)
    token = max(System.unique_integer([:positive, :monotonic]), minimum + 1)

    Lease.new(
      owner_id: "non-superseding-#{token}",
      fencing_token: token,
      issued_at: token,
      metadata: %{instance_key: ref.key}
    )
  end

  @impl true
  def validate(ref, lease, _opts) do
    if Map.get(lease.metadata, :instance_key) == ref.key,
      do: :ok,
      else: {:error, :instance_mismatch}
  end
end

defmodule SpectreInstanceOwnerConformanceTest.RejectedOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  @impl true
  def claim(_ref, _opts), do: {:error, :claim_rejected}

  @impl true
  def validate(_ref, _lease, _opts), do: {:error, :not_owned}
end

defmodule SpectreInstanceOwnerConformanceTest.SecondValidationRejectOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  @impl true
  def claim(ref, opts) do
    token = Keyword.get(opts, :minimum_fencing_token, 0) + 1
    Process.put({__MODULE__, ref.key}, 0)

    Lease.new(
      owner_id: "second-validation-reject",
      fencing_token: token,
      issued_at: token,
      metadata: %{instance_key: ref.key}
    )
  end

  @impl true
  def validate(ref, _lease, _opts) do
    key = {__MODULE__, ref.key}
    calls = Process.get(key, 0)
    Process.put(key, calls + 1)

    if calls == 0, do: :ok, else: {:error, :lease_rejected}
  end
end

defmodule SpectreInstanceOwnerConformanceTest.ConcurrencyFaultOwner do
  @moduledoc false

  @behaviour Spectre.Instance.Owner

  alias Spectre.Instance.Owner.Lease

  def start_link(mode), do: Agent.start_link(fn -> %{mode: mode, next: 0, current: %{}} end)

  @impl true
  def claim(ref, opts) do
    server = Keyword.fetch!(opts, :server)
    minimum = Keyword.get(opts, :minimum_fencing_token, 0)
    mode = Agent.get(server, & &1.mode)

    case {mode, minimum} do
      {:no_successful_claim, value} when value >= 2 ->
        {:error, :contender_rejected}

      {:contender_timeout, value} when value >= 2 ->
        Process.sleep(100)
        {:error, :contender_timeout}

      {:duplicate_tokens, value} when value >= 2 ->
        issue(server, ref, minimum + 1, false)

      _other ->
        issue(server, ref, minimum + 1, true)
    end
  end

  @impl true
  def validate(ref, lease, opts) do
    state = Agent.get(Keyword.fetch!(opts, :server), & &1)

    cond do
      lease.metadata.instance_key != ref.key ->
        {:error, :instance_mismatch}

      state.mode == :multiple_current and lease.fencing_token >= 3 ->
        :ok

      Map.get(state.current, ref.key) == lease.fencing_token ->
        :ok

      true ->
        {:error, :lease_superseded}
    end
  end

  @impl true
  def release(ref, lease, opts) do
    Agent.update(Keyword.fetch!(opts, :server), fn state ->
      if Map.get(state.current, ref.key) == lease.fencing_token,
        do: %{state | current: Map.delete(state.current, ref.key)},
        else: state
    end)

    :ok
  end

  defp issue(server, ref, requested, increment?) do
    Agent.get_and_update(server, fn state ->
      token = if increment?, do: max(state.next + 1, requested), else: requested

      lease =
        Lease.new!(
          owner_id: "concurrency-fault-#{token}",
          fencing_token: token,
          issued_at: token,
          metadata: %{instance_key: ref.key}
        )

      next = %{
        state
        | next: max(state.next, token),
          current: Map.put(state.current, ref.key, token)
      }

      {{:ok, lease}, next}
    end)
  end
end

defmodule SpectreInstanceOwnerConformanceTest.AgentDefinition do
  @moduledoc false

  use Spectre.Agent, id: :instance_owner_conformance_agent
end

defmodule SpectreInstanceOwnerConformanceTest do
  use ExUnit.Case, async: true

  alias Spectre.Instance.Owner.Conformance
  alias Spectre.Instance.Owner.Local
  alias Spectre.Instance.Ref

  alias SpectreInstanceOwnerConformanceTest.AgentDefinition
  alias SpectreInstanceOwnerConformanceTest.ConcurrencyFaultOwner
  alias SpectreInstanceOwnerConformanceTest.DistributedOwner
  alias SpectreInstanceOwnerConformanceTest.NonSupersedingOwner
  alias SpectreInstanceOwnerConformanceTest.RejectedOwner
  alias SpectreInstanceOwnerConformanceTest.SecondValidationRejectOwner

  test "local profile verifies the Registry-scoped lease boundary" do
    ref = Ref.new(AgentDefinition, "owner-conformance-local")

    assert {:ok,
            %{
              contract_version: 1,
              profile: :local,
              lease: :portable,
              ref_binding: :verified,
              fencing_floor: :verified,
              validation: :verified,
              release: :callback_acknowledged,
              supersession: :registry_scoped,
              concurrent_claims: :not_applicable
            }} = Conformance.run(Local, ref, minimum_fencing_token: 50)
  end

  test "distributed profile proves supersession, isolation and one race winner" do
    {:ok, server} = DistributedOwner.start_link()
    ref = Ref.new(AgentDefinition, "owner-conformance-distributed")

    assert {:ok,
            %{
              profile: :distributed,
              supersession: :verified,
              concurrent_claims: :single_current
            }} =
             Conformance.run({DistributedOwner, server: server}, ref,
               profile: :distributed,
               concurrent_claims: 8
             )

    Agent.stop(server)
  end

  test "distributed profile rejects an adapter that keeps superseded leases current" do
    ref = Ref.new(AgentDefinition, "owner-conformance-broken")

    assert {:error, {:instance_owner_conformance_failed, :supersession, :lease_accepted}} =
             Conformance.run(NonSupersedingOwner, ref, profile: :distributed)
  end

  test "options and alternate Ref are validated without invoking the adapter" do
    ref = Ref.new(AgentDefinition, "owner-conformance-options")

    assert {:error, {:instance_owner_conformance_failed, :options, :invalid_profile}} =
             Conformance.run(Local, ref, profile: :cluster)

    assert {:error, {:instance_owner_conformance_failed, :options, :alternate_ref_not_distinct}} =
             Conformance.run(Local, ref, alternate_ref: ref)

    assert {:error, {:instance_owner_conformance_failed, :options, :unknown_options}} =
             Conformance.run(Local, ref, unknown: true)

    assert {:error, {:instance_owner_conformance_failed, :options, :invalid_alternate_ref}} =
             Conformance.run(Local, ref, alternate_ref: "invalid")

    assert {:error, {:instance_owner_conformance_failed, :options, :invalid_keyword}} =
             Conformance.run(Local, ref, [:invalid])
  end

  test "configuration, claim, and post-claim validation failures stay typed" do
    ref = Ref.new(AgentDefinition, "owner-conformance-failures")

    assert {:ok, %{profile: :local}} = Conformance.run(Local, ref)

    assert {:error, {:instance_owner_conformance_failed, :configuration, :invalid_owner}} =
             Conformance.run({Local, [:invalid]}, ref)

    assert {:error, {:instance_owner_conformance_failed, :claim, :rejected}} =
             Conformance.run(RejectedOwner, ref)

    assert {:error, {:instance_owner_conformance_failed, :validation, :lease_rejected}} =
             Conformance.run(SecondValidationRejectOwner, ref)
  end

  test "distributed concurrency failures distinguish rejection, timeout, and bad winners" do
    cases = [
      {:no_successful_claim, :no_successful_claim, []},
      {:contender_timeout, :contender_exit, [timeout: 10]},
      {:duplicate_tokens, :duplicate_fencing_token, []},
      {:multiple_current, :multiple_current_leases, []}
    ]

    Enum.each(cases, fn {mode, code, extra_opts} ->
      {:ok, server} = ConcurrencyFaultOwner.start_link(mode)
      ref = Ref.new(AgentDefinition, "owner-conformance-#{mode}")

      opts =
        [profile: :distributed, concurrent_claims: 3]
        |> Keyword.merge(extra_opts)

      assert {:error, {:instance_owner_conformance_failed, :concurrency, ^code}} =
               Conformance.run({ConcurrencyFaultOwner, server: server}, ref, opts)

      Agent.stop(server)
    end)
  end
end
