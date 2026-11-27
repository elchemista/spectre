defmodule Spectre.Server.GAM.Managed.PayloadTest do
  use ExUnit.Case, async: true

  alias ExGAM.Evidence
  alias Spectre.Server.Checkpoint
  alias Spectre.Server.GAM.Managed.Payload

  defmodule Store do
    @behaviour Spectre.Payload.Store
    def put(bytes, context, opts) do
      send(opts[:owner], {:saved, bytes, context})
      {:ok, "opaque-id"}
    end

    def fetch("opaque-id", context, opts) do
      send(opts[:owner], {:fetched, context})
      {:ok, Keyword.fetch!(opts, :bytes)}
    end

    def fetch(_, _, _), do: {:error, :not_found}
  end

  test "only an opaque marker is retained and legacy content stays readable" do
    value = %{body: "private", to: "private@example.invalid"}
    context = %{kind: :operation, domain_ref: "domain-1"}
    config = {Store, owner: self()}

    assert {:ok, marker} = Payload.protect(config, value, context)
    assert marker == %{"spectre_payload" => 1, "reference" => "opaque-id"}
    assert_received {:saved, bytes, ^context}

    config = {Store, owner: self(), bytes: bytes}
    assert {:ok, ^value} = Payload.restore(config, marker, context)
    assert_received {:fetched, ^context}
    assert {:ok, ^value} = Payload.protect(nil, value, context)
    assert {:ok, ^value} = Payload.restore(nil, value, context)
  end

  test "missing content and invalid stored bytes return errors without inline fallback" do
    marker = %{"spectre_payload" => 1, "reference" => "missing"}
    assert {:error, :not_found} = Payload.restore({Store, owner: self()}, marker, %{})

    marker = %{marker | "reference" => "opaque-id"}
    assert {:error, :payload_store_not_configured} = Payload.restore(nil, marker, %{})
    assert {:error, _} = Payload.restore({Store, owner: self(), bytes: "bad"}, marker, %{})
  end

  test "transient evidence hydration preserves the canonical reference" do
    payload = %{command_id: "command-1", operation: :send}
    {:ok, bytes} = Checkpoint.encode_value(payload)

    evidence =
      struct(Evidence,
        ref: "persisted-reference",
        payload: %{"spectre_payload" => 1, "reference" => "opaque-id"}
      )

    opts = [ingress_opts: [payload_store: {Store, owner: self(), bytes: bytes}]]

    assert {:ok, [hydrated]} = Payload.restore_evidence([evidence], opts, "domain-1")
    assert hydrated.ref == evidence.ref
    assert hydrated.payload == payload
    assert_received {:fetched, %{kind: :evidence, domain_ref: "domain-1"}}
  end

  test "unconfigured operation arguments remain opaque even when they resemble an internal marker" do
    consequence = %{"payload" => %{"spectre_payload" => 1, "reference" => "application-data"}}

    assert {:ok, ^consequence} =
             Spectre.Server.GAM.Managed.Content.consequence(nil, consequence, "domain")
  end

  test "a malformed external operation bundle is rejected before effect preparation" do
    marker = %{"spectre_payload" => 1, "reference" => "opaque-id"}

    for invalid <- [[], %{}, %{"payload" => %{}}] do
      {:ok, bytes} = Checkpoint.encode_value(invalid)
      config = {Store, owner: self(), bytes: bytes}

      assert {:error, :invalid_operation_payload} =
               Spectre.Server.GAM.Managed.Content.consequence(
                 config,
                 %{"payload" => marker},
                 "domain"
               )
    end
  end
end
