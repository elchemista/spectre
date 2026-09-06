defmodule Spectre.Core.ConsequenceContractBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.Consequence.Contract

  for {type, accepted, rejected} <- [
        {"binary", ["", <<0, 255>>], [nil, :text]},
        {"string", ["", "caffè"], [42, ~c"text"]},
        {"integer", [-1, 0, 1], [1.0, "1"]},
        {"non_negative_integer", [0, 1], [-1, 0.0]},
        {"positive_integer", [1, 100], [0, -1, 1.0]},
        {"float", [0.0, -1.5], [0, "1.5"]},
        {"number", [-1, 1.5], [nil, "1"]},
        {"boolean", [true, false], [0, :truth]},
        {"atom", [:ok, nil], ["ok", 1]},
        {"nil", [nil], [false, 0]},
        {"portable_scalar", [nil, true, :ok, 1, 1.5, "x"], [[], %{}]},
        {"ref", ["ref:a"], ["", 1, nil]},
        {"refs", [[], ["ref:a", "ref:b"]], [[""], [1], nil]},
        {"portable", [%{"x" => [1, :ok]}, {"x", 2}], []}
      ] do
    test "#{type} enforces its advertised scalar boundary through nested lists" do
      {:ok, contract} = Contract.new(shape: %{"items" => %{"$list" => unquote(type)}})
      assert :ok = Contract.validate(contract, %{"items" => unquote(Macro.escape(accepted))}, %{})

      for invalid <- unquote(Macro.escape(rejected)) do
        assert {:error, {:consequence_shape_mismatch, ["items", 1], _, _}} =
                 Contract.validate(
                   contract,
                   %{"items" => [unquote(Macro.escape(hd(accepted))), invalid]},
                   %{}
                 )
      end
    end
  end

  test "optional presence, nullable values and closed objects remain distinct" do
    {:ok, c} =
      Contract.new(
        shape: %{
          "required" => %{"$nullable" => "integer"},
          "optional" => %{"$optional" => "string"}
        }
      )

    assert :ok = Contract.validate(c, %{"required" => nil}, %{})
    assert :ok = Contract.validate(c, %{"required" => 3, "optional" => "yes"}, %{})

    assert {:error, {:consequence_shape_missing_keys, [], ["required"]}} =
             Contract.validate(c, %{}, %{})

    assert {:error, {:consequence_shape_unknown_keys, [], ["extra"]}} =
             Contract.validate(c, %{"required" => nil, "extra" => true}, %{})

    assert {:error, _} = Contract.validate(c, %{"required" => nil, "optional" => nil}, %{})
    assert {:error, _} = Contract.validate(c, nil, %{})
    {:ok, optional_root} = Contract.new(shape: %{"$optional" => "integer"})
    assert :ok = Contract.validate(optional_root, 2, %{})
    assert {:error, _} = Contract.validate(optional_root, nil, %{})
  end

  test "constant values compare canonical types, including inside containers" do
    for {expected, counterfeit} <- [{1, 1.0}, {%{"v" => 1}, %{"v" => 1.0}}, {[1, 2], [1.0, 2]}] do
      {:ok, c} = Contract.new(shape: %{"$const" => expected})
      assert :ok = Contract.validate(c, expected, %{})

      assert {:error, {:consequence_shape_mismatch, [], _, _}} =
               Contract.validate(c, counterfeit, %{})

      assert Contract.binding_kinds(c) == MapSet.new()
    end
  end

  for {type, field, value} <- [
        {"subject_ref", :subject_refs, "subject:a"},
        {"subject_refs", :subject_refs, ["subject:a"]},
        {"target_ref", :target_refs, "target:a"},
        {"target_refs", :target_refs, ["target:a"]},
        {"destination_ref", :destination_refs, "target:a"},
        {"destination_refs", :destination_refs, ["target:a"]}
      ] do
    test "#{type} binds exact endpoints and refuses missing or additional authority claims" do
      {:ok, c} = Contract.new(shape: %{"endpoint" => unquote(type)})
      value = unquote(Macro.escape(value))
      field = unquote(field)
      boundary = boundary(field, value)

      assert :ok = Contract.validate(c, %{"endpoint" => value}, boundary)

      assert {:error, {:consequence_binding_mismatch, _, _, _}} =
               Contract.validate(c, %{"endpoint" => value}, %{})

      assert {:error, {:consequence_binding_mismatch, _, _, _}} =
               Contract.validate(
                 c,
                 %{"endpoint" => value},
                 Map.update!(boundary, field, &["other" | &1])
               )

      assert {:error, _} = Contract.validate(c, %{"endpoint" => 1}, boundary)
      refute MapSet.size(Contract.binding_kinds(c)) == 0
    end
  end

  test "meter binding cannot be duplicated or replaced by a numerically equal float" do
    {:ok, c} = Contract.new(shape: %{"cost" => "meter_requests"})

    assert :ok =
             Contract.validate(c, %{"cost" => %{"meter:a" => 1}}, %{
               meter_requests: %{"meter:a" => 1}
             })

    assert {:error, {:consequence_meter_binding_mismatch, _, _}} =
             Contract.validate(c, %{"cost" => %{"meter:a" => 1}}, %{
               meter_requests: %{"meter:a" => 1.0}
             })

    for cost <- [%{"meter:a" => 0}, %{"meter:a" => 1.0}, %{a: 1}, [], nil] do
      assert {:error, _} = Contract.validate(c, %{"cost" => cost}, %{})
    end

    {:ok, duplicated} = Contract.new(shape: %{"a" => "meter_requests", "b" => "meter_requests"})

    assert {:error, {:duplicate_consequence_meter_binding, ["b"]}} =
             Contract.validate(duplicated, %{"a" => %{}, "b" => %{}}, %{})

    assert Contract.binding_kinds(c) == MapSet.new([:meter])
  end

  test "malformed schemas and wrapper collisions fail before a contract can be published" do
    for shape <- [
          nil,
          42,
          "pid",
          %{atom: "integer"},
          %{"" => "integer"},
          %{"nested" => "unknown"},
          %{"$list" => "integer", "extra" => "integer"}
        ] do
      assert {:error, _} = Contract.new(shape: shape)
    end

    assert {:error, _} = Contract.new(shape: "integer", schema_version: 2)
    assert {:error, :invalid_consequence_contract} = Contract.validate(nil, 1, %{})
  end

  test "list contracts reject improper lists without crashing the caller" do
    {:ok, c} = Contract.new(shape: %{"$list" => "integer"})
    assert {:error, _} = Contract.validate(c, [1 | :not_a_list], %{})
    assert {:error, _} = Contract.validate(c, "not a list", %{})
    {:ok, portable} = Contract.new(shape: "portable")
    assert {:error, _} = Contract.validate(portable, self(), %{})
  end

  defp boundary(:destination_refs, value),
    do: %{destination_refs: List.wrap(value), target_refs: List.wrap(value)}

  defp boundary(field, value), do: %{field => List.wrap(value)}
end
