defmodule Spectre.Agents.RequestBuilderBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.Agent.{RequestBuilder, Turn}
  alias Spectre.Candidate
  alias Spectre.GovernedAct.State
  alias Spectre.Mind.Turn, as: MindTurn
  alias Spectre.V04Test.{Fixture, Runtime}

  defmodule RequestAdapter do
    def prepare(_, _, _, opts) do
      if opts[:raise], do: raise(ArgumentError, "private prompt")
      Keyword.fetch!(opts, :reply)
    end
  end

  setup c do
    {:ok, mind_turn} =
      MindTurn.new(
        Fixture.context(c.f),
        "turn:builder",
        "mind:builder",
        [c.payment],
        Runtime.now()
      )

    turn = %Turn{
      ref: mind_turn.ref,
      input: "Please refund the damaged order",
      flow: :support,
      owner: "",
      definition_ref: "definition:builder",
      mind_turn: mind_turn
    }

    fixed =
      c.candidate
      |> Map.from_struct()
      |> Map.take(Candidate.request_fields())
      |> Map.drop([:identity_key, :row, :scope_ref, :proposer_ref, :consequence, :class])

    owner = %{prefix: "", plan: %{requests: %{}, asks: %{}, settings: %{}}}

    runtime = %{
      wiring: %{ports: %{}},
      bindings: %{c.candidate.class => fixed},
      surface: State.surface(c.before)
    }

    %{turn: turn, owner: owner, runtime: runtime}
  end

  test "default request preparation does not invent a class or template", c do
    assert {:error, {:unknown_request_template, :missing}} =
             RequestBuilder.prepare({:request, :missing}, %{}, c.turn, [])

    for kind <- [:request, :ask, :classify] do
      assert {:error, {:request_class_required, ^kind, "unknown"}} =
               RequestBuilder.prepare({kind, "unknown"}, %{}, c.turn, [])
    end

    assert {:error, :invalid_handler_request} =
             RequestBuilder.prepare({:execute, "app"}, %{}, c.turn, [])

    assert {:ok, candidate} = build(c)
    assert candidate.class == c.candidate.class
    assert candidate.row == c.candidate.row
    assert candidate.proposer_ref == c.f.refs.proposer
    assert candidate.scope_ref == c.f.refs.scope
    assert candidate.identity_key == "request:builder"
  end

  test "request adapters cannot return a successful non-map or escape error isolation", c do
    for {reply, expected} <- [
          {{:error, :cannot_prepare}, :cannot_prepare},
          {:invalid, :invalid_request_adapter_reply}
        ] do
      runtime = adapter(c.runtime, c.candidate.class, reply: reply)
      assert {:error, ^expected} = build(%{c | runtime: runtime})
    end

    runtime = adapter(c.runtime, c.candidate.class, raise: true)

    assert {:error, {:adapter_callback_exception, RequestAdapter, :prepare, ArgumentError}} =
             build(%{c | runtime: runtime})
  end

  test "neither an adapter nor host binding may replace identity, Row or fixed authority fields",
       c do
    base = %{class: c.candidate.class, consequence: c.candidate.consequence}

    for {field, value} <- [identity_key: "forged", row: %{read: true}] do
      runtime = adapter(c.runtime, c.candidate.class, reply: {:ok, Map.put(base, field, value)})
      assert {:error, {:reserved_request_field, ^field}} = build(%{c | runtime: runtime})
    end

    runtime =
      adapter(c.runtime, c.candidate.class,
        reply: {:ok, Map.put(base, :accountable_ref, "attacker")}
      )

    assert {:error, {:request_binding_conflict, :accountable_ref}} =
             build(%{c | runtime: runtime})

    runtime = c.runtime

    assert {:error, {:reserved_request_field, :consequence}} =
             build(%{c | runtime: put_in(runtime.bindings[c.candidate.class][:consequence], %{})})
  end

  test "low-level Candidates must be exactly rebound to the sealed Turn", c do
    assert {:ok, candidate} = build(c)
    assert {:ok, ^candidate} = RequestBuilder.low_level(candidate, c.turn)

    assert {:ok, changed} =
             Candidate.new(%{candidate | ref: nil, material_digest: nil, proposer_ref: "foreign"})

    assert {:error, :candidate_turn_mismatch} = RequestBuilder.low_level(changed, c.turn)
    assert {:error, _} = RequestBuilder.low_level(%{}, c.turn)
  end

  test "meter template names are explicit, unique references, not positional quantities" do
    assert {:ok, template} =
             RequestBuilder.template(meter: [budget: "meter:requests", tokens: "meter:tokens"])

    assert template["meter"] == %{"budget" => "meter:requests", "tokens" => "meter:tokens"}

    for value <- [nil, [1], [budget: "one", budget: "two"], %{1 => "meter"}, %{budget: nil}] do
      assert {:error, :invalid_request_meter_bindings} = RequestBuilder.template(meter: value)
    end
  end

  defp build(c),
    do:
      RequestBuilder.build(
        {:request, c.candidate.class},
        c.candidate.consequence,
        c.turn,
        c.owner,
        c.runtime,
        "request:builder"
      )

  defp adapter(runtime, name, opts),
    do: put_in(runtime.wiring.ports["request/" <> name], {RequestAdapter, opts})
end
