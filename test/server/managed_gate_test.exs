defmodule Spectre.Server.ManagedGateTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.GAM.Managed.Gate

  setup do
    owner = self()

    gate =
      start_supervised!(
        {Gate,
         %{
           owner: owner,
           runtime: owner,
           consumer: owner,
           token: "secret",
           auth: %{principal: "human"},
           show_timeout: 10_000
         }}
      )

    %{gate: gate}
  end

  test "input proof cannot authenticate different interpreted text with a copied digest", %{
    gate: gate
  } do
    :ok = Gate.show(gate, %{"presentation_ref" => "bound-input"}, self())
    :ok = Gate.presented(gate, "bound-input", self())
    :ok = Gate.bind_deadline(gate, "bound-input", :infinity)
    original = "non procedere grazie"
    {:ok, proof} = Gate.authorize_input(gate, "bound-input", original, self())
    digest = Base.encode16(:crypto.hash(:sha256, original), case: :lower)

    envelope = %{
      kind: :presentation_response,
      presentation: %{ref: "bound-input"},
      stance: :supports,
      input: Spectre.Input.new("procedi pure")
    }

    assert {:error, :consent_transport_proof_required} =
             Spectre.Server.GAM.Managed.Ingress.observe(
               %{},
               envelope,
               System.system_time(:millisecond),
               gate: gate,
               consent_proof: proof,
               source_digest: digest
             )

    assert :ok = Gate.consume(gate, "bound-input", :contradicts, proof, digest)
  end

  test "authentication and rendering do not create user consent", %{gate: gate} do
    assert {:error, :unauthenticated} = Gate.authenticate(gate, "wrong")
    assert {:ok, %{principal: "human"}} = Gate.authenticate(gate, "secret")
    :ok = Gate.show(gate, %{"presentation_ref" => "one"}, self())

    assert_receive {Spectre.Server.GAM.Managed, _,
                    {:presentation, %{"presentation_ref" => "one"}}}

    assert {:error, :consent_transport_not_authorized} =
             Gate.authorize(gate, "one", :confirm, self())

    assert :ok = Gate.presented(gate, "one", self())
    assert_receive {:spectre_managed_presented, "one"}
    assert {:error, :consent_transport_proof_required} = Gate.consume(gate, "one", :supports, nil)
  end

  test "a duplicate show cannot replace an acknowledged presentation or its proof", %{gate: gate} do
    material = %{"presentation_ref" => "unique"}
    assert :ok = Gate.show(gate, material, self())
    assert :ok = Gate.presented(gate, "unique", self())
    assert :ok = Gate.bind_deadline(gate, "unique", :infinity)
    assert {:ok, proof} = Gate.authorize(gate, "unique", :confirm, self())
    assert_receive {Spectre.Server.GAM.Managed, _, {:presentation, ^material}}

    assert {:error, :presentation_already_pending} = Gate.show(gate, material, self())
    refute_receive {Spectre.Server.GAM.Managed, _, {:presentation, ^material}}
    assert :ok = Gate.consume(gate, "unique", :supports, proof)
  end

  test "a missing presentation consumer fails closed without stopping the gate", %{gate: gate} do
    :sys.replace_state(gate, &%{&1 | consumer: nil})

    assert {:error, :presentation_consumer_unavailable} =
             Gate.show(gate, %{"presentation_ref" => "no-consumer"}, self())

    assert Process.alive?(gate)
    assert :sys.get_state(gate).shows == %{}
    assert {:ok, %{principal: "human"}} = Gate.authenticate(gate, "secret")
  end

  test "decision proof is bound to presentation and stance and consumed once", %{gate: gate} do
    :ok = Gate.show(gate, %{"presentation_ref" => "one"}, self())
    :ok = Gate.presented(gate, "one", self())
    :ok = Gate.bind_deadline(gate, "one", System.system_time(:millisecond) + 600_000)
    assert {:ok, proof} = Gate.authorize(gate, "one", :confirm, self())

    assert {:ok, replacement} = Gate.authorize(gate, "one", :confirm, self())
    refute replacement == proof

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "one", :supports, proof)

    proof = replacement

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "two", :supports, proof)

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "one", :contradicts, proof)

    assert :ok = Gate.consume(gate, "one", :supports, proof)

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "one", :supports, proof)

    assert {:error, :consent_transport_not_authorized} =
             Gate.authorize(gate, "one", :confirm, self())
  end

  test "a process pretending to be the consumer cannot acknowledge or decide", %{gate: gate} do
    consumer = self()
    :ok = Gate.show(gate, %{"presentation_ref" => "one"}, self())

    assert {:error, :presentation_not_authorized} =
             Task.async(fn -> Gate.presented(gate, "one", consumer) end) |> Task.await()

    :ok = Gate.presented(gate, "one", consumer)

    assert {:error, :consent_transport_not_authorized} =
             Task.async(fn -> Gate.authorize(gate, "one", :confirm, consumer) end) |> Task.await()
  end

  test "expired presentation and proof are rejected", %{gate: gate} do
    :ok = Gate.show(gate, %{"presentation_ref" => "one"}, self())
    :ok = Gate.presented(gate, "one", self())
    :ok = Gate.bind_deadline(gate, "one", System.system_time(:millisecond) + 600_000)
    {:ok, proof} = Gate.authorize(gate, "one", :confirm, self())

    :sys.replace_state(gate, fn state ->
      put_in(state, [:proofs, proof, :expires_at], 0)
    end)

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "one", :supports, proof)
  end

  test "the bridge binds long or infinite consent expiry without a five-minute cap", %{gate: gate} do
    for deadline <- [System.system_time(:millisecond) + 3_600_000, :infinity, nil] do
      ref = "deadline-#{inspect(deadline)}"
      :ok = Gate.show(gate, %{"presentation_ref" => ref}, self())
      :ok = Gate.presented(gate, ref, self())
      assert :ok = Gate.bind_deadline(gate, ref, deadline)
      assert {:ok, proof} = Gate.authorize(gate, ref, :confirm, self())
      assert :ok = Gate.consume(gate, ref, :supports, proof)
    end
  end

  test "binding an expired deadline denies consent and another actor cannot extend it", %{
    gate: gate
  } do
    :ok = Gate.show(gate, %{"presentation_ref" => "expired"}, self())
    :ok = Gate.presented(gate, "expired", self())

    assert {:error, :consent_transport_not_authorized} =
             Gate.authorize(gate, "expired", :confirm, self())

    assert {:error, :presentation_deadline_not_authorized} =
             Task.async(fn -> Gate.bind_deadline(gate, "expired", :infinity) end) |> Task.await()

    assert :ok = Gate.bind_deadline(gate, "expired", 0)

    assert {:error, :presentation_deadline_not_authorized} =
             Gate.bind_deadline(gate, "expired", :infinity)

    assert {:error, :consent_transport_not_authorized} =
             Gate.authorize(gate, "expired", :confirm, self())
  end

  test "deadline binding is idempotent only for an identical deadline", %{gate: gate} do
    deadline = System.system_time(:millisecond) + 60_000
    :ok = Gate.show(gate, %{"presentation_ref" => "same"}, self())
    :ok = Gate.presented(gate, "same", self())
    assert :ok = Gate.bind_deadline(gate, "same", deadline, "show:one")
    assert :ok = Task.async(fn -> Gate.bind_deadline(gate, "same", deadline) end) |> Task.await()

    assert {:error, :presentation_deadline_not_authorized} =
             Gate.bind_deadline(gate, "same", deadline + 1)
  end

  test "closing an infinite show releases its slot and any unconsumed decision", %{gate: gate} do
    for number <- 1..260 do
      ref = "close-#{number}"
      show = "show:#{number}"
      assert :ok = Gate.show(gate, %{"presentation_ref" => ref}, self())
      assert :ok = Gate.presented(gate, ref, self())
      assert :ok = Gate.bind_deadline(gate, ref, :infinity, show)
      assert {:ok, proof} = Gate.authorize(gate, ref, :confirm, self())
      assert :ok = Gate.close_show(gate, show)

      assert {:error, :consent_transport_proof_required} =
               Gate.consume(gate, ref, :supports, proof)
    end
  end

  test "authenticated input provenance is exact and cannot itself select a consent stance", %{
    gate: gate
  } do
    :ok = Gate.show(gate, %{"presentation_ref" => "interpreted"}, self())
    :ok = Gate.presented(gate, "interpreted", self())
    :ok = Gate.bind_deadline(gate, "interpreted", :infinity)
    {:ok, proof} = Gate.authorize_input(gate, "interpreted", "procedi pure", self())
    digest = Base.encode16(:crypto.hash(:sha256, "procedi pure"), case: :lower)

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "interpreted", :supports, proof)

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "interpreted", :supports, proof, "other")

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "interpreted", :unclear, proof, digest)

    assert :ok = Gate.consume(gate, "interpreted", :supports, proof, digest)

    assert {:error, :consent_transport_proof_required} =
             Gate.consume(gate, "interpreted", :supports, proof, digest)
  end

  test "untrusted actor and empty text cannot obtain input provenance", %{gate: gate} do
    consumer = self()
    :ok = Gate.show(gate, %{"presentation_ref" => "reply"}, self())
    :ok = Gate.presented(gate, "reply", self())
    :ok = Gate.bind_deadline(gate, "reply", :infinity)

    assert {:error, :consent_transport_not_authorized} =
             Gate.authorize_input(gate, "reply", "", consumer)

    assert {:error, :consent_transport_not_authorized} =
             Task.async(fn -> Gate.authorize_input(gate, "reply", "procedi pure", consumer) end)
             |> Task.await()
  end
end
