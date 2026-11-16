defmodule Spectre.Server.StorePayloadTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.GAM.Managed.Store, as: Memory
  alias Spectre.Server.Store.{Payload, Port}

  defmodule Payloads do
    @behaviour Spectre.Payload.Store

    def put(bytes, context, opts) do
      reference = %{object: System.unique_integer([:positive])}
      Agent.update(opts[:agent], &Map.put(&1, reference, bytes))
      send(opts[:owner], {:payload_write, context, bytes})
      {:ok, reference}
    end

    def fetch(reference, context, opts) do
      send(opts[:owner], {:payload_read, context})

      case Agent.get(opts[:agent], &Map.fetch(&1, reference)) do
        {:ok, bytes} -> {:ok, bytes}
        :error -> {:error, :payload_missing}
      end
    end
  end

  defmodule Refused do
    @behaviour Spectre.Payload.Store
    def put(_, _, _), do: {:error, :storage_offline}
    def fetch(_, _, _), do: {:error, :storage_offline}
  end

  setup do
    backend = start_supervised!({Memory, []})
    objects = start_supervised!({Agent, fn -> %{} end})

    config = %{
      store: {Memory, backend},
      payload_store: {Payloads, agent: objects, owner: self()},
      domain: "test:payload-domain"
    }

    %{config: config, port: {Payload, config}, backend: backend, objects: objects}
  end

  test "protected records keep opaque references in coordination storage and round-trip structs",
       c do
    key = {:spectre_gam_command, "command:1"}

    value = %{
      input: Spectre.Input.new("private content"),
      result: %{email: "private@example.test"}
    }

    assert {:ok, revision} = Port.put_new(c.port, key, value)

    assert {:ok,
            %{revision: ^revision, value: %{"spectre_payload_record" => 1, "reference" => ref}}} =
             Memory.fetch(c.backend, key)

    assert is_map(ref)
    assert_receive {:payload_write, %{domain: "test:payload-domain", key: ^key}, _}
    assert {:ok, %{revision: ^revision, value: ^value}} = Port.fetch(c.port, key)

    assert {:ok, updated} = Port.compare_and_swap(c.port, key, revision, %{state: :finished})
    assert {:ok, %{revision: ^updated, value: %{state: :finished}}} = Port.fetch(c.port, key)
    assert {:error, :conflict} = Port.compare_and_swap(c.port, key, revision, %{state: :stale})
    assert :ok = Port.delete(c.port, key, updated)
    assert :not_found = Port.fetch(c.port, key)
  end

  test "pages hydrate only their selected records and preserve revisions and cursor", c do
    for n <- 1..3 do
      assert {:ok, _} = Port.put_new(c.port, {:external_approval, "owner", n}, %{private: n})
    end

    assert {:ok, first, cursor} = Port.list(c.port, {:external_approval, "owner"}, limit: 2)
    assert Enum.map(first, fn {_, entry} -> entry.value end) == [%{private: 1}, %{private: 2}]
    assert not is_nil(cursor)

    assert {:ok, [{_, %{value: %{private: 3}}}], nil} =
             Port.list(c.port, {:external_approval, "owner"}, after: cursor)
  end

  test "unrelated keys and existing inline records retain their original behavior", c do
    assert {:ok, revision} = Port.put_new(c.port, {:managed_authority, "domain"}, %{ready: true})

    assert {:ok, %{revision: ^revision, value: %{ready: true}}} =
             Memory.fetch(c.backend, {:managed_authority, "domain"})

    refute_receive {:payload_write, _, _}
    assert {:ok, _} = Memory.put_new(c.backend, {:external_approval, "legacy"}, %{legacy: true})
    assert {:ok, %{value: %{legacy: true}}} = Port.fetch(c.port, {:external_approval, "legacy"})
  end

  test "hydrated pages obey the existing byte budget and continue without skipping content", c do
    value = %{private: String.duplicate("x", 700)}

    for n <- 1..3,
        do: assert({:ok, _} = Port.put_new(c.port, {:external_approval, n}, value))

    assert {:ok, [{first, %{value: ^value}}], cursor} =
             Port.list(c.port, {:external_approval}, max_bytes: 1_024)

    assert {:ok, [{second, %{value: ^value}}], cursor} =
             Port.list(c.port, {:external_approval}, max_bytes: 1_024, after: cursor)

    refute first == second

    assert {:ok, [{third, %{value: ^value}}], nil} =
             Port.list(c.port, {:external_approval}, max_bytes: 1_024, after: cursor)

    assert third != first and third != second

    assert {:error, :store_page_entry_too_large} =
             Port.list(c.port, {:external_approval}, max_bytes: 512)
  end

  test "missing or corrupt external content returns an error without inline fallback", c do
    key = {:external_approval, "missing"}
    assert {:ok, _} = Port.put_new(c.port, key, %{private: "unrecoverable"})
    Agent.update(c.objects, fn _ -> %{} end)
    assert {:error, :payload_missing} = Port.fetch(c.port, key)
    assert {:error, :payload_missing} = Port.list(c.port, {:external_approval})

    Agent.update(c.objects, fn _ -> %{bad: <<0>>} end)

    assert {:ok, _} =
             Memory.put_new(c.backend, {:external_approval, "corrupt"}, %{
               "spectre_payload_record" => 1,
               "reference" => :bad
             })

    assert {:error, _} = Port.fetch(c.port, {:external_approval, "corrupt"})
  end

  test "a failed payload write never acquires a plaintext coordination record", c do
    config = %{c.config | payload_store: {Refused, []}}
    key = {:spectre_gam_command, "failed"}

    assert {:error, :storage_offline} = Payload.put_new(config, key, %{private: "content"})
    assert :not_found = Memory.fetch(c.backend, key)
  end
end
