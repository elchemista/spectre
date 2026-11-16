Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.MindCallbackBoundaryTest do
  use Spectre.GAM.Test.GovernedBoundaryCase, async: false

  alias Spectre.GAM.{Candidate, Disclosure, Mind, SubmissionContext}
  alias Spectre.GAM.Domain.{Configuration, Command.Input, Sequencer.State}
  alias Spectre.GAM.Mind.{Derivation, Turn}
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule ReplyMind do
    def ref, do: "mind:boundary"

    def deliberate(_turn, opts) do
      case Keyword.get(opts, :fault) do
        :raise -> raise ArgumentError, "private provider response"
        :exit -> exit(:private_response)
        :throw -> throw(:private_response)
        _ -> Keyword.get(opts, :reply, {:ok, []})
      end
    end

    def deliberate(turn, _state, opts) do
      if Keyword.has_key?(opts, :fault),
        do: deliberate(turn, opts),
        else: Keyword.get(opts, :reply, :invalid)
    end
  end

  defmodule InvalidRef do
    def ref, do: nil
    def deliberate(_, _), do: {:ok, []}
  end

  defmodule FailedRef do
    def ref, do: raise("host details")
    def deliberate(_, _), do: {:ok, []}
  end

  setup c do
    {:ok, turn} =
      Turn.new(
        Fixture.context(c.f),
        "turn:mind-boundary",
        ReplyMind.ref(),
        [c.payment],
        Runtime.now()
      )

    %{turn: turn}
  end

  test "Mind callback failures remain explicit and do not leak exception messages", c do
    assert {:ok, []} = Mind.deliberate(ReplyMind, c.turn)

    for {fault, tag} <- [raise: ArgumentError, exit: :exit, throw: :throw] do
      assert {:error, {:mind_failed, ReplyMind, ^tag}} =
               Mind.deliberate(ReplyMind, c.turn, fault: fault)

      assert {:error, {:mind_failed, ReplyMind, ^tag}} =
               Mind.deliberate(ReplyMind, c.turn, %{}, fault: fault)
    end

    assert {:error, {:invalid_mind_result, ReplyMind}} =
             Mind.deliberate(ReplyMind, c.turn, reply: :invalid)

    assert {:error, {:invalid_stateful_mind_result, ReplyMind}} =
             Mind.deliberate(ReplyMind, c.turn, %{}, [])

    assert {:error, :provider_unavailable} =
             Mind.deliberate(ReplyMind, c.turn, %{}, reply: {:error, :provider_unavailable})

    assert {:error, :invalid_mind_deliberation} = Mind.deliberate(nil, c.turn)
    assert {:error, :invalid_stateful_mind_deliberation} = Mind.deliberate(nil, c.turn, %{}, [])
    assert {:error, :invalid_mind_candidate} = Mind.candidate(nil, %{})
    assert {:error, :invalid_mind_candidate} = Mind.candidate(nil, [], %{})
  end

  test "resolving an adapter requires a usable identity and the matching Turn", c do
    for module <- [nil, true, false, "string", String] do
      assert {:error, {:mind_unavailable, ^module}} = Mind.resolve(module)
    end

    assert {:error, {:invalid_mind_ref, InvalidRef}} = Mind.resolve(InvalidRef)
    assert {:error, {:mind_ref_failed, FailedRef}} = Mind.resolve(FailedRef)

    assert {:error, {:mind_turn_binding_mismatch, ReplyMind}} =
             Mind.deliberate(ReplyMind, %{c.turn | mind_ref: "another"})

    assert {:error, {:mind_unavailable, String}} = Mind.deliberate(String, c.turn)
    assert {:error, _} = Mind.deliberate(ReplyMind, c.turn, reply: {:ok, [c.candidate, %{}]})
  end

  test "a Mind cannot cite unseen Evidence or hide what its disclosure depends on", c do
    attrs = c.candidate |> Map.from_struct() |> Map.drop([:ref, :material_digest])

    assert {:ok, outside} =
             Candidate.new(%{attrs | evidence_refs: [c.payment.ref, "evidence:outside"]})

    assert {:error, {:mind_candidate_evidence_outside_turn, _}} =
             Mind.deliberate(ReplyMind, c.turn, reply: {:ok, outside})

    {:ok, disclosure} = Disclosure.new(%{c.candidate.disclosure | source_evidence_refs: []})
    assert {:ok, unbound} = Candidate.new(%{attrs | disclosure: disclosure})

    assert {:error, {:mind_candidate_disclosure_mismatch, _}} =
             Mind.deliberate(ReplyMind, c.turn, reply: {:ok, unbound})
  end

  test "Turn construction removes capabilities and rejects duplicates or malformed Evidence", c do
    assert c.turn.context.seal == nil
    assert Turn.context_bindings(c.turn) == SubmissionContext.evidence_bindings(c.turn.context)
    assert {:error, :invalid_mind_turn} = Turn.new(nil, "turn", "mind", [], 1)

    assert {:error, :duplicate_turn_evidence} =
             Turn.new(Fixture.context(c.f), "turn", "mind", [c.payment, c.payment], Runtime.now())

    assert {:error, _} = Turn.new(Fixture.context(c.f), "turn", "mind", [%{}], Runtime.now())

    assert {:error, :mind_turn_context_mismatch} =
             Turn.context(%{c.turn | context: Fixture.context(c.f)})

    assert {:error, _} =
             Turn.context(%{c.turn | context: %{c.turn.context | scope_ref: "changed"}})

    assert {:error, :invalid_turn_seal_material} = Turn.seal(nil, "secret")
    assert {:error, :turn_authentication_failed} = Turn.verify_seal(c.turn, "secret")
  end

  test "restored valid Turn seals do not waive Mind, time or immutable Evidence bindings", c do
    {:ok, config} = Configuration.new(c.f.sequencer_opts)
    state = %{State.new(config, c.attempted) | mind_ref: c.turn.mind_ref}
    context = Fixture.context(c.f)

    for {changed, reason} <- [
          {%{c.turn | mind_ref: "mind:another"}, :turn_mind_mismatch},
          {%{c.turn | opened_at: Runtime.now() + 1}, :turn_time_invalid},
          {%{c.turn | evidence: [%{c.payment | payload: "substitution"}]},
           :turn_evidence_mismatch}
        ] do
      {:ok, changed} = Turn.seal(changed, state.grant_secret)
      assert {:error, ^state, ^reason} = Input.continue_turn(state, context, changed, [])
    end

    assert Spectre.GAM.Domain.Sequencer.projection(c.f.server) === c.attempted
  end

  test "derived evidence is tied to this Turn and cannot be duplicated or masquerade as an observation",
       c do
    assert {:ok, derived} =
             Mind.evidence(c.turn, Runtime.now(), %{
               proposition: "refund-reason",
               payload: "Customer returned a damaged item"
             })

    assert {:ok, [^derived]} = Derivation.normalize(c.turn, derived)
    assert :ok = Derivation.validate(derived, c.turn, [c.payment])
    assert {:error, :duplicate_mind_derivation} = Derivation.normalize(c.turn, [derived, derived])
    assert {:error, _} = Derivation.normalize(c.turn, [%{}])
    assert {:error, :invalid_mind_derivations} = Derivation.normalize(nil, [])
    assert {:error, :invalid_mind_derivation} = Derivation.validate(nil, c.turn, [])
    assert {:error, :invalid_mind_evidence} = Mind.evidence(nil, 0, %{})
    attrs = c.candidate |> Map.from_struct() |> Map.drop([:ref, :material_digest])

    assert {:ok, disclosure} =
             Disclosure.new(%{c.candidate.disclosure | source_evidence_refs: [derived.ref]})

    attrs = attrs |> Map.take(Candidate.request_fields()) |> Map.drop([:scope_ref, :proposer_ref])

    assert {:ok, candidate} =
             Mind.candidate(c.turn, derived, %{
               attrs
               | disclosure: disclosure,
                 evidence_refs: [derived.ref]
             })

    assert candidate.evidence_refs == [derived.ref]
  end
end
