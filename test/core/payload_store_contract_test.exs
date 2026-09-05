defmodule Spectre.Core.PayloadStoreContractTest do
  use ExUnit.Case, async: true

  alias Spectre.{Attempt, Erasure, Evidence, Outcome, Portable}
  alias Spectre.Erasure.Analysis
  alias Spectre.GovernedAct.State
  alias Spectre.Payload.Store

  defmodule HostStore do
    @behaviour Spectre.Payload.Store

    @impl true
    def verify(ref, opts) do
      send(Keyword.fetch!(opts, :observer), {:verify_payload, ref})

      case Keyword.get(opts, :behavior, :lookup) do
        :raise -> raise "private storage credentials"
        :throw -> throw({:secret, "private storage credentials"})
        :exit -> exit({:secret, "private storage credentials"})
        {:return, value} -> value
        :lookup -> lookup(Keyword.fetch!(opts, :table), ref)
      end
    end

    defp lookup(table, ref) do
      case :ets.lookup(table, ref) do
        [] ->
          {:error, :not_found}

        [{^ref, value}] ->
          if Portable.content_ref!(:payload, value) == ref,
            do: :ok,
            else: {:error, :digest_mismatch}
      end
    end
  end

  setup do
    value = %{"receipt" => "order paid"}
    ref = Portable.content_ref!(:payload, value)
    table = :ets.new(__MODULE__, [:set, :public])
    :ets.insert(table, {ref, value})
    config = {HostStore, table: table, observer: self()}
    evidence = evidence(ref)
    state = %{State.new("domain") | evidence: %{evidence.ref => evidence}}
    %{value: value, ref: ref, table: table, config: config, state: state, evidence: evidence}
  end

  test "an optional store is unnecessary when history contains only inline payloads" do
    {:ok, inline} = Evidence.new(evidence_attrs(%{payload: %{"text" => "hello"}}))
    state = %{State.new("domain") | evidence: %{inline.ref => inline}}
    assert Store.normalize(nil) == {:ok, nil}
    assert Store.verify_live_references(nil, state) == :ok
  end

  test "an external reference requires a host verifier", c do
    assert Store.verify(nil, c.ref) == {:error, {:payload_store_required, c.ref}}

    assert Store.verify_live_references(nil, c.state) ==
             {:error, {:payload_store_required, c.ref}}
  end

  test "adapter options are retained without being executed during normalization", c do
    assert Store.normalize(c.config) == {:ok, c.config}
    assert Store.normalize(HostStore) == {:ok, {HostStore, []}}
    refute_received {:verify_payload, _}
  end

  test "a module without the verification callback is rejected" do
    assert Store.normalize(__MODULE__) == {:error, {:payload_store_unavailable, __MODULE__}}
  end

  test "non-keyword options and malformed adapter configurations are rejected" do
    assert Store.normalize({HostStore, ["secret"]}) == {:error, :invalid_payload_store_options}

    for config <- [{HostStore, %{}}, {nil, []}, "host", %{}, []] do
      assert Store.normalize(config) == {:error, :invalid_payload_store}
    end
  end

  test "invalid content addresses never reach the host adapter", c do
    for ref <- [
          nil,
          7,
          "",
          "payload:short",
          "other:" <> Portable.digest!("x"),
          "payload:" <> String.duplicate("A", 64)
        ] do
      assert Store.verify(c.config, ref) == {:error, {:invalid_payload_ref, ref}}
    end

    refute_received {:verify_payload, _}
  end

  test "successful verification checks the stored value against its content address", c do
    assert Store.verify(c.config, c.ref) == :ok
    assert_receive {:verify_payload, ref}
    assert ref == c.ref
  end

  test "a missing payload is distinguished from an adapter failure", c do
    :ets.delete(c.table, c.ref)
    assert Store.verify(c.config, c.ref) == {:error, {:payload_not_found, c.ref}}
  end

  test "corrupt bytes under a valid key fail digest verification", c do
    :ets.insert(c.table, {c.ref, %{"receipt" => "forged"}})

    assert Store.verify(c.config, c.ref) ==
             {:error, {:payload_verification_failed, c.ref, :digest_mismatch}}
  end

  test "host errors remain explicit instead of becoming missing data", c do
    config = {HostStore, observer: self(), behavior: {:return, {:error, :storage_offline}}}

    assert Store.verify(config, c.ref) ==
             {:error, {:payload_verification_failed, c.ref, :storage_offline}}
  end

  test "a malformed adapter success cannot authorize payload use", c do
    for value <- [true, nil, {:ok, c.value}, {:ok, :ok}] do
      config = {HostStore, observer: self(), behavior: {:return, value}}

      assert Store.verify(config, c.ref) ==
               {:error, {:invalid_payload_store_response, HostStore}}
    end
  end

  test "adapter exceptions omit private exception messages", c do
    config = {HostStore, observer: self(), behavior: :raise}

    assert Store.verify(config, c.ref) ==
             {:error, {:payload_store_exception, HostStore, RuntimeError}}
  end

  for kind <- [:throw, :exit] do
    test "adapter #{kind} is contained without its private reason", c do
      config = {HostStore, observer: self(), behavior: unquote(kind)}

      assert Store.verify(config, c.ref) ==
               {:error, {:payload_store_failure, HostStore, unquote(kind)}}

      assert Process.alive?(self())
    end
  end

  test "recovery reports unexplained disappearance, not an erasure", c do
    :ets.delete(c.table, c.ref)

    assert Store.verify_live_references(c.config, c.state) ==
             {:error, {:unexpected_missing_payload, c.ref}}
  end

  test "point-of-use verification detects removal after successful admission checks", c do
    assert Store.verify_new_references(c.config, c.state, [c.ref]) == :ok
    :ets.delete(c.table, c.ref)

    assert Store.verify_usable(c.config, c.state, [c.ref]) ==
             {:error, {:payload_not_found, c.ref}}
  end

  test "point-of-use verification detects content replacement after recovery", c do
    assert Store.verify_live_references(c.config, c.state) == :ok
    :ets.insert(c.table, {c.ref, "corrupt"})

    assert Store.verify_usable(c.config, c.state, [c.ref]) ==
             {:error, {:payload_verification_failed, c.ref, :digest_mismatch}}
  end

  test "shared references are verified once per operation, not cached across operations", c do
    other = evidence(c.ref, "another claim")
    state = %{c.state | evidence: Map.put(c.state.evidence, other.ref, other)}

    for operation <- [
          fn -> Store.verify_live_references(c.config, state) end,
          fn -> Store.verify_usable(c.config, state, [c.ref, c.ref]) end,
          fn -> Store.verify_new_references(c.config, state, [c.ref, c.ref]) end
        ] do
      assert operation.() == :ok
      assert_receive {:verify_payload, _}
      refute_received {:verify_payload, _}
    end
  end

  test "an invalid read model cannot silently skip verification", c do
    assert Store.verify_live_references(c.config, %{}) == {:error, :invalid_payload_projection}
    assert Store.verify_usable(c.config, %{}, [c.ref]) == {:error, :invalid_payload_use}

    assert Store.verify_new_references(c.config, %{}, [c.ref]) ==
             {:error, :invalid_new_payload_references}
  end

  test "only payload-bearing ledger events introduce content addresses", c do
    events = [
      %{"type" => "evidence_recorded", "data" => %{"payload_ref" => c.ref}},
      %{"type" => "presentation_recorded", "data" => %{"rendered_payload_ref" => c.ref}},
      %{"type" => "evidence_recorded", "data" => %{"payload_ref" => nil}},
      %{"type" => "act_committed", "data" => %{"payload_ref" => "untrusted"}}
    ]

    assert Store.introduced_refs(events) == [c.ref]
  end

  test "evidence reference lookup ignores inline and absent evidence and deduplicates", c do
    other = evidence(c.ref, "another claim")
    state = %{c.state | evidence: Map.put(c.state.evidence, other.ref, other)}
    assert Store.evidence_payload_refs([other.ref, "missing", c.evidence.ref], state) == [c.ref]
  end

  # These are typed historical prefixes for the erasure algebra, not forged
  # admission histories. End-to-end tests separately verify the ledger fold.
  test "authorizing erasure alone cannot excuse missing bytes", c do
    state = erasure_state(c, :unattempted)
    assert Analysis.execution_state(state, c.ref) == {:ok, :live}

    assert {:error, {:erasure_target_already_requested, _, _}} =
             Analysis.requestable?(state, c.ref)

    :ets.delete(c.table, c.ref)

    assert Store.verify_live_references(c.config, state) ==
             {:error, {:unexpected_missing_payload, c.ref}}
  end

  for status <- [:pending, :ambiguous, :failed] do
    test "#{status} erasure justifies absence but prevents use and resurrection", c do
      state = erasure_state(c, unquote(status))
      :ets.delete(c.table, c.ref)
      assert Analysis.execution_state(state, c.ref) == {:ok, :possibly_absent}
      assert Store.verify_live_references(c.config, state) == :ok

      assert Store.verify_usable(c.config, state, [c.ref]) ==
               {:error, {:payload_temporarily_unavailable, c.ref}}

      :ets.insert(c.table, {c.ref, c.value})

      assert Store.verify_new_references(c.config, state, [c.ref]) ==
               {:error, {:payload_reference_retired, c.ref, :possibly_absent}}

      refute_received {:verify_payload, _}
    end
  end

  test "successful erasure remains retired even if the host restores the same bytes", c do
    state = erasure_state(c, :succeeded)
    assert Analysis.execution_state(state, c.ref) == {:ok, :erased}
    assert Store.verify_live_references(nil, state) == :ok

    assert Store.verify_usable(c.config, state, [c.ref]) ==
             {:error, {:payload_redacted, c.ref}}

    assert Store.verify_new_references(c.config, state, [c.ref]) ==
             {:error, {:payload_reference_retired, c.ref, :erased}}

    refute_received {:verify_payload, _}
  end

  test "definitive no-effect permits reuse but still requires actual bytes", c do
    state = erasure_state(c, :definitive_no_effect)
    assert Analysis.execution_state(state, c.ref) == {:ok, :live}
    assert Analysis.requestable?(state, c.ref) == :ok
    assert Store.verify_new_references(c.config, state, [c.ref]) == :ok
    :ets.delete(c.table, c.ref)

    assert Store.verify_live_references(c.config, state) ==
             {:error, {:unexpected_missing_payload, c.ref}}
  end

  test "cancellation before Attempt permits a new request without claiming deletion", c do
    state = erasure_state(c, :unattempted)
    [erasure] = Map.values(state.erasures)
    state = %{state | terminal_dispatches: %{erasure.source_act_ref => {:cancelled, "cancel"}}}
    assert Analysis.execution_state(state, c.ref) == {:ok, :live}
    assert Analysis.requestable?(state, c.ref) == :ok
    assert Store.verify_usable(c.config, state, [c.ref]) == :ok
  end

  for correction <- [:succeeded, :failed] do
    test "late #{correction} correcting no-effect retires the reference again", c do
      state = erasure_state(c, :definitive_no_effect)
      [prior] = Map.values(state.outcomes)

      {:ok, corrected} =
        Outcome.new(%{
          act_ref: prior.act_ref,
          attempt_ref: prior.attempt_ref,
          status: unquote(correction),
          evidence_refs: ["evidence:late"],
          observed_at: 120,
          details_ref: "details:late",
          contradicts_outcome_ref: prior.ref
        })

      state = %{state | outcomes: Map.put(state.outcomes, corrected.ref, corrected)}
      expected = if unquote(correction) == :succeeded, do: :erased, else: :possibly_absent
      assert Analysis.execution_state(state, c.ref) == {:ok, expected}

      assert Store.verify_new_references(c.config, state, [c.ref]) ==
               {:error, {:payload_reference_retired, c.ref, expected}}
    end
  end

  test "erasing one payload never excuses loss of an unrelated payload", c do
    other_ref = Portable.content_ref!(:payload, "another receipt")
    other = evidence(other_ref, "another claim")
    state = erasure_state(c, :succeeded)
    state = %{state | evidence: Map.put(state.evidence, other.ref, other)}

    assert Store.verify_live_references(c.config, state) ==
             {:error, {:unexpected_missing_payload, other_ref}}

    assert Store.verify_usable(c.config, state, [other_ref]) ==
             {:error, {:payload_not_found, other_ref}}
  end

  defp evidence(ref, proposition \\ "paid") do
    {:ok, evidence} = Evidence.new(evidence_attrs(%{payload_ref: ref, proposition: proposition}))
    evidence
  end

  defp evidence_attrs(attrs) do
    Map.merge(
      %{
        proposition: "paid",
        issuer_ref: "issuer",
        source_ref: "source",
        provenance: :observed,
        observed_at: 100,
        labels: [],
        bindings: %{}
      },
      attrs
    )
  end

  defp erasure_state(c, status) do
    "payload:" <> digest = c.ref

    {:ok, erasure} =
      Erasure.new(%{
        source_act_ref: "act:erase",
        target_ref: c.ref,
        target_digest: digest,
        affected_refs: [c.evidence.ref],
        reason: "requested deletion",
        reduces_verifiability: true,
        requested_at: 100
      })

    state = %{c.state | erasures: %{erasure.ref => erasure}}
    if status == :unattempted, do: state, else: attempted_state(state, status)
  end

  defp attempted_state(state, status) do
    {:ok, attempt} =
      Attempt.new(%{
        ref: "01900000-0000-7000-8000-000000000001",
        act_ref: "act:erase",
        executor_ref: "executor",
        material_digest: Portable.digest!("erase"),
        generation: 1,
        grant_nonce_digest: Portable.digest!("nonce"),
        started_at: 101
      })

    state = %{state | attempts: %{attempt.ref => attempt}}

    if status == :pending do
      state
    else
      {:ok, outcome} =
        Outcome.new(%{
          act_ref: attempt.act_ref,
          attempt_ref: attempt.ref,
          status: status,
          evidence_refs: ["evidence:outcome"],
          observed_at: 110,
          details_ref: "details:outcome"
        })

      %{state | outcomes: %{outcome.ref => outcome}}
    end
  end
end
