defmodule Spectre.Agents.GenHostTaskTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  alias Mix.Tasks.Spectre.Gen.{Agent, Host}
  alias Spectre.Domain.Sequencer
  alias Spectre.Test.DocumentationRuntime
  alias Spectre.V04Test.{Fixture, Runtime}

  @moduletag :tmp_dir

  defmodule Existing do
    use Spectre.Agent, namespace: "host-scaffold", name: "existing"
  end

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.IO)
    on_exit(fn -> Mix.shell(previous) end)
  end

  test "dry-run and invalid classes cannot write, overwrite or generate intrinsic authority", c do
    File.cd!(c.tmp_dir, fn ->
      args = [inspect(Existing), "--class", "greeting.save"]
      assert capture_io(fn -> Host.run(args ++ ["--dry-run"]) end) =~ "would create"
      assert File.ls!() == []

      for class <- ["", "definition.revise", "data.erase", "mandate.delegate"] do
        assert_raise Mix.Error, fn -> Host.run([inspect(Existing), "--class", class]) end
      end

      assert_raise Mix.Error, fn -> Host.run([inspect(Existing)]) end
      assert_raise Mix.Error, fn -> Host.run(["../Escape", "--class", "greeting.save"]) end
      assert_raise Mix.Error, fn -> Host.run(["Uncompiled.HostExample", "--class", "save"]) end
      assert_raise Mix.Error, fn -> Host.run(["String", "--class", "save"]) end
      assert_raise OptionParser.ParseError, fn -> Host.run(args ++ ["--force"]) end
      assert File.ls!() == []

      path = "lib/" <> Macro.underscore(inspect(Existing))
      File.mkdir_p!(path)
      File.ln_s!("missing", path <> "/executor.ex")
      assert_raise Mix.Error, ~r/refusing to overwrite/, fn -> Host.run(args) end
      refute File.exists?(path <> "/host.ex")
      refute File.exists?("test")
    end)
  end

  test "incomplete scaffold compiles, preserves the Agent, and its own tests fail with a checklist",
       c do
    ebin = Path.expand(Mix.Project.compile_path())

    File.cd!(c.tmp_dir, fn ->
      {name, path} = generate_agent()
      original = File.read!("lib/#{path}.ex")
      output = capture_io(fn -> Host.run([name, "--class", "greeting.save"]) end)
      assert output =~ "Manual change"
      assert output =~ "request :save_greeting"
      assert File.read!("lib/#{path}.ex") === original

      script = """
      ExUnit.start(autorun: false)
      Code.compile_file("lib/#{path}/router.ex")
      Code.compile_file("lib/#{path}.ex")
      Code.compile_file("lib/#{path}/executor.ex")
      Code.compile_file("lib/#{path}/host.ex")
      missing = #{name}.Host.missing_setup()
      {:error, {:incomplete_host_setup, ^missing}} = #{name}.Host.domain_options()
      true = Keyword.has_key?(missing, :genesis)
      Code.require_file("test/#{path}_governed_test.exs")
      result = ExUnit.run()
      nil = Process.whereis(Spectre.Domain.Registry)
      System.halt(if result.total == 2 and result.failures == 2 and result.skipped == 0, do: 0, else: 1)
      """

      {output, status} =
        System.cmd("elixir", ["-pa", ebin, "-e", script],
          stderr_to_stdout: true,
          env: [{"ERL_FLAGS", "+S 2:2"}]
        )

      assert status == 0, output
      assert output =~ "genesis"
      assert output =~ "executor"
    end)
  end

  test "completed generated code and its actual integration test save once through GAM", c do
    Runtime.reset(Fixture.default_now())

    File.cd!(c.tmp_dir, fn ->
      {name, path} = generate_agent()
      capture_io(fn -> Host.run([name, "--class", "greeting.save"]) end)
      # This test owns the host adaptations. The generator never edits the
      # user's Agent or guesses a Foundation. Exercise its output, not a copy.
      source = File.read!("lib/#{path}.ex")

      source =
        String.replace(
          source,
          "@impl true\n",
          "request :save_greeting, class: \"greeting.save\"\n\n@impl true\n",
          global: false
        )

      source =
        String.replace(
          source,
          "{:ok, Map.put(state, :draft, String.trim(text))}",
          "{:request, :save_greeting, %{\"target_ref\" => state.greeting_box_ref, \"text\" => String.trim(text)}, state}"
        )

      source =
        source
        |> Code.string_to_quoted!()
        |> Macro.postwalk(fn
          {:defmodule, meta, [module, [do: {:__block__, block_meta, definitions}]]} ->
            callback =
              quote do
                @impl true
                def handle_result({:request, :save_greeting}, result, _turn, state),
                  do: {:ok, Map.put(state, :last_save_status, result.status)}
              end

            {:defmodule, meta,
             [module, [do: {:__block__, block_meta, definitions ++ [callback]}]]}

          node ->
            node
        end)
        |> Macro.to_string()

      unload(String.to_existing_atom("Elixir." <> name))
      [{agent, _} | _] = compile(source, "lib/#{path}.ex")
      definition = agent.definition(revision: 1, declared_at: Runtime.now())

      executor_source =
        File.read!("lib/#{path}/executor.ex")
        |> replace_function(
          :configuration,
          quote do
            [
              executor_ref: Spectre.V04Test.Executor.executor_ref(),
              contract_ref: Spectre.V04Test.Executor.contract_ref(),
              execute: &unquote(__MODULE__).save/4
            ]
          end
        )

      [{executor, _}] = compile(executor_source)
      [{host, _}] = compile(File.read!("lib/#{path}/host.ex"))
      {:ok, surface} = host.application_surface(1)
      backend = start_supervised!({Elixir.Agent, fn -> %{count: 0, values: %{}} end})
      fixture = fixture(definition, surface, executor, backend)
      {:ok, domain} = Spectre.lookup_domain(fixture.refs.domain)
      {:ok, scope} = Spectre.resume_scope(domain, Fixture.context(fixture))

      {:ok, admin} =
        Spectre.resume_scope(
          domain,
          Fixture.context(fixture,
            authenticated_principal_ref: fixture.refs.grantor
          )
        )

      assert {:ok, %{primary: %{decision: %{outcome: :admitted}}}} =
               Spectre.revise_definition(admin, definition,
                 identity_key: "publish-greeting",
                 requested_mandate_ref: fixture.governance_mandate.ref,
                 accountable_ref: fixture.refs.accountable,
                 purpose_ref: fixture.refs.purpose,
                 purpose_params: %{"currency" => "EUR"}
               )

      config = completed_configuration(fixture)
      Process.put(:generated_host_configuration, config)

      host_source =
        File.read!("lib/#{path}/host.ex")
        |> replace_function(
          :configuration,
          quote(do: Process.get(:generated_host_configuration))
        )

      # Unload before recompiling deliberate test edits, avoiding redefine warnings.
      unload(host)
      compile(host_source)
      assert [] == host.missing_setup()
      assert {:ok, options} = host.domain_options()
      assert options[:genesis] === fixture.genesis
      assert options[:root_mandates] === fixture.sequencer_opts[:root_mandates]

      [mandate] = fixture.additional_mandates

      bindings =
        host.bindings(
          requested_mandate_ref: mandate.ref,
          accountable_ref: fixture.refs.accountable,
          purpose_ref: fixture.refs.purpose,
          purpose_params: %{"currency" => "EUR"},
          observation_window_ms: 5_000
        )

      instance_options = [
        scope: scope,
        definition: definition,
        bindings: bindings,
        state: %{greeting_box_ref: "greeting-box:allowed"}
      ]

      context = %{
        instance_options: instance_options,
        constitution: fixture.constitution,
        now: &Runtime.now/0,
        execution_count: fn -> Elixir.Agent.get(backend, & &1.count) end,
        read_greeting: fn ->
          Elixir.Agent.get(backend, &Map.fetch(&1.values, "greeting-box:allowed"))
        end,
        export: fn -> Spectre.Ledger.export(fixture.store_config, fixture.refs.domain) end
      }

      Process.put(:generated_host_context, context)

      test_source =
        File.read!("test/#{path}_governed_test.exs")
        |> String.replace(
          "use ExUnit.Case, async: false",
          "use ExUnit.Case, async: false, register: false"
        )
        |> replace_function(
          :integration_context,
          quote(do: {:ok, Process.get(:generated_host_context)})
        )

      [{test_module, _}] = compile(test_source)
      for test <- test_module.__ex_unit__().tests, do: apply(test_module, test.name, [%{}])
      assert_receive {:saved_greeting, _, _}

      # A perfect route and the same executor binding do not authorize another target.
      opts = Keyword.put(instance_options, :state, %{greeting_box_ref: "greeting-box:outside"})
      denied = start_supervised!(Supervisor.child_spec({agent, opts}, id: :denied_greeting))
      assert {:ok, %{requests: [request]}} = agent.turn(denied, "hello Ada", flow: :greetings)
      assert {:ok, %{result: %{status: :refused}}} = Spectre.Instance.advance(denied, request)
      assert context.execution_count.() == 1
      refute_received {:saved_greeting, _, _}

      # Removing an entry cannot make the checklist falsely complete.
      Process.put(:generated_host_configuration, Keyword.delete(config, :genesis_verifier))
      assert [{:genesis_verifier, _}] = host.missing_setup()
      assert {:error, {:incomplete_host_setup, _}} = host.domain_options()
    end)
  end

  def save(act, attempt, _capability, opts) do
    projection = Sequencer.projection(opts[:domain])
    assert projection.acts[act.ref] === act
    assert projection.attempts[attempt.ref] === attempt
    target = act.consequence["target_ref"]
    text = act.consequence["text"]

    :ok =
      Elixir.Agent.update(opts[:backend], fn state ->
        %{count: state.count + 1, values: Map.put(state.values, target, text)}
      end)

    send(opts[:observer], {:saved_greeting, act, attempt})

    {:ok, evidence} =
      Spectre.Attempt.Executor.outcome_evidence(act, attempt, :succeeded, Runtime.now(),
        payload: %{"saved_target" => target}
      )

    {:ok, %{evidence: [evidence], details_ref: "receipt:" <> attempt.ref}}
  end

  defp generate_agent do
    name = "Scaffold.HostHello#{System.unique_integer([:positive])}"
    path = Macro.underscore(name)
    capture_io(fn -> Agent.run([name]) end)
    compile(File.read!("lib/#{path}/router.ex"))
    # Preserve __DIR__ so compiled prompts come from the generated folder.
    modules = Code.compile_file("lib/#{path}.ex")
    on_exit(fn -> Enum.each(modules, fn {module, _} -> unload(module) end) end)
    {name, path}
  end

  defp fixture(definition, surface, executor, backend) do
    namespace = "generated-host-#{System.unique_integer([:positive])}"
    server = {:via, Registry, {Spectre.Domain.Registry, "v0.4:#{namespace}:domain"}}

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: server,
        mind: Spectre.Agent,
        ingress: DocumentationRuntime.Ingress,
        executors: [{executor, backend: backend, observer: self(), domain: server}],
        governance_allowed: true,
        governance_classes: ["definition.revise"],
        governance_targets: [definition.ref],
        governance_declarations: surface.declarations,
        consequence_contracts: surface.consequence_contracts,
        additional_mandates: fn root ->
          attrs =
            root
            |> Map.from_struct()
            |> Map.delete(:ref)
            |> Map.merge(%{
              ceiling: surface.declarations["greeting.save"],
              classes: ["greeting.save"],
              conditions: [],
              meters: %{},
              subject_refs: [],
              target_refs: ["greeting-box:allowed"]
            })

          {:ok, mandate} = Spectre.Mandate.new(attrs)
          [mandate]
        end
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    fixture
  end

  defp completed_configuration(fixture) do
    fixture.sequencer_opts
    |> Keyword.take([
      :domain_ref,
      :constitution,
      :principals,
      :root_mandates,
      :surface,
      :host_profile,
      :genesis_verifier,
      :store,
      :ingress,
      :broker,
      :clock
    ])
    |> Keyword.put(:executor_options, [])
    |> Keyword.put(
      :genesis,
      Map.take(
        fixture.genesis,
        [:ref, :issued_at, :attestation_ref, :emergency_mandate_ref]
      )
    )
  end

  defp replace_function(source, function, body) do
    source
    |> Code.string_to_quoted!()
    |> Macro.postwalk(fn
      {kind, meta, [{^function, args_meta, args}, [do: _old]]}
      when kind in [:def, :defp] and args in [nil, []] ->
        {kind, meta, [{function, args_meta, args}, [do: body]]}

      node ->
        node
    end)
    |> Macro.to_string()
  end

  defp compile(source, path \\ "nofile") do
    modules = Code.compile_string(source, path)
    on_exit(fn -> Enum.each(modules, fn {module, _} -> unload(module) end) end)
    modules
  end

  defp unload(module) do
    :code.purge(module)
    :code.delete(module)
  end
end
