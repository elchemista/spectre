defmodule SpectreStateCodecRecoveryContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Awaitable
  alias Spectre.Effect
  alias Spectre.State
  alias Spectre.State.Codec

  test "decode! restores a valid snapshot and raises on corrupted boot state" do
    state = %State{
      revision: 9,
      conversation_id: "codec-recovery",
      data: %{checkpoint: :ready}
    }

    assert {:ok, json} = Codec.encode_json(state)
    assert %State{revision: 9, data: %{checkpoint: :ready}} = Codec.decode!(json)

    assert_raise ArgumentError, ~r/invalid Spectre state/, fn ->
      Codec.decode!(~s({"state_version":4,"revision":"corrupt"}))
    end
  end

  test "binaries unsafe for JSONB are tagged, round-trip, and never emit \\u0000" do
    raw_id = <<0, 255, 7, 0>>

    state = %State{
      revision: 1,
      conversation_id: "jsonb-safety",
      data: %{lifecycle_id: raw_id, note: "plain text stays plain"}
    }

    assert {:ok, json} = Codec.encode_json(state)
    refute json =~ "\\u0000"
    assert json =~ "plain text stays plain"

    assert {:ok, decoded} = Codec.decode(json)
    assert decoded.data.lifecycle_id == raw_id
    assert decoded.data.note == "plain text stays plain"
  end

  test "an effect idempotency key with unsafe bytes survives the round-trip" do
    effect = %{
      Effect.stage_action(%{name: :publish}, __MODULE__, :agent)
      | idempotency_key: "effect:" <> <<1, 0, 2>>
    }

    assert {:ok, json} = Codec.encode_json(%State{pending_effects: [effect]})
    refute json =~ "\\u0000"

    assert {:ok, decoded} = Codec.decode(json)
    assert [%Effect{idempotency_key: "effect:" <> <<1, 0, 2>>}] = decoded.pending_effects
  end

  test "decoding enforces collection bounds before recovered state becomes live" do
    effect = Effect.stage_action(%{name: :publish}, __MODULE__, :agent)
    assert {:ok, encoded} = Codec.encode(%State{pending_effects: [effect]})
    [encoded_effect] = encoded["pending_effects"]

    oversized =
      Map.put(encoded, "pending_effects", List.duplicate(encoded_effect, 257))

    assert {:error, {:state_collection_too_large, :pending_effects, 257, 256}} =
             Codec.decode(oversized)
  end

  test "legacy snapshots accept atom schema keys and plain nested maps without creating atoms" do
    assert {:ok, encoded} = Codec.encode(%State{})

    atom_keyed =
      encoded
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
      |> Map.put(:state_version, 2)
      |> Map.put(:data, %{"legacy" => %{"plain" => 7}})

    assert {:ok,
            %State{
              state_version: 5,
              revision: 0,
              data: %{"legacy" => %{"plain" => 7}}
            }} = Codec.decode(atom_keyed)
  end

  test "schema v5 round-trips independent Run lifecycle and rejects duplicate ownership" do
    first =
      %{name: :publish}
      |> Effect.stage_action(__MODULE__, :agent)
      |> Effect.bind_run("run-a")
      |> Effect.waiting_policy(:confirm)

    second =
      %{name: :archive}
      |> Effect.stage_action(__MODULE__, :agent)
      |> Effect.bind_run("run-b")
      |> Effect.waiting_policy(:confirm)

    state = %State{
      pending_effects: [first, second],
      planned_effects: [first, second],
      awaitables: [
        Awaitable.open_policy(:confirm, first),
        Awaitable.open_policy(:confirm, second)
      ]
    }

    assert {:ok, %{"state_version" => 5} = encoded} = Codec.encode(state)
    assert {:ok, restored} = Codec.decode(encoded)
    assert Enum.map(restored.pending_effects, & &1.run_id) == ["run-a", "run-b"]
    assert Enum.map(restored.awaitables, & &1.run_id) == ["run-a", "run-b"]

    duplicate =
      put_in(
        encoded,
        ["pending_effects"],
        [hd(encoded["pending_effects"]), hd(encoded["pending_effects"])]
      )

    assert {:error, {:duplicate_pending_effect_scope, "run-a"}} = Codec.decode(duplicate)

    [first_awaitable, second_awaitable] = encoded["awaitables"]

    mismatched =
      put_in(
        encoded,
        ["awaitables"],
        [
          Map.put(first_awaitable, "run_id", "run-b"),
          Map.put(second_awaitable, "run_id", "run-a")
        ]
      )

    assert {:error, {:invalid_policy_lifecycle_owner, _, "run-b", "run-a"}} =
             Codec.decode(mismatched)
  end

  test "duplicate normalized keys and non-schema keys fail closed" do
    assert {:ok, encoded} = Codec.encode(%State{})

    duplicate = Map.put(encoded, :revision, 4)

    assert {:error, {:duplicate_or_unknown_field, :state, "revision"}} =
             Codec.decode(duplicate)

    invalid_key = Map.put(encoded, 123, "unsafe")

    assert {:error, {:invalid_schema_key, :other}} = Codec.decode(invalid_key)
  end

  test "nested effect and awaitable fields are type checked during recovery" do
    effect = Effect.stage_action(%{name: :publish}, __MODULE__, :agent)

    awaitable =
      Awaitable.open_policy(:confirm, effect, max_attempts: 3)

    state = %State{
      pending_effects: [Effect.waiting_policy(effect, :confirm)],
      planned_effects: [Effect.waiting_policy(effect, :confirm)],
      awaitables: [awaitable]
    }

    assert {:ok, encoded} = Codec.encode(state)
    assert {:ok, %State{awaitables: [%Awaitable{max_attempts: 3}]}} = Codec.decode(encoded)

    [encoded_effect] = encoded["pending_effects"]

    invalid_key =
      put_in(
        encoded,
        ["pending_effects"],
        [Map.put(encoded_effect, "idempotency_key", 42)]
      )

    assert {:error, {:invalid_binary, "idempotency_key", :other}} =
             Codec.decode(invalid_key)

    missing_key =
      put_in(
        encoded,
        ["pending_effects"],
        [Map.delete(encoded_effect, "idempotency_key")]
      )

    assert {:error, {:missing_field, "idempotency_key"}} = Codec.decode(missing_key)

    invalid_mode =
      put_in(
        encoded,
        ["pending_effects"],
        [Map.put(encoded_effect, "mode", 123)]
      )

    assert {:error, {:invalid_enum, "mode", 123}} = Codec.decode(invalid_mode)
  end

  test "malformed tagged structs and unsafe in-memory values are rejected predictably" do
    assert {:ok, encoded} = Codec.encode(%State{})

    malformed_struct = %{
      "$spectre" => "struct",
      "module" => "Elixir.Enum",
      "fields" => %{
        "$spectre" => "map",
        "entries" => [
          [
            %{"$spectre" => "atom", "value" => "revision"},
            1
          ]
        ]
      }
    }

    assert {:error, {:invalid_state_struct, "Elixir.Enum", UndefinedFunctionError}} =
             encoded
             |> Map.put("data", malformed_struct)
             |> Codec.decode()

    assert {:error, {:invalid_encoded_state_value, :pid}} =
             encoded
             |> Map.put("data", self())
             |> Codec.decode()

    assert {:error, {:invalid_state_payload, :other}} = Codec.decode(<<1::1>>)
  end
end
