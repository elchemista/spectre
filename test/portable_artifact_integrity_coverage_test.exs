defmodule SpectrePortableArtifactIntegrityCoverageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Component
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Projection.HumanReport
  alias Spectre.SensitiveData

  @fixture Path.expand("fixtures/compatibility/0.2.9/governance-v1.json", __DIR__)

  test "HumanReport normalizes references without accepting non-canonical report data" do
    report = report_fixture()
    [lineage] = report.lineage_refs

    non_canonical = %{report | lineage_refs: [lineage, lineage]}

    assert {:error, {:invalid_human_report, :human_report_integrity_mismatch}} =
             HumanReport.verify(non_canonical)

    data = HumanReport.to_data(report)

    assert {:error, :human_report_integrity_mismatch} =
             data
             |> Map.put("lineage_refs", [lineage, lineage])
             |> HumanReport.from_data()
  end

  test "HumanReport rejects malformed change collections before trusting their digest" do
    data = report_fixture() |> HumanReport.to_data()

    too_many =
      List.duplicate(%{"path" => [0], "change" => "added", "after" => true}, 4_097)

    assert {:error, {:human_report_change_limit_exceeded, 4_096}} =
             data |> Map.put("structural_changes", too_many) |> HumanReport.from_data()

    assert {:error, :human_report_changes_not_json_shaped} =
             data
             |> Map.put("structural_changes", [
               %{"path" => [0], "change" => "added", "after" => :atom}
             ])
             |> HumanReport.from_data()

    assert {:error, {:invalid_human_report_changes, {:nonportable_governance_data, _, :pid}}} =
             data
             |> Map.put("structural_changes", [
               %{"path" => [0], "change" => "added", "after" => self()}
             ])
             |> HumanReport.from_data()

    for {changes, reason} <- [
          {[%{"path" => :invalid, "change" => "added", "after" => true}],
           :human_report_changes_not_json_shaped},
          {[%{"path" => [0], "change" => "future", "after" => true}],
           {:invalid_human_report_change_shape, :structural}},
          {[%{"path" => [0], "change" => "added", "after" => true, "extra" => true}],
           {:invalid_human_report_change_shape, :structural}}
        ] do
      assert {:error, ^reason} =
               data |> Map.put("structural_changes", changes) |> HumanReport.from_data()
    end
  end

  test "HumanReport rejects malformed reference collections and unsafe struct verification" do
    report = report_fixture()
    data = HumanReport.to_data(report)

    assert {:error, {:invalid_human_report_refs, "candidate:sha256:"}} =
             data
             |> Map.put("lineage_refs", [42])
             |> HumanReport.from_data()

    assert {:error, {:invalid_human_report_refs, :tuple}} =
             data
             |> Map.put("lineage_refs", {:not, :a, :list})
             |> HumanReport.from_data()

    assert {:error, :invalid_human_report_data} =
             data |> Map.put("generator_id", :invalid) |> HumanReport.from_data()

    assert {:error, {:invalid_human_report, FunctionClauseError}} =
             HumanReport.verify(%{report | lineage_refs: [hd(report.lineage_refs) | :improper]})
  end

  test "HumanReport bounds adversarial structural diffs" do
    parent = canonical_with_payload(Map.new(1..4_097, &{&1, false}))
    candidate = canonical_with_payload(Map.new(1..4_097, &{&1, true}))

    assert {:error, {:human_report_change_limit_exceeded, 4_096}} =
             HumanReport.project(parent, candidate, evaluation_delta: evaluation_delta())
  end

  test "HumanReport renders integer and non-UTF8 map paths deterministically" do
    invalid_utf8 = <<255>>
    refute SensitiveData.sensitive_key?(invalid_utf8)
    assert SensitiveData.sensitive_key?(<<"password", 255>>)

    assert [^invalid_utf8, :password] =
             SensitiveData.sensitive_path(%{invalid_utf8 => %{password: "secret"}})

    parent = canonical_with_payload(%{7 => "before", invalid_utf8 => "old"})
    candidate = canonical_with_payload(%{7 => "after", invalid_utf8 => "new"})

    assert {:ok, report} =
             HumanReport.project(parent, candidate, evaluation_delta: evaluation_delta())

    paths = Enum.map(report.structural_changes, & &1["path"])
    assert Enum.any?(paths, &Enum.member?(&1, 7))
    assert Enum.any?(paths, &Enum.any?(&1, fn item -> is_map(item) end))
  end

  property "sensitive-data inspection is total for arbitrary binary keys" do
    check all(key <- binary(), max_runs: 250) do
      assert is_binary(SensitiveData.normalize_key(key))
      assert is_boolean(SensitiveData.sensitive_key?(key))

      result = SensitiveData.sensitive_path(%{key => %{value: true}})
      assert is_nil(result) or is_list(result)
    end
  end

  test "canonical decoder rejects malformed lengths, depth and integer payloads" do
    assert {:error, {:invalid_allowed_structs, :all}} =
             Value.decode(Value.encode!(nil), allowed_structs: :all)

    nested = Value.encode!([:nested])

    assert {:error, {:canonical_depth_exceeded, [0], 0}} =
             Value.decode(nested, max_depth: 0)

    assert {:error, {:invalid_canonical_integer, []}} =
             Value.decode("SPCV" <> <<1, 0x10, 2::unsigned-big-32, "1x">>)

    assert {:error, {:truncated_canonical_value, :binary}} =
             Value.decode("SPCV" <> <<1, 0x12, 1>>)
  end

  test "canonical struct decoder fails closed before constructing unsafe modules" do
    kernel = Atom.to_string(Kernel)
    <<"SPCV", 1, encoded_fields::binary>> = Value.encode!(%{})

    unsafe =
      "SPCV" <>
        <<1, 0x23, byte_size(kernel)::unsigned-big-32, kernel::binary, encoded_fields::binary>>

    assert {:error, {:invalid_canonical_struct, [], Kernel, UndefinedFunctionError}} =
             Value.decode(unsafe, allowed_structs: [Kernel])

    subject = Atom.to_string(Spectre.Subject)
    <<"SPCV", 1, encoded_integer::binary>> = Value.encode!(1)

    invalid_fields =
      "SPCV" <>
        <<1, 0x23, byte_size(subject)::unsigned-big-32, subject::binary, encoded_integer::binary>>

    assert {:error, {:invalid_canonical_struct_fields, []}} =
             Value.decode(invalid_fields, allowed_structs: [Spectre.Subject])

    for {value, shape} <- [{[], :list}, {%{}, :map}, {{}, :tuple}] do
      assert {:error, {:invalid_canonical_binary, ^shape}} = Value.decode(value)
    end
  end

  defp report_fixture do
    data = fixture_data() |> Map.fetch!("human_report")
    assert {:ok, report} = HumanReport.from_data(data)
    report
  end

  defp evaluation_delta do
    data = fixture_data() |> get_in(["human_report", "evaluation_delta"])
    assert {:ok, delta} = EvaluationDelta.from_data(data)
    delta
  end

  defp canonical_with_payload(payload) do
    component =
      Component.new!(
        component_type: :coverage_payload,
        schema_ref: "spectre.test/coverage-payload/1",
        criticality: :descriptive,
        payload: payload
      )

    Canonical.new!(
      kind: :agent,
      id: :portable_artifact_integrity,
      declared_version: 1,
      origin: :runtime,
      components: [component]
    )
  end

  defp fixture_data, do: @fixture |> File.read!() |> Jason.decode!()
end
