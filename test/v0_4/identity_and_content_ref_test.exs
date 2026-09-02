defmodule Spectre.V04Test.InvalidIdSource do
  @moduledoc false
  @behaviour Spectre.Id.Source

  @impl true
  def generate, do: "attempt:018f0000-0000-7000-8000-000000000001"
end

defmodule Spectre.V04Test.IdentityAndContentRefTest do
  use ExUnit.Case, async: true

  alias Spectre.{Id, Portable}

  test "UUIDv7 adapter returns a raw canonical identifier and validates version and variant" do
    raw = UUIDv7.bingenerate()

    assert <<_timestamp::48, 7::4, _clock::12, 2::2, _random::62>> = raw
    assert byte_size(raw) == 16

    encoded = UUIDv7.encode(raw)
    assert Id.valid?(encoded)
    assert UUIDv7.decode(encoded) == raw

    generated = Id.generate(Id.UUIDv7)
    assert Id.valid?(generated)
    assert byte_size(generated) == 36
    refute String.contains?(generated, ":")

    refute Id.valid?("018f0000-0000-6000-8000-000000000001")
    refute Id.valid?("018f0000-0000-7000-7000-000000000001")
    refute Id.valid?("018F0000-0000-7000-8000-000000000001")
    refute Id.valid?("attempt:018f0000-0000-7000-8000-000000000001")

    assert_raise ArgumentError, ~r/returned an invalid UUIDv7/, fn ->
      Id.generate(Spectre.V04Test.InvalidIdSource)
    end
  end

  test "UUIDv7 source is strictly monotonic in adapter call order" do
    identifiers = Enum.map(1..512, fn _index -> Id.UUIDv7.generate() end)

    assert Enum.all?(identifiers, &Id.valid?/1)
    assert identifiers == Enum.sort(identifiers)
    assert length(identifiers) == identifiers |> Enum.uniq() |> length()

    timestamps = Enum.map(identifiers, &UUIDv7.extract_timestamp/1)
    assert timestamps == Enum.sort(timestamps)
  end

  test "content references are deterministic SHA-256 values over canonical bytes" do
    value =
      Map.new([
        {"z", [3, 2, 1]},
        {"nested", Map.new([{"enabled", true}, {"amount", 4_200}])},
        {"class", "refund.issue"}
      ])

    same_value_different_order =
      Map.new([
        {"class", "refund.issue"},
        {"nested", Map.new([{"amount", 4_200}, {"enabled", true}])},
        {"z", [3, 2, 1]}
      ])

    assert {:ok, canonical} = Portable.canonical_value(value)

    expected_digest =
      canonical
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert {:ok, ^expected_digest} = Portable.digest(value)
    assert {:ok, "candidate:" <> ^expected_digest} = Portable.content_ref(:candidate, value)

    assert Portable.content_ref(:candidate, value) ==
             Portable.content_ref("candidate", same_value_different_order)

    assert {:ok, changed_ref} =
             Portable.content_ref(:candidate, Map.put(value, "class", "refund.cancel"))

    refute changed_ref == "candidate:" <> expected_digest
    assert Regex.match?(~r/\Acandidate:[0-9a-f]{64}\z/, changed_ref)
  end

  test "semantic records reject an identity that does not address their exact content" do
    assert {:ok, principal} = Spectre.Principal.new(%{kind: :human})
    assert principal.ref == Spectre.Principal.content_ref(principal)

    assert {:ok, ^principal} = Spectre.Principal.new(principal)

    assert {:error, {:content_ref_mismatch, "principal:forged", expected}} =
             Spectre.Principal.new(%{ref: "principal:forged", kind: :human})

    assert expected == principal.ref
  end

  test "Genesis uses an explicit external anchor while exposing its signed content address" do
    attrs = %{
      ref: "institution:genesis:2026-09-02",
      domain_ref: "domain:refunds",
      principal_refs: [],
      root_mandate_refs: [],
      constitution_ref: "constitution:empty",
      surface_ref: "surface:empty",
      surface_revision: 0,
      host_profile_ref: "host:profile",
      issued_at: 1_000,
      attestation_ref: "attestation:genesis"
    }

    assert {:ok, genesis} = Spectre.Genesis.new(attrs)
    assert genesis.ref == attrs.ref
    assert Regex.match?(~r/\Agenesis:[0-9a-f]{64}\z/, Spectre.Genesis.content_ref(genesis))
    assert {:error, {:invalid_ref, :ref, _shape}} = Spectre.Genesis.new(Map.delete(attrs, :ref))
  end

  test "Attempt identities are UUIDv7 occurrences, not caller-selected semantic names" do
    attrs = %{
      act_ref: "act:known",
      executor_ref: "principal:executor",
      material_digest: String.duplicate("a", 64),
      generation: 1,
      grant_nonce_digest: String.duplicate("b", 64),
      started_at: 1_000
    }

    assert {:error, {:invalid_attempt_ref, nil}} = Spectre.Attempt.new(attrs)

    ref = Id.generate()
    assert {:ok, attempt} = Spectre.Attempt.new(Map.put(attrs, :ref, ref))
    assert attempt.ref == ref

    assert {:error, {:invalid_attempt_ref, "attempt:chosen"}} =
             Spectre.Attempt.new(Map.put(attrs, :ref, "attempt:chosen"))
  end
end
