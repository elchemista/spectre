defmodule SpectreFlowConstraintContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Flow.Constraint
  alias Spectre.Input
  alias Spectre.Input.Source
  alias Spectre.Rule

  test "input sources normalize valid attributes and reject invalid boundaries" do
    source = Source.new(kind: :telegram, mount: :support)

    assert Source.new(source) == source

    assert_raise ArgumentError, ~r/kind/, fn ->
      Source.new(%{kind: "", mount: :support})
    end

    assert_raise ArgumentError, ~r/metadata/, fn ->
      Source.new(%{kind: :telegram, mount: :support, metadata: []})
    end
  end

  test "constructor normalizes source constraints and rejects malformed contracts" do
    constraint =
      Constraint.new(
        namespace: :telegram,
        values: :support,
        metadata: %{origin: :agent}
      )

    assert constraint == %Constraint{
             namespace: :telegram,
             kind: :source,
             values: [:support],
             mode: :any,
             metadata: %{origin: :agent}
           }

    assert Constraint.new(constraint) == constraint

    assert %Constraint{namespace: "telegram", mode: :all} =
             Constraint.new(%{namespace: "telegram", values: ["support"], mode: :all})

    for {attrs, message} <- [
          {[namespace: nil, values: [:support]], "namespace"},
          {[namespace: "", values: [:support]], "namespace"},
          {[namespace: 7, values: [:support]], "namespace"},
          {[namespace: :telegram, values: [:support], mode: :some], "mode"},
          {[namespace: :telegram, values: []], "values"},
          {[namespace: :telegram, values: [:support], metadata: []], "metadata"}
        ] do
      assert_raise ArgumentError, ~r/#{message}/, fn -> Constraint.new(attrs) end
    end
  end

  test "source matching is explicit while non-source constraints remain routing-neutral" do
    input = input(:telegram, :support)
    no_source = %Input{text: "status", source: nil}
    any = Constraint.new(namespace: "telegram", values: ["support", "other"])
    all_one = Constraint.new(namespace: :telegram, values: [:support], mode: :all)
    all_many = Constraint.new(namespace: :telegram, values: [:support, :other], mode: :all)
    wrong_namespace = Constraint.new(namespace: :whatsapp, values: [:support])
    inference = Constraint.new(namespace: :prism, kind: :inference, values: [:deep])

    assert Constraint.match?([], input)
    assert Constraint.match?([inference], input)
    assert Constraint.match?([any], input)
    assert Constraint.match?([all_one], input)
    refute Constraint.match?([all_many], input)
    refute Constraint.match?([wrong_namespace], input)
    refute Constraint.match?([any], no_source)
  end

  test "filtering rejects incompatible rules and preserves deterministic precedence" do
    input = input(:telegram, :support)
    matching = Constraint.new(namespace: :telegram, values: [:support])
    incompatible = Constraint.new(namespace: :whatsapp, values: [:support])
    inference = Constraint.new(namespace: :prism, kind: :inference, values: [:deep])

    ordinary_open = %Rule{label: :ordinary_open, constraints: []}
    global_open = %Rule{label: :global_open, constraints: [], global?: true}
    ordinary_specific = %Rule{label: :ordinary_specific, constraints: [matching]}
    global_specific = %Rule{label: :global_specific, constraints: [matching], global?: true}
    neutral = %Rule{label: :neutral, constraints: [inference]}
    rejected = %Rule{label: :rejected, constraints: [incompatible], global?: true}

    assert [
             %Rule{label: :global_specific},
             %Rule{label: :global_open},
             %Rule{label: :ordinary_specific},
             %Rule{label: :ordinary_open},
             %Rule{label: :neutral}
           ] =
             Constraint.filter_and_order(
               [
                 ordinary_open,
                 global_open,
                 ordinary_specific,
                 global_specific,
                 neutral,
                 rejected
               ],
               input
             )
  end

  defp input(kind, mount) do
    %Input{text: "status", source: Source.new(kind: kind, mount: mount)}
  end
end
