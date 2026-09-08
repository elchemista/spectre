defmodule Mix.Tasks.Spectre.Gen.Host do
  @moduledoc """
  Generates an opt-in host scaffold for a first governed greeting save.

      mix spectre.gen.host MyApp.Hello --class greeting.save --dry-run
      mix spectre.gen.host MyApp.Hello --class greeting.save

  Requires an already compiled Agent. Writes Host, Executor and an integration
  test; does not patch the Agent, application configuration or supervisor.
  Prints the manual handler change. The class is explicit; renaming it does
  not turn this greeting example into an arbitrary payment or delivery adapter.

  Generated modules compile, but TODOs block domain options before startup.
  The integration test deliberately fails with the missing setup checklist.
  Complete it with your own authorities, authentication and backend. Nothing
  grants permissions, generates credentials or starts a service on your behalf.
  An existing Domain can reuse just the class and request binding functions;
  do not bootstrap another Domain for every agent.

  Files are created exclusively, with all-target preflight and no `--force`.
  Dry-run neither writes nor compiles. Normal generation compiles the host
  project but never starts its application.
  """
  use Mix.Task
  alias Spectre.{Adapter, GovernedAct.Class, Portable}
  alias Spectre.Mix.Scaffold
  @shortdoc "Generate explicit host wiring and a first governed Act test"

  @impl Mix.Task
  def run(args) do
    {opts, names} = OptionParser.parse!(args, strict: [dry_run: :boolean, class: :string])

    name =
      Scaffold.module_name!(
        names,
        "usage: mix spectre.gen.host MyApp.Hello --class greeting.save"
      )

    class = opts[:class]

    unless Portable.validate_ref(class, :class) == :ok and not Class.intrinsic?(class),
      do: Mix.raise("--class must name an explicit application class, not an intrinsic GAM class")

    unless opts[:dry_run], do: Mix.Task.run("compile")
    validate_agent!(name)
    path = Macro.underscore(name)

    Scaffold.write(
      [
        {"lib/#{path}/host.ex", host(name, class)},
        {"lib/#{path}/executor.ex", executor(name)},
        {"test/#{path}_governed_test.exs", integration_test(name)}
      ],
      opts[:dry_run]
    )

    Mix.shell().info(
      "Complete #{name}.Host.configuration/0 and #{name}.Executor.configuration/0."
    )

    Mix.shell().info("Then complete test/#{path}_governed_test.exs; no tests are skipped.")

    Mix.shell().info(
      "Manual change inside #{name} (existing files were not patched):\n" <> handler(class)
    )
  end

  defp validate_agent!(name) do
    module = existing_module!(name)

    with :ok <- Adapter.validate(module, __spectre_plan__: 0),
         %{kind: :agent} <- module.__spectre_plan__() do
      :ok
    else
      _invalid -> Mix.raise("expected an already compiled Spectre.Agent: #{name}")
    end
  end

  defp existing_module!(name) do
    String.to_existing_atom("Elixir." <> name)
  rescue
    ArgumentError -> Mix.raise("compile the Agent before generating its host: #{name}")
  end

  defp host(name, class) do
    """
    defmodule #{name}.Host do
      @moduledoc \"\"\"
      Application-owned setup for #{class}: saving a greeting is not delivery.

      Complete configuration, including a full Surface with this application
      class and the governance classes needed to open Scopes/activate Definitions.
      Root Mandates must reference your chosen Genesis anchor. Keep credentials
      out of portable records. Foundation.new derives links, not permissions.

      After domain_options/0 succeeds, supervise the chosen store before
      {Spectre.Domain, opts}. Authenticate/open a Scope and activate the Agent's
      exact Definition through the existing governance APIs. Only then start
      #{name} with scope, definition, bindings and state.greeting_box_ref.
      An existing Domain instead revises its Surface/Definition under authority;
      it does not create another Genesis. See the host-setup guide.
      \"\"\"
      alias #{name}.Executor

      @foundation_keys [:genesis, :constitution, :principals, :root_mandates, :surface, :host_profile]
      @runtime_keys [:domain_ref, :store, :ingress, :broker, :clock, :genesis_verifier]

      @doc "Explicit setup values; replace TODO values, never delete required entries."
      def configuration do
        [
          domain_ref: {:todo, "choose the shared authority boundary"},
          genesis: {:todo, "ref, issued_at, attestation_ref and explicit emergency_mandate_ref"},
          constitution: {:todo, "Duty rules and independent disposition authorities"},
          principals: {:todo, "identified grantors, proposers, executors and accountable parties"},
          root_mandates: {:todo, "explicit holders, classes, targets, purposes, expiry and limits"},
          surface: {:todo, "combine application_surface/1 with required governance classes"},
          host_profile: {:todo, "declare the mediated boundary and broker profile"},
          genesis_verifier: {:todo, "external recognition of the exact Genesis attestation"},
          store: {:todo, "already supervised ledger store handle"},
          ingress: {:todo, "real caller authentication and input observation"},
          broker: {:todo, "capability broker matching the HostProfile"},
          clock: {:todo, "trusted clock adapter"},
          executor_options: {:todo, "backend options; [] only if none are needed"}
        ]
      end

      @doc "Remaining scaffold TODOs, not a certificate of authority or backend readiness."
      def missing_setup do
        missing_setup(configuration())
      end

      defp missing_setup(config) do
        host = incomplete(config, @foundation_keys ++ @runtime_keys ++ [:executor_options])
        executor = for {key, instruction} <- incomplete(Executor.configuration(),
          [:executor_ref, :contract_ref, :execute]),
          do: {{:executor, key}, instruction}
        host ++ executor
      end

      defp incomplete(config, keys) do
        for key <- keys,
            {:todo, instruction} <- [Keyword.get(config, key, {:todo, "required entry is missing"})],
            do: {key, instruction}
      end

      @doc "Validates the completed foundation without starting processes or calling the backend."
      def domain_options do
        config = configuration()
        case missing_setup(config) do
          [] ->
            records = Keyword.take(config, @foundation_keys)

            with {:ok, foundation} <- Spectre.Foundation.new(Keyword.fetch!(config, :domain_ref), records) do
              runtime = for key <- @runtime_keys,
                do: {key, Keyword.fetch!(config, key)}
              {:ok, foundation ++ runtime ++ [mind: Spectre.Agent,
                executors: [{Executor, Keyword.fetch!(config, :executor_options)}]]}
            end

          missing -> {:error, {:incomplete_host_setup, missing}}
        end
      end

      @doc "Application class fragment only: merge deliberately into the Domain's full Surface."
      def application_surface(revision) do
        with {:ok, row} <- Spectre.Row.new(attempt: true, write: true),
             {:ok, contract} <- Spectre.Consequence.Contract.new(
               shape: %{"target_ref" => "target_ref", "text" => "string"}) do
          Spectre.Surface.new(revision: revision,
            declarations: %{#{inspect(class)} => row},
            consequence_contracts: %{#{inspect(class)} => contract})
        end
      end

      @doc \"\"\"
      Bind the host's existing permission and purpose; no authority is created.
      Supply requested_mandate_ref, accountable_ref, purpose_ref, purpose_params
      and observation_window_ms explicitly. The latter is not a backend timeout.
      Scope, proposer, identity and Row remain fixed by the ordinary builder.
      \"\"\"
      def bindings(authority) do
        attrs = Keyword.validate!(authority, [:requested_mandate_ref, :accountable_ref,
          :purpose_ref, :purpose_params, :observation_window_ms])
        occurrence = attrs |> Map.new()
          |> Map.put(:executor_ref, Executor.executor_ref())
          |> Map.put(:executor_contract_ref, Executor.contract_ref())
        %{#{inspect(class)} => occurrence}
      end
    end
    """
  end

  defp executor(name) do
    """
    defmodule #{name}.Executor do
      @moduledoc \"\"\"
      Application-owned executor. Act and Attempt precede every backend call.

      Set execute to a function of (act, attempt, capability, options), e.g.
      &MyApp.Greetings.save/4, returning Spectre.Attempt.Executor.result().
      That function performs the actual write and builds receipt Evidence with
      Spectre.Attempt.Executor.outcome_evidence/5. Use the capability supplied
      by the broker, never credentials selected from agent input.

      Succeeded means the backend confirmed saving, not that a user received
      anything. Lost responses/timeouts are ambiguous, not definitive_no_effect;
      never retry an uncertain write. Evidence must describe a real receipt,
      and details_ref must not contain credentials or raw provider responses.
      This module installs no storage and defines no new backend behaviour.
      \"\"\"
      @behaviour Spectre.Attempt.Executor

      @doc "Complete these actual callback inputs; Host derives its checklist from them."
      def configuration do
        [
          executor_ref: {:todo, "identified executor Principal"},
          contract_ref: {:todo, "immutable execution contract reference"},
          execute: {:todo, "function of four arguments implementing the real backend write"}
        ]
      end

      @impl true
      def executor_ref, do: Keyword.fetch!(configuration(), :executor_ref)
      @impl true
      def contract_ref, do: Keyword.fetch!(configuration(), :contract_ref)

      @impl true
      def execute(act, attempt, capability, options) do
        # An incomplete callback raises before I/O, never fabricates success.
        # If invoked outside Host's setup, the ordinary Runner still contains
        # its failure as uncertainty rather than granting a retry.
        callback = Keyword.fetch!(configuration(), :execute)
        callback.(act, attempt, capability, options)
      end
    end
    """
  end

  defp integration_test(name) do
    """
    defmodule #{name}GovernedTest do
      use ExUnit.Case, async: false
      alias #{name}, as: Hello
      alias #{name}.Host

      test "host setup has no unfinished scaffold entries" do
        assert [] == Host.missing_setup()
        assert {:ok, _options} = Host.domain_options()
      end

      test "the real router proposes a save and only advance performs it" do
        assert [] == Host.missing_setup()
        assert {:ok, context} = integration_context()
        instance = start_supervised!({Hello, context.instance_options})
        before = context.execution_count.()

        assert {:ok, turn} = Hello.turn(instance, "hello Ada", flow: :greetings)
        assert [request] = turn.requests
        assert context.execution_count.() == before
        assert {:ok, completed} = Spectre.Instance.advance(instance, request)
        assert completed.result.status == :done
        primary = completed.result.details.primary
        assert primary.decision.outcome == :admitted
        assert primary.attempt.act_ref == primary.act.ref
        assert primary.outcome.attempt_ref == primary.attempt.ref
        assert primary.outcome.status == :succeeded
        assert context.execution_count.() == before + 1
        assert {:ok, "Hello, Ada!"} == context.read_greeting.()
        assert {:ok, export} = context.export.()
        assert {:ok, _report} = Spectre.Audit.verify(export, context.constitution, context.now.())
      end

      # Complete with a real test Domain, authentication, governed Definition
      # activation, Host.bindings/1 and a supervised application backend.
      # instance_options includes state: %{greeting_box_ref: your_target}.
      # Supply constitution and now (the test's trusted clock), plus
      # execution_count/read_greeting/export functions observing those
      # resources, never callbacks returning canned success. Use a bounded
      # synchronous test backend for the direct advance assertion above; an
      # asynchronous backend needs a bounded ticket wait, never resubmission.
      defp integration_context do
        {:error, :complete_authenticated_domain_and_backend_test_setup}
      end
    end
    """
  end

  defp handler(class) do
    """
    request :save_greeting, class: #{inspect(class)}

    # In the hello handler, render the existing prompt, then replace the draft return with:
    {:request, :save_greeting,
     %{"target_ref" => state.greeting_box_ref, "text" => String.trim(text)}, state}

    @impl true
    def handle_result({:request, :save_greeting}, result, _turn, state),
      do: {:ok, Map.put(state, :last_save_status, result.status)}

    # Validate greeting_box_ref in init/1. Activate the changed Definition via
    # governance before starting its Instance; a declaration does not activate it.
    """
  end
end
