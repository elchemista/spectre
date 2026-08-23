defmodule SpectreInstanceErasureValueContractTest.MissingErasureStatus do
  @moduledoc false

  def erase(_ref, _request, _opts), do: {:ok, :erased}
end

defmodule SpectreInstanceErasureValueContractTest.ReplyStore do
  @moduledoc false

  @behaviour Spectre.Instance.CheckpointStore

  @impl true
  def erase(_ref, _request, opts), do: reply(Keyword.fetch!(opts, :erase_reply))

  @impl true
  def erasure_status(_ref, opts), do: reply(Keyword.fetch!(opts, :status_reply))

  defp reply(:raise), do: raise("adapter failure")
  defp reply(:throw), do: throw(:adapter_failure)
  defp reply(value), do: value
end

defmodule SpectreInstanceErasureValueContractTest do
  use ExUnit.Case, async: true

  alias Spectre.AgentRef
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.CheckpointStore.ErasureConformance
  alias Spectre.Instance.Erasure.Proof
  alias Spectre.Instance.Erasure.Request
  alias Spectre.Instance.Erasure.Status
  alias Spectre.Instance.Owner.Conformance, as: OwnerConformance
  alias Spectre.Instance.Owner.Local
  alias Spectre.Instance.Ref
  alias Spectre.Subject

  alias SpectreInstanceErasureValueContractTest.MissingErasureStatus
  alias SpectreInstanceErasureValueContractTest.ReplyStore

  @digest String.duplicate("a", 64)

  test "erasure requests enforce schema, Ref binding, checkpoint identity, and fences" do
    ref = ref("request")
    valid = request_attrs()

    assert {:ok, %Request{} = present} = Request.new(ref, valid)
    assert :ok = Request.validate(present)

    assert {:ok, %Request{expected_revision: nil, checkpoint_digest: nil}} =
             Request.new(
               ref,
               Keyword.merge(valid, expected_revision: nil, checkpoint_digest: nil)
             )

    assert {:error, {:invalid_instance_erasure_request, :atom}} = Request.new(ref, :invalid)
    assert {:error, {:invalid_instance_erasure_request, :map}} = Request.new(ref, present)

    assert {:error, {:unsupported_instance_erasure_request_schema, 2}} =
             Request.new(ref, Keyword.put(valid, :schema_version, 2))

    assert {:error, :instance_erasure_request_ref_mismatch} =
             Request.new(ref, Keyword.put(valid, :instance_key, "foreign"))

    assert {:error, {:invalid_instance_erasure_request_field, :erasure_id}} =
             Request.new(ref, Keyword.put(valid, :erasure_id, ""))

    assert {:error, :invalid_instance_erasure_checkpoint_identity} =
             Request.new(ref, Keyword.put(valid, :checkpoint_digest, nil))

    assert {:error, :invalid_instance_erasure_checkpoint_identity} =
             Request.new(ref, Keyword.put(valid, :expected_revision, nil))

    assert {:error, {:invalid_instance_erasure_request_field, :checkpoint_digest}} =
             Request.new(ref, Keyword.put(valid, :checkpoint_digest, String.duplicate("z", 64)))

    assert {:error, {:invalid_instance_erasure_request_field, :checkpoint_digest}} =
             Request.new(ref, Keyword.put(valid, :checkpoint_digest, "short"))

    assert {:error, {:invalid_instance_erasure_request_field, :owner_fencing_token}} =
             Request.new(ref, Keyword.put(valid, :owner_fencing_token, 0))

    assert {:error, {:invalid_instance_erasure_request_field, :requested_at}} =
             Request.new(ref, Keyword.put(valid, :requested_at, -1))

    assert {:error, {:invalid_instance_erasure_request, :atom}} = Request.validate(:invalid)
  end

  test "erasure status and proof projections reject malformed or foreign evidence" do
    ref = ref("status")
    {:ok, request} = Request.new(ref, request_attrs())
    assert {:ok, %Status{} = status} = Status.from_request(request, 11)

    assert {:error, {:invalid_instance_erasure_status_field, :erased_at}} =
             Status.from_request(request, -1)

    assert :ok = Status.validate(status, ref)
    assert byte_size(Status.digest(status)) == 64

    assert {:error, :instance_erasure_status_ref_mismatch} =
             Status.validate(status, ref("foreign"))

    invalid_statuses = [
      {%{status | schema_version: 2}, {:unsupported_instance_erasure_status_schema, 2}},
      {%{status | erasure_id: ""}, {:invalid_instance_erasure_status_field, :erasure_id}},
      {%{status | instance_key: ""}, {:invalid_instance_erasure_status_field, :instance_key}},
      {%{status | erased_revision: nil}, :invalid_instance_erasure_status_checkpoint_identity},
      {%{status | checkpoint_digest: String.duplicate("z", 64)},
       {:invalid_instance_erasure_status_field, :checkpoint_digest}},
      {%{status | owner_fencing_token: 0},
       {:invalid_instance_erasure_status_field, :owner_fencing_token}},
      {%{status | erased_at: -1}, {:invalid_instance_erasure_status_field, :erased_at}}
    ]

    Enum.each(invalid_statuses, fn {invalid, reason} ->
      assert {:error, ^reason} = Status.validate(invalid)
    end)

    assert {:error, {:invalid_instance_erasure_status, :atom}} = Status.validate(:invalid)

    key = %{
      kind: :stable,
      prior_state: :present,
      outcome: :erased,
      marker_digest: @digest
    }

    components = %{
      journal: %{outcome: :not_configured, key_count: 0},
      receipt_payloads: %{
        outcome: :not_configured,
        payload_count: 0,
        deleted_count: 0,
        not_found_count: 0
      },
      checkpoint: %{outcome: :erased, key_count: 1}
    }

    attrs = [
      outcome: :erased,
      owner_fencing_token: 12,
      completed_at: 13,
      components: components,
      keys: [key]
    ]

    assert {:ok, %Proof{} = proof} = Proof.new(ref, attrs)
    assert :ok = Proof.validate(proof)

    for invalid <- [
          %{proof | schema_version: 2},
          %{proof | scope: :all_subject_data},
          %{proof | outcome: :unknown},
          %{proof | owner_fencing_token: 0},
          %{proof | completed_at: -1},
          %{proof | components: %{}},
          %{proof | keys: []},
          %{proof | keys: [%{key | kind: :unknown}]},
          %{proof | keys: [%{key | marker_digest: "short"}]}
        ] do
      assert {:error, _reason} = Proof.validate(invalid)
    end

    assert {:error, {:invalid_instance_erasure_proof, :atom}} = Proof.new(ref, :invalid)
    assert {:error, {:invalid_instance_erasure_proof, :atom}} = Proof.validate(:invalid)

    for {value, shape} <- [
          {%{}, :map},
          {[], :list},
          {{:invalid}, :tuple},
          {1.5, :other}
        ] do
      assert {:error, {:invalid_instance_erasure_proof, ^shape}} = Proof.validate(value)
      assert {:error, {:invalid_instance_erasure_status, ^shape}} = Status.validate(value)
    end

    for {value, shape} <- [
          {[], :list},
          {{:invalid}, :tuple},
          {1.5, :other}
        ] do
      assert {:error, {:invalid_instance_erasure_request, ^shape}} = Request.validate(value)
    end

    assert {:error, :invalid_instance_erasure_proof} = Proof.new(ref, %{})
  end

  test "Checkpoint Store erasure wrappers classify unsupported and ambiguous adapters" do
    ref = ref("store")
    foreign = ref("store-foreign")
    {:ok, request} = Request.new(ref, request_attrs())
    {:ok, status} = Status.from_request(request, 20)

    assert {:error, :instance_checkpoint_store_required} =
             CheckpointStore.erasure_capability(nil)

    assert {:error, {:checkpoint_store_not_loaded, Spectre.NotLoadedErasureStore}} =
             CheckpointStore.erasure_capability({Spectre.NotLoadedErasureStore, []})

    assert {:error, {:checkpoint_store_erasure_unsupported, String, :erase, 3}} =
             CheckpointStore.erasure_capability({String, []})

    assert {:error,
            {:checkpoint_store_erasure_unsupported, MissingErasureStatus, :erasure_status, 2}} =
             CheckpointStore.erasure_capability({MissingErasureStatus, []})

    assert {:error, :instance_erasure_request_ref_mismatch} =
             CheckpointStore.erase(
               {ReplyStore, erase_reply: {:ok, :erased}, status_reply: :not_erased},
               foreign,
               request,
               []
             )

    for {reply, expected} <- [
          {{:ok, :erased}, {:ok, :erased}},
          {{:ok, :already_erased}, {:ok, :already_erased}},
          {{:error, :denied}, {:error, :denied}}
        ] do
      store = {ReplyStore, erase_reply: reply, status_reply: {:ok, status}}
      assert CheckpointStore.erase(store, ref, request, []) == expected
    end

    invalid_store = {ReplyStore, erase_reply: :invalid, status_reply: {:ok, status}}

    assert {:error, {:ambiguous, {:invalid_checkpoint_erase_reply, ReplyStore, :invalid}}} =
             CheckpointStore.erase(invalid_store, ref, request, [])

    for action <- [:raise, :throw] do
      store = {ReplyStore, erase_reply: action, status_reply: {:ok, status}}
      assert {:error, {:ambiguous, _reason}} = CheckpointStore.erase(store, ref, request, [])
    end

    assert {:ok, ^status} =
             CheckpointStore.erasure_status(
               {ReplyStore, erase_reply: {:ok, :erased}, status_reply: {:ok, status}},
               ref,
               []
             )

    assert :not_erased =
             CheckpointStore.erasure_status(
               {ReplyStore, erase_reply: {:ok, :erased}, status_reply: :not_erased},
               ref,
               []
             )

    for reply <- [:invalid, {:ok, %{status | instance_key: foreign.key}}, :raise, :throw] do
      store = {ReplyStore, erase_reply: {:ok, :erased}, status_reply: reply}
      assert {:error, _reason} = CheckpointStore.erasure_status(store, ref, [])
    end
  end

  test "public conformance runners reject unsafe option shapes before mutation" do
    ref = ref("conformance-options")

    for opts <- [
          [unknown: true],
          [profile: :cluster],
          [minimum_fencing_token: -1],
          [concurrent_claims: 1],
          [timeout: 0],
          [alternate_ref: ref]
        ] do
      assert {:error, {:instance_owner_conformance_failed, _phase, _code}} =
               OwnerConformance.run(Local, ref, opts)
    end

    assert {:error, {:instance_owner_conformance_failed, :options, :invalid_arguments}} =
             OwnerConformance.run(Local, ref, :invalid)

    for opts <- [
          [unknown: true],
          [owner_fencing_token: 0],
          [owner_fencing_token: "invalid"],
          [now: -1],
          [timeout: 0],
          [timeout: :infinity],
          [:invalid]
        ] do
      assert {:error, {:checkpoint_store_erasure_conformance_failed, _phase, _code}} =
               ErasureConformance.run(nil, ref, opts)
    end

    assert {:error, {:checkpoint_store_erasure_conformance_failed, :options, :invalid_arguments}} =
             ErasureConformance.run(nil, ref, :invalid)

    assert {:error,
            {:checkpoint_store_erasure_conformance_failed, :configuration, :invalid_store}} =
             ErasureConformance.run(nil, ref)

    assert {:error,
            {:checkpoint_store_erasure_conformance_failed, :configuration, :invalid_store}} =
             ErasureConformance.run({ReplyStore, [:invalid]}, ref)

    assert {:error,
            {:checkpoint_store_erasure_conformance_failed, :configuration, :erasure_unsupported}} =
             ErasureConformance.run(String, ref)
  end

  defp request_attrs do
    [
      erasure_id: "erasure-value-contract",
      expected_revision: 3,
      checkpoint_digest: @digest,
      owner_fencing_token: 10,
      requested_at: 9
    ]
  end

  defp ref(label) do
    Ref.new(
      AgentRef.from_id("instance-erasure-value-contract"),
      Subject.new({label, System.unique_integer([:positive, :monotonic])})
    )
  end
end
