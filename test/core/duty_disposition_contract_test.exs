defmodule Spectre.Core.DutyDispositionContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Duty
  alias Spectre.Duty.Disposition
  alias Spectre.Portable

  setup do
    attrs = %{
      class: "app.review",
      cause_key: {:review, "case", 1},
      accountable: "owner",
      evidence_refs: ["evidence:original"],
      missing: [%{"receipt" => 1}],
      containment: %{"maximum" => 1},
      closing_conditions: [%{"revision" => 1}],
      disposition_authority_refs: ["reviewer"],
      opened_at: 100
    }

    {:ok, duty} = Duty.new(attrs)
    {:ok, disposition} = Disposition.for_duty(duty, :accept_loss, ["evidence:review"], :settle)
    %{attrs: attrs, duty: duty, disposition: disposition}
  end

  test "disposition binds the exact opening and leaves the source Duty untouched", c do
    assert c.disposition.duty_ref == c.duty.ref
    assert c.disposition.opening_digest == Duty.digest(c.duty)
    assert c.disposition.cause_key === c.duty.cause_key
    assert c.duty.status == :open
    assert c.duty.disposition_act_ref == nil
  end

  test "every discretionary kind is explicit; mechanical condition closure is distinct", c do
    for kind <- [:ratify, :repudiate, :compensate, :assign, :accept_loss] do
      assert {:ok, disposition} = Disposition.for_duty(c.duty, kind, ["proof"])
      assert Disposition.discretionary?(disposition)
      assert disposition.meter_resolution == :none
    end

    assert {:ok, mechanical} = Disposition.for_duty(c.duty, :condition_met, ["proof"])
    refute Disposition.discretionary?(mechanical)
  end

  test "settlement and release remain different signed material", c do
    {:ok, settle} = Disposition.for_duty(c.duty, :accept_loss, ["proof"], :settle)
    {:ok, release} = Disposition.for_duty(c.duty, :repudiate, ["proof"], :release)

    refute Portable.digest!(Disposition.canonical(settle)) ==
             Portable.digest!(Disposition.canonical(release))

    assert settle.opening_digest == release.opening_digest
  end

  test "canonical disposition and its single-effect consequence round-trip exactly", c do
    canonical = Disposition.canonical(c.disposition)
    assert {:ok, restored} = Disposition.from_canonical(canonical)
    assert restored === c.disposition
    assert Disposition.from_consequence(Disposition.consequence(c.disposition)) == {:ok, restored}
  end

  test "support is a canonical set, never extra votes from repeated refs", c do
    assert {:ok, disposition} = Disposition.for_duty(c.duty, :ratify, ["z", "a", "z"])
    assert disposition.supporting_refs == ["a", "z"]
  end

  test "empty supporting evidence cannot manufacture a disposition", c do
    assert Disposition.for_duty(c.duty, :ratify, []) ==
             {:error, :duty_disposition_supporting_refs_required}
  end

  test "non-reference support cannot smuggle executable values", c do
    for supporting <- [[self()], [fn -> :close end], [""], [%{"approved" => true}]] do
      assert {:error, _} = Disposition.for_duty(c.duty, :ratify, supporting)
    end
  end

  test "a disposed Duty cannot be disposed again using the constructor", c do
    {:ok, disposed} =
      Duty.new(
        %{c.attrs | opened_at: 100}
        |> Map.merge(%{status: :disposed, disposition_act_ref: "act:closure"})
      )

    assert Disposition.for_duty(disposed, :ratify, ["proof"]) ==
             {:error, {:duty_not_open, disposed.ref}}
  end

  test "a malformed open Duty cannot bypass constructor revalidation", c do
    assert Disposition.for_duty(%{c.duty | disposition_act_ref: "act:already"}, :ratify, ["proof"]) ==
             {:error, :open_duty_has_disposition_act}
  end

  test "a canonical map must be decoded explicitly before for_duty", c do
    assert Disposition.for_duty(Duty.canonical(c.duty), :ratify, ["proof"]) ==
             {:error, :invalid_duty_disposition_source}
  end

  test "unknown schema versions cannot reinterpret a closure", c do
    for version <- [0, 2, 1.0, "1"] do
      assert {:error, {:unsupported_duty_disposition_schema_version, ^version}} =
               update_disposition(c.disposition, schema_version: version)
    end
  end

  test "unknown disposition verbs are not discretionary authority", c do
    for kind <- [:close, :expire, :delete, "ratify", nil] do
      assert {:error, {:invalid_duty_disposition_kind, ^kind}} =
               update_disposition(c.disposition, kind: kind)
    end
  end

  test "invalid Meter resolution cannot imply release", c do
    for resolution <- [:automatic, :refund, "release", nil] do
      assert {:error, {:invalid_duty_meter_resolution, ^resolution}} =
               update_disposition(c.disposition, meter_resolution: resolution)
    end
  end

  test "the opening digest must be a canonical SHA256 value", c do
    for digest <- [nil, "", "opening", String.duplicate("A", 64), String.duplicate("a", 63)] do
      assert {:error, {:invalid_duty_opening_digest, ^digest}} =
               update_disposition(c.disposition, opening_digest: digest)
    end
  end

  test "the cause cannot be missing or carry process-local authority", c do
    assert update_disposition(c.disposition, cause_key: nil) ==
             {:error, :missing_duty_disposition_cause_key}

    for cause <- [self(), make_ref(), fn -> :approved end] do
      assert {:error, _} = update_disposition(c.disposition, cause_key: cause)
    end
  end

  test "a disposition consequence cannot carry a second effect", c do
    extra = Map.put(Disposition.consequence(c.disposition), "grant", "self-authorized")
    assert Disposition.from_consequence(extra) == {:error, :invalid_duty_disposition_consequence}
  end

  test "canonical decoding does not silently deduplicate malformed support", c do
    canonical = Disposition.canonical(c.disposition)
    repeated = Map.put(canonical, "supporting_refs", ["proof", "proof"])
    assert {:error, _} = Disposition.from_canonical(repeated)
  end

  test "closed schema rejects hidden authority fields", c do
    attrs = Map.put(Map.from_struct(c.disposition), :approved_by, "self")

    assert {:error, {:unknown_attribute, :duty_disposition, :approved_by}} =
             Disposition.new(attrs)
  end

  test "Duty identity is causal while its opening digest binds the complete obligation", c do
    {:ok, changed} = Duty.new(%{c.attrs | containment: %{"maximum" => 2}})
    assert changed.ref == c.duty.ref
    refute Duty.digest(changed) == Duty.digest(c.duty)
    {:ok, next} = Disposition.for_duty(changed, :accept_loss, ["proof"])
    refute next.opening_digest == c.disposition.opening_digest
  end

  test "a disposed projection preserves its original causal content", c do
    {:ok, disposed} =
      Duty.new(Map.merge(c.attrs, %{status: :disposed, disposition_act_ref: "act:closure"}))

    assert disposed.ref == c.duty.ref
    assert Duty.same_cause?(disposed, c.duty)
    refute Duty.digest(disposed) == Duty.digest(c.duty)
  end

  for {field, changed} <- [
        {:missing, [%{"receipt" => 1.0}]},
        {:containment, %{"maximum" => 1.0}},
        {:closing_conditions, [%{"revision" => 1.0}]}
      ] do
    test "same_cause cannot conflate distinct canonical #{field}", c do
      {:ok, changed} = Duty.new(Map.put(c.attrs, unquote(field), unquote(Macro.escape(changed))))
      assert changed.ref == c.duty.ref
      refute Duty.digest(changed) == Duty.digest(c.duty)
      refute Duty.same_cause?(changed, c.duty)
    end
  end

  test "missing accountable conflict is rejected even with a named reviewer", c do
    assert Duty.new(Map.put(c.attrs, :conflict_refs, ["reviewer"])) ==
             {:error, :duty_accountable_conflict_required}
  end

  test "a Duty cannot point at an Attempt without its causal Act", c do
    assert Duty.new(Map.put(c.attrs, :attempt_ref, "attempt")) ==
             {:error, :duty_attempt_without_act}
  end

  test "disposed status requires a durable disposition Act ref", c do
    assert Duty.new(Map.put(c.attrs, :status, :disposed)) ==
             {:error, :disposed_duty_missing_disposition_act}
  end

  test "distinct causal keys never share a Duty identity", c do
    {:ok, changed} = Duty.new(%{c.attrs | cause_key: {:review, "case", 1.0}})
    refute changed.ref == c.duty.ref
    refute Duty.same_cause?(changed, c.duty)
  end

  defp update_disposition(disposition, changes),
    do: disposition |> Map.from_struct() |> Map.merge(Map.new(changes)) |> Disposition.new()
end
