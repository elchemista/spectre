defmodule SpectreOperationValueContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Delivery.Consent
  alias Spectre.Operation.Delivery.Policy
  alias Spectre.Operation.Delivery.Receipt
  alias Spectre.Operation.Ref
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Update

  test "Definition keeps a closed, unique local and imported operation catalog" do
    local = Spec.new(id: :local, kind: :function, executor: {__MODULE__, :execute})

    definition =
      Definition.new(
        id: :closed_catalog,
        version: 1,
        kind: :work,
        operations: [local],
        imports: [:global],
        branches: %{approved: [:local, :global]},
        waits: [:event],
        triggers: [:event]
      )

    assert Definition.validate(definition) == :ok
    assert {:ok, ^local} = Definition.operation(definition, :local)

    assert {:error, {:operation_not_registered, :global}} =
             Definition.operation(definition, :global)

    assert_raise ArgumentError, ~r/invalid_loop_definition_imports/, fn ->
      Definition.new(
        id: :duplicates,
        version: 1,
        kind: :work,
        imports: [:global, :global]
      )
    end

    assert_raise ArgumentError, ~r/invalid_loop_definition_branches/, fn ->
      Definition.new(
        id: :open_branch,
        version: 1,
        kind: :work,
        imports: [:global],
        branches: %{unsafe: [:not_registered]}
      )
    end
  end

  test "control commands have a validated, bounded idempotency history" do
    control = Control.new("loop-1")

    command =
      Command.new("loop-1", :pause,
        id: "pause-1",
        correlation_id: "correlation-1"
      )

    assert {:ok, pending} = Control.request(control, command)
    assert pending.pending.status == :committed
    assert {:duplicate, ^pending} = Control.request(pending, command)

    applied = Command.applied(pending.pending)
    finished = Control.finish(pending, applied)
    assert Control.validate(finished) == :ok
    assert finished.last_command == applied
    assert finished.history == [applied]
    assert finished.state == :paused
  end

  test "Update rejects malformed status fields and duplicate invalidations" do
    pending =
      Update.new(%{items: [1]},
        id: "update-1",
        correlation_id: "correlation-1",
        requested_at: 10
      )

    assert Update.validate(pending) == :ok

    assert Update.validate(%{pending | applied_at: 11}) ==
             {:error, :invalid_pending_operation_update}

    applied = Update.applied(pending, 1, [:queue])
    assert Update.validate(applied) == :ok

    assert Update.validate(%{applied | invalidations: [:queue, :queue]}) ==
             {:error, :invalid_operation_update_invalidations}

    rejected = Update.rejected(pending, :invalid_url)
    assert Update.validate(rejected) == :ok

    assert Update.validate(%{rejected | applied_context_revision: 1}) ==
             {:error, :invalid_rejected_operation_update}
  end

  test "delivery values enforce revocation and terminal receipt transitions" do
    consent =
      Consent.new(
        id: "consent-1",
        subject_id: "subject-1",
        destination: %{channel: :email},
        granted_at: 10,
        expires_at: 30,
        channels: [:email]
      )

    assert Consent.active?(consent, 20)
    revoked = Consent.revoke(consent, 21)
    refute Consent.active?(revoked, 22)
    assert Consent.revoke(revoked, 25) == revoked

    authorized = %Receipt{
      id: "receipt-1",
      event_id: "event-1",
      loop_id: "loop-1",
      subject_id: "subject-1",
      destination: %{channel: :email},
      channel: :email,
      consent_id: consent.id,
      dedupe_key: "dedupe-1",
      status: :authorized,
      decided_at: 20
    }

    assert Receipt.validate(authorized) == :ok
    assert {:ok, delivered} = Receipt.transition(authorized, :delivered, %{id: "external"}, 22)
    assert delivered.status == :delivered
    assert {:ok, ^delivered} = Receipt.transition(delivered, :delivered, %{id: "external"}, 23)

    assert {:error, {:invalid_delivery_receipt_transition, :delivered, :failed}} =
             Receipt.transition(delivered, :failed, :transport_failed, 24)

    denied = %{authorized | status: :denied, reason: :policy_denied}
    assert Receipt.validate(denied) == :ok

    assert {:error, {:invalid_delivery_receipt_transition, :denied, :delivered}} =
             Receipt.transition(denied, :delivered, %{id: "forbidden"}, 25)

    assert_raise ArgumentError, ~r/invalid_delivery_event_types/, fn ->
      Policy.new(event_types: [:completed, :completed])
    end
  end

  test "operation references reject malformed or nonportable identities" do
    valid = %Ref{
      id: "loop-1",
      kind: :work,
      subject_id: "subject-1",
      controller: __MODULE__,
      correlation_id: "correlation-1"
    }

    assert Ref.validate(valid) == :ok
    assert Ref.validate(%{valid | kind: :mission}) == {:error, :invalid_operation_ref_kind}
    assert Ref.validate(%{valid | subject_id: ""}) == {:error, :invalid_operation_ref_identity}
  end

  def execute(value, _context), do: {:ok, value}
end
