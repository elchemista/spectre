defmodule Mix.Tasks.Spectre.Gen.Agent do
  @moduledoc """
  Generates a small, local Hello World agent and its routing regression cases.

      mix spectre.gen.agent MyApp.Hello
      mix spectre.gen.agent MyApp.Hello --dry-run

  Writes an Agent, extracted Router, compiled `.txt.eex` prompt, ExUnit contract
  test and JSONL cases beneath `lib/` and `test/`. Run from the host Mix project
  (for an umbrella, from the selected child application). The module name
  determines paths and the authoring namespace/name; it grants no authority.

  The generated handler prepares a local greeting in `state.draft`. No LLM,
  network client, Surface, Mandate, credential, Domain or process is installed.
  Its contract test runs immediately; an actual Instance still requires the
  host's authenticated Scope and activated Definition. This is scaffolding,
  not an alternative runtime or a permissive test foundation.

  Existing targets are rejected before writing anything. `--dry-run` lists
  targets without writing or compiling. There is deliberately no `--force`.
  """
  use Mix.Task
  alias Spectre.Mix.Scaffold
  @shortdoc "Generate an Agent, Router, prompt and runnable Hello World tests"

  @impl Mix.Task
  def run(args) do
    {opts, names} = OptionParser.parse!(args, strict: [dry_run: :boolean])
    name = Scaffold.module_name!(names, "usage: mix spectre.gen.agent MyApp.Hello [--dry-run]")
    Scaffold.write(files(name), opts[:dry_run])

    path = Macro.underscore(name)
    Mix.shell().info("Next: mix test test/#{path}_test.exs")
    Mix.shell().info("Then: mix spectre.eval #{name} test/#{path}_routes.jsonl --flow greetings")

    Mix.shell().info(
      "This prepares local drafts only. Wire a Scope and Definition to start an Instance."
    )

    Mix.shell().info("Optional next step: mix spectre.gen.host #{name} --class greeting.save")
  end

  defp files(name) do
    path = Macro.underscore(name)
    leaf = Path.basename(path)
    namespace = path |> String.split("/") |> hd()

    [
      {"lib/#{path}/router.ex", router(name)},
      {"lib/#{path}/prompts/hello.txt.eex", "Hello, <%= @name %>!\n"},
      {"lib/#{path}.ex", agent(name, namespace, leaf)},
      {"test/#{path}_test.exs", contract_test(name)},
      {"test/#{path}_routes.jsonl", cases()}
    ]
  end

  defp router(name) do
    """
    defmodule #{name}.Router do
      @moduledoc "Local message routing. Selecting a handler is not permission to act."
      use Spectre.Router

      flow :greetings do
        # Try an exact grammar first, then phrase similarity for help messages.
        router via: [:regex, :string_bag], accept: 0.85, margin: 0.05
        route :hello, match: [regex: ~r/^(?:hello|hi)(?: (?<name>[\\p{L}][\\p{L} '-]{0,63}))?[!.]?$/iu]
        route :help, match: [string_bag: ["help", "what can you do"]]
      end
    end
    """
  end

  defp agent(name, namespace, leaf) do
    """
    defmodule #{name} do
      @moduledoc \"\"\"
      A local greeting agent: Router -> handler -> rendered draft.

      Run its contract test without a Domain or provider. To use the ordinary
      OTP Instance, the host supplies an authenticated Scope and activates the
      exact Definition; see Spectre's host-setup guide. A draft is not delivery.
      \"\"\"
      use Spectre.Agent, namespace: #{inspect(namespace)}, name: #{inspect(leaf)}

      router #{name}.Router
      prompt_root Path.join(__DIR__, #{inspect(leaf <> "/prompts")})
      prompt :hello, file: "hello.txt.eex"

      @impl true
      def handle_turn({:greetings, :hello, captures}, _turn, state) do
        name = case Map.get(captures, "name", "") do
          "" -> "World"
          name -> name
        end

        case Spectre.Agent.render_prompt(__MODULE__, :hello, %{name: name}) do
          {:ok, text} -> {:ok, Map.put(state, :draft, String.trim(text))}
          {:error, reason} -> {:error, reason, state}
        end
      end

      def handle_turn({:greetings, :help, _captures}, _turn, state),
        do: {:ok, Map.put(state, :draft, "Say hello or hello Ada.")}

      # These are application choices, not hidden Router fallbacks.
      def handle_turn({:greetings, :no_match, _input}, _turn, state),
        do: {:error, :unrecognized_message, state}

      def handle_turn({:greetings, :ambiguous, _rules}, _turn, state),
        do: {:error, :clarification_needed, state}

      def handle_turn({:greetings, :error, reason}, _turn, state),
        do: {:error, reason, state}
    end
    """
  end

  defp contract_test(name) do
    path = Macro.underscore(name)

    """
    defmodule #{name}Test do
      use ExUnit.Case, async: true

      alias #{name}, as: Hello
      alias Spectre.Agent

      test "greeting grammar, phrase matching and misses retain their meaning" do
        assert {:ok, flow} = Spectre.Eval.prepare(Hello, "greetings")
        assert {:ok, %{failed: 0, total: 5}} =
                 Spectre.Eval.run_file(flow, Path.join(__DIR__, #{inspect(Path.basename(path) <> "_routes.jsonl")}))
      end

      test "the same routed handler renders a local draft without a model" do
        assert {:ok, state} = Hello.init(%{})

        # This pure callback does not use a sealed Turn. It cannot submit an
        # Act; real ingress and Instance integration remain host responsibilities.
        for {input, text} <- [{"hello Ada", "Hello, Ada!"}, {"hi", "Hello, World!"}] do
          assert {:ok, message} = Agent.route_message(Hello, "greetings", input)
          assert {:ok, %{draft: ^text}} = Hello.handle_turn(message, nil, state)
        end

        assert {:ok, message} = Agent.route_message(Hello, "greetings", "refund")
        assert {:error, :unrecognized_message, ^state} =
                 Hello.handle_turn(message, nil, state)
      end
    end
    """
  end

  defp cases do
    ~S"""
    {"input":"hello Ada","expected":{"status":"matched","rule":"greetings/hello","via":"regex"}}
    {"input":"hi","expected":{"status":"matched","rule":"greetings/hello"}}
    {"input":"HELLO André!","expected":{"status":"matched","rule":"greetings/hello"}}
    {"input":"what can you do","expected":{"status":"matched","rule":"greetings/help","via":"string_bag"}}
    {"input":"refund order 42","expected":{"status":"no_match"}}
    """
  end
end
