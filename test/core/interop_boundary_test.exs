defmodule Spectre.InteropBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false
  alias Spectre.{Candidate, Evidence, Interop}

  test "exchange requires exactly the Candidate's Evidence closure", c do
    assert {:ok, envelope} =
             Interop.outbound(c.f.refs.domain, "domain:peer", c.candidate, [c.payment])

    assert {:ok, contents} = Interop.inbound(envelope, "domain:peer")
    assert contents.candidate == c.candidate
    assert contents.evidence == [c.payment]

    assert {:error, {:interop_candidate_evidence_missing, [_]}} =
             Interop.outbound(c.f.refs.domain, "domain:peer", c.candidate, [])

    assert {:error, :duplicate_interop_evidence} =
             Interop.outbound(c.f.refs.domain, "domain:peer", c.candidate, [c.payment, c.payment])

    assert {:error, _} = Interop.outbound(c.f.refs.domain, "domain:peer", c.candidate, [%{}])

    assert {:error, :invalid_interop_envelope} =
             Interop.outbound(c.f.refs.domain, "domain:peer", c.candidate, nil)

    assert {:error, :invalid_interop_envelope} = Interop.inbound(nil, "domain:peer")

    assert {:error, :invalid_interop_evidence} =
             Interop.inbound(%{envelope | "evidence" => nil}, "domain:peer")

    assert {:error, _} = Interop.inbound(%{envelope | "evidence" => [%{}]}, "domain:peer")
  end

  test "a portable self-contained lineage still cannot derive from a future fact", c do
    {:ok, parent} = Evidence.new(%{c.payment | ref: nil, observed_at: c.payment.observed_at + 1})

    {:ok, child} =
      Evidence.new(%{c.payment | ref: nil, provenance: :derived, parent_refs: [parent.ref]})

    {:ok, candidate} =
      Candidate.new(%{
        c.candidate
        | ref: nil,
          material_digest: nil,
          evidence_refs: [child.ref],
          disclosure: %{c.candidate.disclosure | source_evidence_refs: [child.ref]}
      })

    assert {:error, {:interop_evidence_parent_from_future, _, _}} =
             Interop.outbound(c.f.refs.domain, "domain:peer", candidate, [parent, child])
  end
end
