defmodule SpectreInferenceHardeningContractTest.DeterminismSource do
  @moduledoc false

  @behaviour Spectre.Determinism.Source

  @impl Spectre.Determinism.Source
  def system_time(_unit, opts), do: Keyword.fetch!(opts, :system_time)

  @impl Spectre.Determinism.Source
  def monotonic_time(_unit, opts), do: Keyword.get(opts, :monotonic_time, -10)

  @impl Spectre.Determinism.Source
  def random_bytes(count, opts) do
    bytes = Keyword.fetch!(opts, :random_bytes)
    binary_part(bytes, 0, count)
  end
end

defmodule SpectreInferenceHardeningContractTest.Agent do
  @moduledoc false

  use Spectre.Agent, prompt_root: "test/fixtures/strategy_matrix/prompts"
end

defmodule SpectreInferenceHardeningContractTest.AuditSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :asset_audit,
    prompt_root: "test/fixtures/skill_inject/skill"
end

defmodule SpectreInferenceHardeningContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Action.Schema
  alias Spectre.Determinism
  alias Spectre.Inference.IncrementalSanitizer
  alias Spectre.Prompt.AssetAudit

  test "the action schema subset validates nested values without echoing rejected data" do
    schema = %{
      type: :object,
      required: ["name", "items"],
      additionalProperties: false,
      properties: %{
        "name" => %{type: :string, minLength: 2, maxLength: 8, pattern: "^[a-z]+$"},
        "items" => %{
          type: :array,
          minItems: 1,
          maxItems: 2,
          uniqueItems: true,
          items: %{type: :integer, minimum: 1, maximum: 9}
        }
      }
    }

    assert :ok = Schema.validate(schema, %{"name" => "valid", "items" => [1, 2]})

    secret = "BADVALUE"

    assert {:error, {:action_arguments_outside_schema, ["name"], "pattern"}} =
             Schema.validate(schema, %{"name" => secret, "items" => [1]})

    refute inspect(Schema.validate(schema, %{"name" => secret, "items" => [1]})) =~ secret

    assert {:error, {:action_arguments_outside_schema, ["unexpected"], :additional_property}} =
             Schema.validate(schema, %{
               "name" => "valid",
               "items" => [1],
               "unexpected" => true
             })
  end

  test "unsupported or ambiguous JSON-Schema vocabulary fails closed" do
    assert Schema.constrained?(%{"$ref" => "https://example.invalid/schema"})

    assert {:error, {:invalid_action_schema, [], {:unsupported_keyword, "$ref"}}} =
             Schema.validate(%{"$ref" => "https://example.invalid/schema"}, %{})

    assert {:error, {:invalid_action_schema, [], {:duplicate_keyword, "type"}}} =
             Schema.validate(%{"type" => "string", type: :string}, "value")

    assert {:error, {:action_arguments_outside_schema, [], "oneOf"}} =
             Schema.validate(
               %{"oneOf" => [%{"type" => "number"}, %{"type" => "integer"}]},
               1
             )

    # Discovery-only metadata remains backward compatible and does not claim
    # to constrain an action payload.
    refute Schema.constrained?(%{arity: 2, version: 1})
    assert :ok = Schema.validate(%{arity: 2, version: 1}, %{anything: :goes})
  end

  test "incremental sanitization is invariant to provider chunk boundaries" do
    input = "<think>private reasoning</think><!-- hidden -->visible"

    for split <- 0..byte_size(input) do
      <<left::binary-size(^split), right::binary>> = input

      assert {:ok, first, state} = IncrementalSanitizer.push(IncrementalSanitizer.new(), left)
      assert {:ok, second, state} = IncrementalSanitizer.push(state, right)
      assert {:ok, trailing, _state} = IncrementalSanitizer.finish(state)
      assert first <> second <> trailing == "visible"
    end

    assert {:ok, "", state} =
             IncrementalSanitizer.push(IncrementalSanitizer.new(), "intent: secret")

    assert {:ok, "visible", state} = IncrementalSanitizer.push(state, "\nvisible")
    assert {:ok, "", _state} = IncrementalSanitizer.finish(state)
  end

  test "the sanitizer bounds incomplete control headers and explicit opt-out is transparent" do
    state = IncrementalSanitizer.new(max_sanitizer_lookahead_bytes: 16)

    assert {:error, :sanitizer_lookahead_exceeded} =
             IncrementalSanitizer.push(state, "<think " <> String.duplicate("x", 32))

    transparent = IncrementalSanitizer.new(sanitize_reply: false)
    chunk = "<think>host explicitly requested raw provisional text</think>"
    assert {:ok, ^chunk, transparent} = IncrementalSanitizer.push(transparent, chunk)
    assert {:ok, "", _transparent} = IncrementalSanitizer.finish(transparent)
  end

  test "the sanitizer handles incomplete and non-control tags in every parser state" do
    assert {:ok, "visible", _state} =
             IncrementalSanitizer.push(
               IncrementalSanitizer.new(),
               "<reply>visible</reply>"
             )

    assert {:ok, "<xyz", _state} =
             IncrementalSanitizer.push(IncrementalSanitizer.new(), "<xyz")

    assert {:ok, "shown", _state} =
             IncrementalSanitizer.push(
               IncrementalSanitizer.new(),
               "<think>secret<unknown>still secret</think>shown"
             )

    assert {:ok, "", fragment} =
             IncrementalSanitizer.push(IncrementalSanitizer.new(), "<think>secret</th")

    assert {:ok, "", %{buffer: ""}} = IncrementalSanitizer.finish(fragment)

    assert {:ok, "", incomplete_tag} =
             IncrementalSanitizer.push(IncrementalSanitizer.new(), "<think attribute")

    assert {:ok, "", %{buffer: ""}} = IncrementalSanitizer.finish(incomplete_tag)

    bounded = IncrementalSanitizer.new(max_sanitizer_lookahead_bytes: 16)

    assert {:error, :sanitizer_lookahead_exceeded} =
             IncrementalSanitizer.push(
               bounded,
               "<think>secret<think " <> String.duplicate("x", 17)
             )
  end

  test "decision-relevant clock and randomness can be captured and replayed exactly" do
    source =
      {SpectreInferenceHardeningContractTest.DeterminismSource,
       system_time: 1_700_000_000_123,
       monotonic_time: -50,
       random_bytes: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9>>}

    {values, samples} =
      Determinism.capture([determinism_source: source], fn ->
        {
          Determinism.system_time(:millisecond),
          Determinism.monotonic_time(:millisecond),
          Determinism.random_bytes(4)
        }
      end)

    assert values == {1_700_000_000_123, -50, <<0, 1, 2, 3>>}
    assert Enum.map(samples, & &1.kind) == [:system_time, :random_bytes]
    assert Enum.map(samples, & &1.sequence) == [1, 2]

    assert {^values, ^samples} =
             Determinism.capture([determinism_replay: samples], fn ->
               {
                 Determinism.system_time(:millisecond),
                 # Monotonic liveness is sourceable but deliberately absent
                 # from durable replay evidence.
                 -50,
                 Determinism.random_bytes(4)
               }
             end)

    assert_raise ArgumentError, ~r/determinism replay mismatch/, fn ->
      Determinism.capture([determinism_replay: samples], fn ->
        Determinism.random_bytes(4)
      end)
    end
  end

  test "prompt asset audit identifies untrusted interpolation and accepts data wrapping" do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-prompt-audit-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    unsafe = Path.join(root, "unsafe.text.heex")
    safe = Path.join(root, "safe.text.heex")
    File.write!(unsafe, "Instruction: <%= @input.text %>\n")
    File.write!(safe, "Data: <%= Spectre.Prompt.data(@input.text) %>\n")

    {:ok, definition} =
      Spectre.Definition.fetch(SpectreInferenceHardeningContractTest.Agent)

    assert {:ok, [finding]} = AssetAudit.audit(%{definition | prompt_root: root})
    assert finding.path == unsafe
    assert finding.line == 1
    assert finding.assigns == ["input"]
  end

  test "prompt asset audit follows valid Skill roots and skips unavailable definitions" do
    {:ok, definition} =
      Spectre.Definition.fetch(SpectreInferenceHardeningContractTest.Agent)

    {:ok, skill_definition} =
      Spectre.Definition.fetch(SpectreInferenceHardeningContractTest.AuditSkill)

    mount =
      Spectre.Skill.Mount.new(
        SpectreInferenceHardeningContractTest.AuditSkill,
        skill_definition,
        as: :asset_audit
      )

    unavailable = %{
      mount
      | id: :unavailable,
        module: Module.concat(__MODULE__, UnavailableAuditSkill)
    }

    audit_definition = %{
      definition
      | prompt_root: "test/fixtures/does-not-exist",
        skills: [mount, unavailable]
    }

    assert {:ok, findings} = AssetAudit.audit(audit_definition)
    assert Enum.any?(findings, &(&1.scope == {:skill, :asset_audit}))
  end

  test "prompt asset audit reports an unreadable template instead of ignoring it" do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-prompt-audit-unreadable-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    path = Path.join(root, "unreadable.text.heex")
    File.write!(path, "<%= @input.text %>")
    File.chmod!(path, 0o000)

    on_exit(fn ->
      _ = File.chmod(path, 0o600)
      File.rm_rf!(root)
    end)

    {:ok, definition} =
      Spectre.Definition.fetch(SpectreInferenceHardeningContractTest.Agent)

    assert {:error, {:prompt_asset_audit_read_failed, ^path, :eacces}} =
             AssetAudit.audit(%{definition | prompt_root: root})
  end
end
