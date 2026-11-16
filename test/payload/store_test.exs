defmodule Spectre.Payload.StoreTest do
  use ExUnit.Case, async: true

  alias Spectre.Payload.Store

  defmodule Adapter do
    @behaviour Store

    def put(payload, context, opts) do
      send(opts[:owner], {:put, self(), payload, context})
      Keyword.fetch!(opts, :result)
    end

    def fetch(reference, context, opts) do
      send(opts[:owner], {:fetch, self(), reference, context})
      Keyword.fetch!(opts, :result)
    end
  end

  defmodule Failing do
    @behaviour Store
    def put(_, _, _), do: raise("private content must not escape")
    def fetch(_, _, _), do: throw({:private, "content"})
  end

  test "accepts ordinary adapter options and optional absence" do
    assert {:ok, nil} = Store.normalize(nil)
    config = {Adapter, owner: self(), result: {:ok, :reference}}
    assert {:ok, ^config} = Store.normalize(config)

    for config <- [:inline, {Adapter, [:bad]}, {__MODULE__, []}, {nil, []}] do
      assert {:error, :invalid_payload_store} = Store.normalize(config)
    end
  end

  test "references are opaque portable values rather than prescribed hashes" do
    payload = %{email: "private@example.invalid", body: "private content"}
    context = %{kind: :operation, operation_id: "command-1"}

    for reference <- [42, "object-1", %{bucket: "private", id: "object-1"}, {:opaque, 1}] do
      config = {Adapter, owner: self(), result: {:ok, reference}}
      assert {:ok, ^reference} = Store.put(config, payload, context)
      assert_received {:put, caller, ^payload, ^context}
      assert caller == self()
    end

    config = {Adapter, owner: self(), result: {:ok, payload}}
    assert {:ok, ^payload} = Store.fetch(config, "object-1", context)
    assert_received {:fetch, _, "object-1", ^context}
  end

  test "nonportable references cannot be persisted" do
    config = {Adapter, owner: self(), result: {:ok, self()}}
    assert {:error, :invalid_payload_reference} = Store.put(config, "payload", %{})
  end

  test "storage failures do not trigger retry or inline fallback" do
    config = {Adapter, owner: self(), result: {:error, :unavailable}}
    assert {:error, :unavailable} = Store.put(config, "private", %{})
    assert_received {:put, _, "private", %{}}
    refute_received {:put, _, _, _}
    assert {:error, :unavailable} = Store.fetch(config, "object-1", %{})

    assert {:error, :invalid_payload_store_result} =
             Store.put({Adapter, owner: self(), result: :ok}, "private", %{})
  end

  test "exceptions and throws omit private exception and reason values" do
    assert {:error, {:adapter_callback_exception, Failing, :put, RuntimeError}} =
             Store.put({Failing, []}, "private", %{})

    assert {:error, {:adapter_callback_failure, Failing, :fetch, :throw}} =
             Store.fetch({Failing, []}, "object-1", %{})
  end

  test "invalid context and absent store return explicit failures" do
    assert {:error, :invalid_payload_context} = Store.put(nil, "payload", [])
    assert {:error, :invalid_payload_context} = Store.fetch(nil, "id", [])
    assert {:error, :payload_store_not_configured} = Store.put(nil, "payload", %{})
    assert {:error, :payload_store_not_configured} = Store.fetch(nil, "id", %{})
  end
end
