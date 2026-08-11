defmodule SpectreReflectiveRuntimeConceptSystemTest.LearningClassifier do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    if pid = Keyword.get(opts, :test_pid) do
      send(pid, {:learning_classifier_called, Keyword.get(opts, :learning_phase)})
    end

    case Keyword.get(opts, :learning_phase) do
      :teach -> {:ok, "LEARNED_SUPPORT"}
      :offline -> {:error, :classifier_offline}
      phase -> {:error, {:unexpected_learning_phase, phase}}
    end
  end
end

defmodule SpectreReflectiveRuntimeConceptSystemTest.LearningSkill do
  @moduledoc false

  use Spectre.Skill, id: :learned_support, version: 1

  flow :learned_support do
    on :LEARNED_SUPPORT, via: [:llm_classifier, :semantic_cache], learn: true do
      run(:answer)
    end
  end

  def answer(input, _context), do: {:ok, "learned:" <> input.text}
end

defmodule SpectreReflectiveRuntimeConceptSystemTest.LearningAgent do
  @moduledoc false

  use Spectre.Agent, id: :real_learning_agent

  classifier(SpectreReflectiveRuntimeConceptSystemTest.LearningClassifier)
  router(via: [:llm_classifier], classification_log?: false)
  skill(SpectreReflectiveRuntimeConceptSystemTest.LearningSkill, as: :learned_support)
end

defmodule SpectreReflectiveRuntimeConceptSystemTest do
  use ExUnit.Case, async: false

  alias Spectre.Router.SemanticCache
  alias SpectreReflectiveRuntimeConceptSystemTest.LearningAgent
  alias SpectreReflectiveRuntimeConceptSystemTest.LearningSkill

  test "a real Agent learns, rejects unverified memory, then recalls verified evidence" do
    assert :ok = SemanticCache.clear(LearningAgent)
    on_exit(fn -> SemanticCache.clear(LearningAgent) end)

    assert {:ok, taught} =
             Spectre.ask(LearningAgent, "reset my password",
               learning_phase: :teach,
               test_pid: self()
             )

    assert_receive {:learning_classifier_called, :teach}
    assert taught.reply_text == "learned:reset my password"
    assert taught.route.strategy == :llm_classifier
    assert taught.route.owner == LearningSkill
    assert taught.route.scope == {:skill, :learned_support}

    assert {:ok, [example]} = SemanticCache.examples(LearningAgent)
    assert example.text == "reset my password"
    assert example.label == :LEARNED_SUPPORT
    refute example.verified?
    assert example.metadata.owner == LearningSkill
    assert example.metadata.scope == {:skill, :learned_support}

    assert {:ok, guarded} =
             Spectre.ask(LearningAgent, "reset my password",
               learning_phase: :offline,
               test_pid: self()
             )

    assert_receive {:learning_classifier_called, :offline}
    assert guarded.reply_text == ""
    refute guarded.route.accepted?

    assert {:ok, verified} = SemanticCache.verify(LearningAgent, example.id)
    assert verified.verified?
    assert %DateTime{} = verified.metadata.verified_at

    assert {:ok, recalled} =
             Spectre.ask(LearningAgent, "reset my password",
               learning_phase: :offline,
               test_pid: self()
             )

    refute_receive {:learning_classifier_called, :offline}, 50
    assert recalled.reply_text == "learned:reset my password"
    assert recalled.route.strategy == :semantic_cache_exact
    assert recalled.route.owner == LearningSkill
    assert recalled.route.scope == {:skill, :learned_support}
  end
end
