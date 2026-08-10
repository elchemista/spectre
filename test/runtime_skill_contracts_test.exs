defmodule SpectreRuntimeSkillContractsTest do
  use ExUnit.Case, async: true

  alias Spectre.Router.IndexProfile
  alias Spectre.Skill.Applicability
  alias Spectre.Skill.PromptBudget

  describe "routing index profiles" do
    test "support deterministic defaults, keyword input, and portable round-trips" do
      assert IndexProfile.schema_version() == 1

      default = IndexProfile.default()
      assert default.strategy == :exact
      assert default.metric == :none
      assert {:ok, ^default} = IndexProfile.new(default)

      assert {:ok, lexical} =
               IndexProfile.new(id: "spectre.routing.lexical", strategy: :lexical)

      data = IndexProfile.to_data(lexical)
      assert {:ok, ^lexical} = IndexProfile.from_data(data)
      assert {:ok, ^lexical} = IndexProfile.from_data(stringify_keys(data))
      assert IndexProfile.digest(lexical) == IndexProfile.digest(lexical)

      assert {:ok, embedding} =
               IndexProfile.new(%{
                 id: "spectre.routing.embedding",
                 strategy: :embedding,
                 model_profile_ref: "model:text-v1",
                 dimensions: 384,
                 metric: :cosine
               })

      assert embedding.dimensions == 384
    end

    test "reject malformed identities, strategies, capacities, and model fields" do
      invalid = [
        {%{schema_version: 2}, {:unsupported_routing_index_profile_schema, 2}},
        {%{id: ""}, {:invalid_routing_index_profile_id, ""}},
        {%{version: 0}, {:invalid_routing_index_profile_version, 0}},
        {%{strategy: :unknown}, {:invalid_routing_index_strategy, :unknown}},
        {%{metric: :unknown}, {:invalid_routing_index_metric, :unknown}},
        {%{max_entries: 0}, {:invalid_routing_index_capacity, 0}},
        {%{metadata: []}, :invalid_routing_index_metadata},
        {%{strategy: :embedding}, :incomplete_embedding_routing_index_profile},
        {%{model_profile_ref: "model:v1"}, :non_embedding_routing_index_has_model_fields}
      ]

      Enum.each(invalid, fn {attrs, reason} ->
        assert {:error, ^reason} = IndexProfile.new(attrs)
      end)

      assert {:error, {:unknown_routing_index_profile_fields, [:extra]}} =
               IndexProfile.new(%{extra: true})

      assert {:error, {:nonportable_routing_index_profile, _reason}} =
               IndexProfile.new(%{metadata: %{pid: self()}})
    end

    test "reject invalid shapes and expose raising construction" do
      assert {:error, {:invalid_routing_index_profile, :list}} = IndexProfile.new([:bad])
      assert {:error, {:invalid_routing_index_profile, :map}} = IndexProfile.new(URI.parse("/"))
      assert {:error, {:invalid_routing_index_profile, :binary}} = IndexProfile.new("bad")
      assert {:error, {:invalid_routing_index_profile, :other}} = IndexProfile.new(42)

      assert_raise ArgumentError, ~r/invalid routing index profile/, fn ->
        IndexProfile.new!(%{version: 0})
      end
    end
  end

  describe "Skill applicability" do
    test "normalizes portable values and evaluates scope, tags, specificity, and conflicts" do
      assert Applicability.schema_version() == 1

      assert {:ok, applicability} =
               Applicability.new(
                 scopes: [:support, :support],
                 required_tags: [:trusted],
                 forbidden_tags: [:admin],
                 positive: ["lookup", "lookup"],
                 negative: ["delete"],
                 conflicts: [:legacy]
               )

      assert applicability.scopes == [:support]
      assert Applicability.matches?(applicability, %{scope: :support, tags: [:trusted]})
      assert Applicability.matches?(applicability, %{"scope" => :support, "tags" => [:trusted]})
      refute Applicability.matches?(applicability, %{scope: :support, tags: [:trusted, :admin]})
      refute Applicability.matches?(applicability, %{scope: :other, tags: [:trusted]})
      refute Applicability.matches?(applicability, :invalid_context)
      assert Applicability.specificity(applicability) == 2

      assert applicability
             |> Map.put(:forbidden_tags, Enum.map(1..50, &"absent-#{&1}"))
             |> Applicability.specificity() == 2

      assert Applicability.conflicts?(applicability, :legacy)
      refute Applicability.conflicts?(applicability, :current)

      data = Applicability.to_data(applicability)
      assert {:ok, ^applicability} = Applicability.from_data(stringify_keys(data))
      assert {:ok, ^applicability} = Applicability.new(applicability)
    end

    test "fails closed for malformed declarations and nonportable matching values" do
      invalid = [
        {%{schema_version: 2}, {:unsupported_skill_applicability_schema, 2}},
        {%{scopes: :support}, {:invalid_skill_applicability_values, :scopes, :other}},
        {%{required_tags: :trusted},
         {:invalid_skill_applicability_values, :required_tags, :other}},
        {%{positive: :lookup}, {:invalid_skill_applicability_examples, :positive}},
        {%{negative: [""]}, {:invalid_skill_applicability_examples, :negative}},
        {%{positive: ["same"], negative: ["same"]},
         {:conflicting_skill_applicability_value, "same"}},
        {%{required_tags: [:same], forbidden_tags: [:same]},
         {:conflicting_skill_applicability_value, :same}}
      ]

      Enum.each(invalid, fn {attrs, reason} ->
        assert {:error, ^reason} = Applicability.new(attrs)
      end)

      assert {:error, {:unknown_skill_applicability_fields, [:extra]}} =
               Applicability.new(%{extra: true})

      assert {:error, {:invalid_skill_applicability_value, :scopes, _reason}} =
               Applicability.new(%{scopes: [self()]})

      assert {:error, {:invalid_skill_applicability, :list}} = Applicability.new([:bad])

      assert {:error, {:invalid_skill_applicability, :map}} =
               Applicability.new(URI.parse("/"))

      assert {:error, {:invalid_skill_applicability, :binary}} = Applicability.new("bad")
      assert {:error, {:invalid_skill_applicability, :other}} = Applicability.new(42)

      applicability = Applicability.new!(%{required_tags: [:trusted]})
      refute Applicability.matches?(applicability, %{tags: [self()]})

      assert_raise ArgumentError, ~r/invalid Skill applicability/, fn ->
        Applicability.new!(%{schema_version: 2})
      end
    end
  end

  describe "Skill prompt budgets" do
    test "accounts for capped and legacy fragments and round-trips canonical data" do
      assert PromptBudget.schema_version() == 1

      fragments = [
        %{content: "1234", token_cap: 2},
        %{"content" => "12345678", "token_cap" => 3}
      ]

      assert {:ok, budget} =
               PromptBudget.new(fragments, token_cap: 8, reserved_tokens: 4)

      assert budget.reserved_tokens == 5
      assert budget.estimated_tokens == 3
      assert budget.fragment_count == 2

      data = PromptBudget.to_data(budget)
      assert {:ok, ^budget} = PromptBudget.from_data(data)
      assert {:ok, ^budget} = PromptBudget.from_data(stringify_keys(data))
      assert PromptBudget.digest(budget) == PromptBudget.digest(budget)

      assert {:ok, legacy} = PromptBudget.new([%{content: "12345"}], token_cap: 8)
      assert legacy.reserved_tokens == 2
    end

    test "rejects invalid options, counters, caps, fragments, and aggregate usage" do
      assert {:error, :invalid_skill_prompt_budget_options} =
               PromptBudget.new([], require_fragment_caps?: :yes)

      assert {:error, {:unknown_skill_prompt_budget_options, [:unknown]}} =
               PromptBudget.new([], unknown: true)

      assert {:error, :invalid_skill_prompt_budget_options} =
               PromptBudget.new([], [{:token_cap, 8}, :bad])

      assert {:error, {:invalid_skill_prompt_token_cap, 0, 4_096}} =
               PromptBudget.new([], token_cap: 0)

      assert {:error, {:invalid_skill_prompt_token_cap, 4_097, 4_096}} =
               PromptBudget.new([], token_cap: 4_097)

      assert {:error, {:invalid_skill_prompt_reserved_tokens, 9, 8}} =
               PromptBudget.new([], token_cap: 8, reserved_tokens: 9)

      assert {:error, {:runtime_skill_prompt_fragment_requires_cap, 0}} =
               PromptBudget.new([%{content: "hello"}],
                 token_cap: 8,
                 require_fragment_caps?: true
               )

      assert {:error, {:invalid_skill_prompt_fragment, 0, :binary}} =
               PromptBudget.new(["hello"])

      assert {:error, {:invalid_skill_prompt_fragment_cap, 0, nil}} =
               PromptBudget.new([%{content: 42}])

      assert {:error, {:invalid_skill_prompt_fragment_cap, 0, 0}} =
               PromptBudget.new([%{content: "hello", token_cap: 0}])

      assert {:error, {:skill_prompt_fragment_over_budget, 0, 2, 1}} =
               PromptBudget.new([%{content: "12345", token_cap: 1}])

      assert {:error, {:skill_prompt_budget_exceeded, 4, 3}} =
               PromptBudget.new(
                 [%{content: "1", token_cap: 2}, %{content: "2", token_cap: 2}],
                 token_cap: 3
               )

      assert {:error, :invalid_skill_prompt_budget_counters} =
               PromptBudget.from_data(%{
                 schema_version: 1,
                 token_cap: 8,
                 reserved_tokens: 4,
                 estimated_tokens: -1,
                 fragment_count: 1
               })

      assert {:error, {:unsupported_skill_prompt_budget_schema, 2}} =
               PromptBudget.from_data(%{
                 schema_version: 2,
                 token_cap: 8,
                 reserved_tokens: 0,
                 estimated_tokens: 0,
                 fragment_count: 0
               })
    end

    test "rejects invalid shapes and exposes raising construction" do
      assert %PromptBudget{token_cap: 512, fragment_count: 0} = PromptBudget.new!([])

      assert {:error, {:invalid_skill_prompt_budget_input, :map, :list}} =
               PromptBudget.new(%{})

      assert {:error, {:invalid_skill_prompt_budget_input, :list, :map}} =
               PromptBudget.new([], %{})

      assert {:error, {:invalid_skill_prompt_budget, :map}} = PromptBudget.from_data(%{})
      assert {:error, {:invalid_skill_prompt_budget, :list}} = PromptBudget.from_data([])
      assert {:error, {:invalid_skill_prompt_budget, :binary}} = PromptBudget.from_data("bad")
      assert {:error, {:invalid_skill_prompt_budget, :other}} = PromptBudget.from_data(42)

      assert {:error, {:invalid_skill_prompt_reserved_tokens, 9, 8}} =
               PromptBudget.from_data(%{
                 schema_version: 1,
                 token_cap: 8,
                 reserved_tokens: 9,
                 estimated_tokens: 0,
                 fragment_count: 0
               })

      assert_raise ArgumentError, ~r/invalid Skill prompt budget/, fn ->
        PromptBudget.new!([], token_cap: 0)
      end
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
