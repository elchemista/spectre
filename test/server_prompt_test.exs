defmodule Spectre.ServerPromptTest.Model do
  def complete(prompt, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:server_model_prompt, prompt})
    {:ok, "generated answer"}
  end
end

defmodule Spectre.ServerPromptTest do
  use ExUnit.Case, async: true

  defp agent do
    module = Module.concat(__MODULE__, "Agent#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Spectre.Agent, server: MyApp.Server, prompt_root: "missing-agent-default-root"
      model Spectre.ServerPromptTest.Model
    end
    """)

    module
  end

  @tag :tmp_dir
  test "Server generation resolves templates from its own root", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "answer.text.heex"), "server-specific prompt")
    agent = agent()

    context = %{
      agent: agent,
      input: Spectre.Input.new("question"),
      assigns: %{},
      routing: %{},
      options: [prompt_root: dir],
      consumer: self()
    }

    request = %{
      input: context.input,
      prompt: :answer,
      assigns: %{},
      planning: false,
      stream: false
    }

    assert {:generated, %{text: "generated answer", proposals: []}} =
             Spectre.Server.Services.generate(request, context, test_pid: self())

    assert_receive {:server_model_prompt, prompt}
    assert prompt =~ "server-specific prompt"
  end

  @tag :tmp_dir
  test "Server root preserves prompt containment and rejects an invalid root", %{tmp_dir: dir} do
    agent = agent()
    ctx = %Spectre.Context{agent: agent, state: %Spectre.State{}}

    assert {:error, {:prompt_outside_root, _, _}} =
             Spectre.Prompt.resolve(agent, "../outside.text.heex", ctx, server_prompt_root: dir)

    assert {:error, {:invalid_server_prompt_root, false}} =
             Spectre.Prompt.resolve(agent, :answer, ctx, server_prompt_root: false)
  end

  test "bundled Server prompt roots resolve inside the application's priv directory" do
    agent = agent()
    ctx = %Spectre.Context{agent: agent, state: %Spectre.State{}}
    root = {:priv, :spectre, "templates/spectre.gen.agent"}

    assert {:ok, path} =
             Spectre.Prompt.resolve(agent, "server.ex.eex", ctx, server_prompt_root: root)

    assert String.ends_with?(path, "priv/templates/spectre.gen.agent/server.ex.eex")

    assert {:error, {:prompt_outside_root, _, _}} =
             Spectre.Prompt.resolve(agent, "mix.exs", ctx,
               server_prompt_root: {:priv, :spectre, ".."}
             )

    assert {:error, {:prompt_outside_root, _, _}} =
             Spectre.Prompt.resolve(agent, "../outside.text.heex", ctx, server_prompt_root: root)
  end

  @tag :tmp_dir
  test "mounted Skill keeps its root when a Server root is configured", %{tmp_dir: dir} do
    skill_root = Path.join(dir, "skill")
    server_root = Path.join(dir, "server")
    File.mkdir_p!(skill_root)
    File.mkdir_p!(server_root)
    path = Path.join(skill_root, "answer.text.heex")
    File.write!(path, "skill prompt")
    File.write!(Path.join(server_root, "answer.text.heex"), "server prompt")
    skill = Module.concat(__MODULE__, "Skill#{System.unique_integer([:positive])}")
    agent = Module.concat(__MODULE__, "MountedAgent#{System.unique_integer([:positive])}")

    Code.compile_string("""
    defmodule #{inspect(skill)} do
      use Spectre.Skill, prompt_root: #{inspect(skill_root)}
      flow :billing do
        on :invoice
      end
    end
    defmodule #{inspect(agent)} do
      use Spectre.Agent, server: MyApp.Server
      skill #{inspect(skill)}, as: :billing
    end
    """)

    ctx = %Spectre.Context{
      agent: agent,
      state: %Spectre.State{},
      route: %Spectre.Route{scope: {:skill, :billing}}
    }

    assert {:ok, ^path} =
             Spectre.Prompt.resolve(agent, :answer, ctx, server_prompt_root: server_root)

    assert {:ok, "skill prompt"} =
             Spectre.Prompt.render_asset(agent, :answer, ctx, server_prompt_root: server_root)

    context = %{
      agent: agent,
      input: Spectre.Input.new("question"),
      assigns: %{},
      routing: %{route: ctx.route},
      options: [prompt_root: server_root, runtime_scope: {:skill, :billing}]
    }

    legacy = Spectre.Server.ServiceContext.legacy(context, context.input, [], %{})

    assert {:ok, "server prompt"} =
             Spectre.Prompt.render_asset(agent, :answer, legacy, legacy.opts)

    assert {:error, {:prompt_outside_root, _, _}} =
             Spectre.Prompt.resolve(agent, "../outside.text.heex", legacy, legacy.opts)
  end
end
