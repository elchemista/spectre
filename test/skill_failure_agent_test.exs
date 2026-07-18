defmodule SpectreSkillFailureAgentTest.Model do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:model_called, prompt})

    if Keyword.get(opts, :fail_model?, false) do
      {:error, :model_unavailable}
    else
      {:ok, "MODEL_OK"}
    end
  end
end

defmodule SpectreSkillFailureAgentTest.Provider do
  @moduledoc false

  def unavailable(_ctx), do: {:error, :provider_unavailable}
end

defmodule SpectreSkillFailureAgentTest.Actions do
  @moduledoc false

  def perform_failure(args, ctx) do
    if pid = Keyword.get(ctx.opts, :test_pid), do: send(pid, {:action_called, args})
    {:error, :backend_unavailable}
  end
end

defmodule SpectreSkillFailureAgentTest.FailureSkill do
  @moduledoc false

  use Spectre.Skill,
    id: :failure_skill,
    prompt_root: "test/fixtures/skill_inject/skill"

  requires_action(:work, mode: :write)

  policy :confirm_publish do
    request(:confirm_publish)
    accept(:accepted, regex: ~r/^yes$/i)
    reject(:rejected, regex: ~r/^no$/i)
  end

  protect(:work, with: :confirm_publish)

  flow :failure_paths do
    on :ASK, regex: ~r/^ask$/ do
      ask(:base)
    end

    on :MISSING_PROMPT, regex: ~r/^missing prompt$/ do
      ask(:missing_prompt)
    end

    on :RUN_CRASH, regex: ~r/^run crash$/ do
      run(:crashing_run)
    end

    on :RUN_EXIT, regex: ~r/^run exit$/ do
      run(:exiting_run)
    end

    on :RUN_OK, regex: ~r/^run ok$/ do
      run(:healthy_run)
    end

    on :FAILING_ACTION, regex: ~r/^failing action$/ do
      action(:work, args: %{job: :failure_test})
    end
  end

  def crashing_run(_input, _ctx), do: raise("run callback exploded")
  def exiting_run(_input, _ctx), do: exit(:run_callback_exit)
  def healthy_run(_input, _ctx), do: {:ok, "RUN_OK"}
end

defmodule SpectreSkillFailureAgentTest.Agent do
  @moduledoc false

  use Spectre.Agent

  model(SpectreSkillFailureAgentTest.Model)
  actions(SpectreSkillFailureAgentTest.Actions)

  skill(SpectreSkillFailureAgentTest.FailureSkill,
    as: :failure,
    bind: [work: :perform_failure]
  )
end

defmodule SpectreSkillFailureAgentTest do
  use ExUnit.Case, async: false

  alias Spectre.Effect
  alias Spectre.Provider.Failure
  alias Spectre.Result
  alias SpectreSkillFailureAgentTest.Agent
  alias SpectreSkillFailureAgentTest.FailureSkill
  alias SpectreSkillFailureAgentTest.Provider

  test "a full Skill Agent reports a missing owner prompt and its Session remains usable" do
    session = start_supervised!({Spectre.Session, agent: Agent})

    assert {:error, {:missing_prompt, path}} =
             Spectre.ask(session, "missing prompt", test_pid: self())

    assert String.ends_with?(path, "/skill/missing_prompt.text.heex")
    refute_receive {:model_called, _prompt}
    assert Process.alive?(session)

    assert {:ok, recovered} = Spectre.ask(session, "run ok")
    assert recovered.reply_text == "RUN_OK"
    assert recovered.route.owner == FailureSkill
    assert recovered.route.scope == {:skill, :failure}
  end

  test "a required runtime injection failure stops the full turn before the model call" do
    inject = [
      prompt: :required_provider,
      from: {Provider, :unavailable},
      into: :context
    ]

    assert {:error, {:prompt_operation_failed, :required_provider, :provider_unavailable}} =
             Spectre.ask(Agent, "ask", inject: inject, test_pid: self())

    refute_receive {:model_called, _prompt}
  end

  test "a model failure is returned and does not poison a full Agent Session" do
    session = start_supervised!({Spectre.Session, agent: Agent})

    assert {:error, :model_unavailable} =
             Spectre.ask(session, "ask", fail_model?: true, test_pid: self())

    assert_receive {:model_called, prompt}
    assert prompt =~ "BASE_TASK ask"
    assert Process.alive?(session)

    assert {:ok, recovered} = Spectre.ask(session, "ask", test_pid: self())
    assert_receive {:model_called, _prompt}
    assert recovered.reply_text == "MODEL_OK"
  end

  test "raising and exiting Skill run callbacks return errors without crashing the Session" do
    session = start_supervised!({Spectre.Session, agent: Agent})

    assert {:error,
            %Failure{provider: :run, kind: :exception, reason: RuntimeError} = raised_failure} =
             Spectre.ask(session, "run crash")

    refute inspect(raised_failure) =~ "run callback exploded"

    assert Process.alive?(session)

    assert {:error, %Failure{provider: :run, kind: :exit, reason: :run_callback_exit}} =
             Spectre.ask(session, "run exit")

    assert Process.alive?(session)
    assert {:ok, recovered} = Spectre.ask(session, "run ok")
    assert recovered.reply_text == "RUN_OK"
  end

  test "rejecting a protected Skill action cancels it without invoking the adapter" do
    assert {:ok, awaiting} = Spectre.ask(Agent, "failing action", test_pid: self())
    assert_receive {:model_called, prompt}
    assert prompt =~ "CONFIRM_PUBLISH"

    assert %Effect{status: :waiting_policy} = Result.pending_effect(awaiting)

    assert {:ok, rejected} =
             Spectre.ask(Agent, "no", state: awaiting.state, test_pid: self())

    assert [%Effect{status: :cancelled} = cancelled] = rejected.effects
    assert Effect.outcome(cancelled) == {:cancelled, {:policy_rejected, :rejected}}
    assert rejected.state.pending_effects == []
    refute_receive {:action_called, _args}

    assert {:ok, terminal} = Spectre.execute(Agent, rejected, test_pid: self())
    assert terminal.state.pending_effects == []
    refute_receive {:action_called, _args}
  end

  test "an approved Skill action adapter failure becomes a scoped failed effect" do
    assert {:ok, awaiting} = Spectre.ask(Agent, "failing action", test_pid: self())
    assert_receive {:model_called, _prompt}

    assert {:ok, approved} =
             Spectre.ask(Agent, "yes", state: awaiting.state, test_pid: self())

    assert %Effect{status: :approved} = Result.pending_effect(approved)

    assert {:ok, failed_result} = Spectre.execute(Agent, approved, test_pid: self())
    assert_receive {:action_called, %{job: :failure_test}}

    assert [%Effect{status: :failed, error: :backend_unavailable} = failed] =
             failed_result.effects

    assert Effect.scope(failed) == {:skill, :failure}
    assert failed_result.state.pending_effects == []
    assert Result.action_outcome(failed_result) == {:error, :backend_unavailable}
  end
end
