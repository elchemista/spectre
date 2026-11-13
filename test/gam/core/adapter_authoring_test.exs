Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.CoreTest.AdapterAuthoringTest do
  use ExUnit.Case, async: false

  alias Spectre.GAM.{Audit, Ledger, Mind}
  alias Spectre.GAM.V04Test.{Fixture, Runtime}

  defmodule StatefulMind do
    @ref "mind:authoring:stateful"
    use Spectre.GAM.Mind, ref: @ref, stateful: true

    @impl true
    def deliberate(turn, state, opts) do
      send(Keyword.fetch!(opts, :observer), {:deliberated, turn, state, opts})
      Keyword.get(opts, :reply, {:ok, [], (state || 0) + 1})
    end
  end

  defmodule StatelessMind do
    use Spectre.GAM.Mind, ref: "mind:authoring:stateless"

    @impl true
    def deliberate(_turn, opts), do: {:ok, Keyword.get(opts, :candidates, [])}
  end

  defmodule OverriddenMind do
    use Spectre.GAM.Mind, ref: "mind:unused", stateful: true

    @impl true
    def ref, do: "mind:authoring:overridden"

    @impl true
    def deliberate(_turn, _opts), do: {:error, :stateless_not_supported}

    @impl true
    def deliberate(_turn, state, _opts), do: {:ok, [], state}
  end

  defmodule Ingress do
    use Spectre.GAM.Ingress, ref: "ingress:authoring"

    @impl true
    def authenticate(_domain, _scope, _input, _generation, _opts),
      do: {:error, :credentials_required}

    @impl true
    def observe(_context, _input, _now, _opts), do: {:error, :observation_required}
  end

  defmodule Executor do
    use Spectre.GAM.Attempt.Executor,
      executor_ref: "executor:authoring",
      contract_ref: "contract:authoring:v1"

    @impl true
    def execute(_act, _attempt, _capability, _opts),
      do: {:error, :ambiguous, %{evidence: [], details_ref: "receipt:unavailable"}}
  end

  defmodule Broker do
    use Spectre.GAM.Secret.Broker, ref: "broker:authoring", profile: :development

    @impl true
    def checkout(_receipt, _act, _attempt, _opts),
      do: {:error, :ambiguous, %{evidence: [], details_ref: "receipt:no-credential"}}
  end

  setup context do
    Runtime.reset(Fixture.default_now())
    namespace = "adapter-authoring"
    domain_ref = "v0.4:#{namespace}:domain"

    fixture =
      Fixture.start_domain(
        namespace: namespace,
        name: {:via, Registry, {Spectre.GAM.Domain.Registry, domain_ref}},
        mind: Map.get(context, :mind, StatefulMind)
      )

    on_exit(fn -> Fixture.stop_domain(fixture) end)
    {:ok, domain} = Spectre.GAM.lookup_domain(domain_ref)
    {:ok, scope} = Spectre.GAM.resume_scope(domain, Fixture.context(fixture))
    input = fixture |> Fixture.paid_evidence() |> Map.from_struct() |> Map.delete(:ref)
    %{fixture: fixture, scope: scope, input: input}
  end

  test "stateful bridge keeps options distinct from nil and explicit local state", c do
    assert {:ok, {StatefulMind, "mind:authoring:stateful"}} = Mind.resolve(StatefulMind)

    assert {:ok, %{candidates: [], turn: first}} =
             Spectre.GAM.turn(c.scope, c.input, mind_opts: [observer: self(), message: "first"])

    assert_receive {:deliberated, ^first, nil, [observer: _, message: "first"]}

    assert {:ok, %{candidates: [], state: 8, turn: second}} =
             Spectre.GAM.turn(c.scope, c.input, 7, mind_opts: [observer: self()])

    assert_receive {:deliberated, ^second, 7, [observer: _]}
    assert {:ok, []} = Spectre.GAM.acts(c.scope)
    assert {:ok, snapshot} = Ledger.load(c.fixture.store_config, c.fixture.refs.domain)
    assert {:ok, _report} = Audit.verify(snapshot, c.fixture.constitution, Runtime.now())
  end

  @tag mind: StatelessMind
  test "stateless helper uses the existing runtime bridge without changing state", c do
    refute function_exported?(StatelessMind, :deliberate, 3)

    assert {:ok, %{candidates: [], state: %{count: 7}}} =
             Spectre.GAM.turn(c.scope, c.input, %{count: 7}, [])
  end

  @tag mind: StatelessMind
  test "helpers cannot bypass sealed candidate scope validation", c do
    original = Fixture.refund_candidate(c.fixture, 1)

    {:ok, wrong} =
      original
      |> Map.put(:scope_ref, "scope:foreign")
      |> Spectre.GAM.Candidate.new()

    assert {:error, {:mind_candidate_scope_mismatch, _, _}} =
             Spectre.GAM.turn(c.scope, c.input, mind_opts: [candidates: [wrong]])

    assert {:ok, []} = Spectre.GAM.acts(c.scope)
  end

  test "a malformed stateful result does not become a valid stateless reply", c do
    assert {:error, {:invalid_stateful_mind_result, StatefulMind}} =
             Spectre.GAM.turn(c.scope, c.input, mind_opts: [observer: self(), reply: {:ok, []}])

    assert {:error, :needs_clarification} =
             Spectre.GAM.turn(c.scope, c.input,
               mind_opts: [observer: self(), reply: {:error, :needs_clarification}]
             )
  end

  @tag mind: OverriddenMind
  test "identity and stateless bridge can be explicitly overridden", c do
    assert {:ok, {OverriddenMind, "mind:authoring:overridden"}} = Mind.resolve(OverriddenMind)
    assert {:error, :stateless_not_supported} = Spectre.GAM.turn(c.scope, c.input)
    assert {:ok, %{candidates: [], state: 42}} = Spectre.GAM.turn(c.scope, c.input, 42, [])
  end

  test "identity helpers neither authenticate nor perform successful effects" do
    assert {:ok, {Ingress, "ingress:authoring"}} = Spectre.GAM.Ingress.resolve(Ingress)
    assert {:error, :credentials_required} = Ingress.authenticate(nil, nil, nil, nil, [])
    assert {:error, :observation_required} = Ingress.observe(nil, nil, nil, [])
    assert Executor.executor_ref() == "executor:authoring"
    assert Executor.contract_ref() == "contract:authoring:v1"
    assert {:error, :ambiguous, _} = Executor.execute(nil, nil, nil, [])
    assert Broker.ref() == "broker:authoring"
    assert Broker.profile() == :development
    assert {:error, :ambiguous, _} = Broker.checkout(nil, nil, nil, [])
  end

  test "missing identities and contracts are compile-time configuration errors" do
    for {behaviour, opts} <- [
          {Spectre.GAM.Mind, []},
          {Spectre.GAM.Ingress, []},
          {Spectre.GAM.Attempt.Executor, [executor_ref: "executor:only"]},
          {Spectre.GAM.Secret.Broker, [profile: :mediated]}
        ] do
      assert_raise KeyError, fn -> compile_adapter(behaviour, opts) end
    end
  end

  test "invalid identities, hidden routing options and undeclared profiles fail compilation" do
    for {behaviour, opts} <- [
          {Spectre.GAM.Mind, [ref: nil]},
          {Spectre.GAM.Ingress, [ref: ""]},
          {Spectre.GAM.Attempt.Executor, [executor_ref: "e", contract_ref: 7]},
          {Spectre.GAM.Secret.Broker, [ref: "b"]},
          {Spectre.GAM.Secret.Broker, [ref: "b", profile: :secure]},
          {Spectre.GAM.Mind, [ref: "m", stateful: :yes]},
          {Spectre.GAM.Mind, [ref: "m", route_on: "user.message"]}
        ] do
      assert_raise ArgumentError, fn -> compile_adapter(behaviour, opts) end
    end
  end

  test "an optional argument on stateful deliberate cannot silently replace the bridge" do
    assert_raise CompileError, fn ->
      Code.compile_string("""
      defmodule Spectre.GAM.InvalidDefaultMind do
        use Spectre.GAM.Mind, ref: "mind:invalid", stateful: true
        def deliberate(_turn, state, _opts \\\\ []), do: {:ok, [], state}
      end
      """)
    end
  end

  defp compile_adapter(behaviour, opts) do
    Code.compile_quoted(
      quote do
        defmodule Spectre.GAM.InvalidAuthoringAdapter do
          use unquote(behaviour), unquote(Macro.escape(opts))
        end
      end
    )
  end
end
