defmodule Spectre.Core.RouterExtensionTest do
  use ExUnit.Case, async: true

  alias Spectre.{Agent, Definition, Extension, Router}
  alias Spectre.Agent.Flow
  alias Spectre.Router.Rule

  defmodule BinaryMatcher do
    use Spectre.Router.Adapter

    @impl true
    def evaluate(request, opts) do
      if opts[:observer], do: send(opts[:observer], {:matcher_request, request})
      {:ok, for(rule <- request.rules, rule.data == request.input, do: result(rule, 1.0))}
    end
  end

  defmodule ReplyMatcher do
    use Spectre.Router.Adapter
    @impl true
    def evaluate(_request, opts), do: Keyword.fetch!(opts, :reply)
  end

  defmodule CrashingMatcher do
    use Spectre.Router.Adapter
    @impl true
    def evaluate(_request, _opts), do: raise("private raw input and credentials")
  end

  defmodule PreparedMatcher do
    use Spectre.Router.Adapter
    @impl true
    def prepare(data, opts) do
      send(opts[:observer], {:prepared, data})
      {:ok, {:compiled, data}}
    end

    @impl true
    def evaluate(request, _opts) do
      {:ok,
       for(rule <- request.rules, rule.data == {:compiled, request.input}, do: result(rule, 1))}
    end
  end

  defmodule ConfigurablePrepareMatcher do
    use Spectre.Router.Adapter

    @impl true
    def prepare(_data, opts), do: Keyword.fetch!(opts, :prepare_reply)

    @impl true
    def evaluate(_request, _opts), do: {:ok, []}
  end

  defmodule Package do
    @behaviour Spectre.Extension
    @impl true
    def configure(opts),
      do: {:ok, %{data: %{version: 1}, ports: %{{:router, :binary} => {BinaryMatcher, opts}}}}
  end

  defmodule Billing do
    use Spectre.Skill, namespace: "router-test", name: "billing"
    use Spectre.Test.Authoring
    install(Package, [])
    request(:refund, class: "refund.issue")
    prompt(:instructions, "Offer a proposal, never promise execution.")

    flow :refunds do
      router(via: [:binary, :regex])
      route(:refund, match: [regex: ~r/^refund (?<amount>[0-9]+)$/u, binary: <<1, 2>>])
    end
  end

  defmodule Bundle do
    use Spectre.Skill, namespace: "router-test", name: "bundle"
    use Spectre.Test.Authoring
    skill(Billing, as: :billing)
  end

  defmodule Assistant do
    use Spectre.Agent, namespace: "router-test", name: "assistant"
    use Spectre.Test.Authoring
    skill(Bundle, as: :support)
  end

  defmodule WrongContribution do
    @behaviour Spectre.Extension
    @impl true
    def configure(_opts), do: %{ports: %{}}
  end

  defmodule WrongPorts do
    @behaviour Spectre.Extension
    @impl true
    def configure(_opts),
      do: {:ok, %{ports: %{{:router, :binary} => {BinaryMatcher, [:invalid]}}}}
  end

  test "an ordinary custom method is mounted through an Extension and Skill namespace" do
    assert %{module: BinaryMatcher, options: []} =
             Assistant.ports()["support/billing/router/binary"]

    {:ok, flow} =
      Agent.flow(Assistant.definition(), "support/billing/refunds",
        adapters: [binary: BinaryMatcher]
      )

    assert {:ok, %{candidate: "refund", rule: "support/billing/refunds/refund", via: "binary"}} =
             Flow.route(flow, <<1, 2>>)

    assert {:ok, %{matched: %{"amount" => "37"}}} = Flow.route(flow, "refund 37")
  end

  test "transport retains declarative ports but does not install or invoke them" do
    original = Assistant.definition()
    assert {:ok, restored} = original |> Definition.canonical() |> Definition.from_canonical()
    assert restored === original
    assert {:ok, _, components} = Agent.declarations(restored)
    assert components["support/billing"] == Billing.definition().ref

    assert {:error, {:unknown_router_method, "binary"}} =
             Agent.flow(restored, "support/billing/refunds")

    refute_receive {:matcher_request, _}
  end

  test "matcher sees no Candidate target or another method's rule data" do
    assert {:ok, router} =
             Router.new(
               %{
                 "match" => %{
                   to: "private/executor-template",
                   match: %{binary: "yes", regex: "private-pattern"}
                 },
                 "hidden" => %{to: "secret", match: %{regex: "secret-pattern"}}
               },
               via: [:binary],
               adapters: [binary: {BinaryMatcher, observer: self()}]
             )

    assert {:ok, _} = Router.route(router, "yes")
    assert_receive {:matcher_request, request}
    assert Map.from_struct(request) == %{input: "yes", rules: [%{ref: "match", data: "yes"}]}
  end

  test "custom preparation occurs once while repeated routing only evaluates" do
    assert {:ok, router} =
             Router.new(rule(),
               via: [:binary],
               adapters: [binary: {PreparedMatcher, observer: self()}]
             )

    assert_receive {:prepared, "yes"}
    assert {:ok, first} = Router.route(router, "yes")
    assert {:ok, ^first} = Router.route(router, "yes")
    refute_receive {:prepared, _}
  end

  test "string bag matches normalized Unicode and whitespace" do
    assert {:ok, router} =
             Router.new(%{"coffee" => %{to: "serve", match: %{string_bag: ["café please"]}}},
               via: [:string_bag]
             )

    assert {:ok, result} = Router.route(router, "  CAFE\u0301   PLEASE ")
    assert result.score == 1.0
    assert result.via == "string_bag"
  end

  test "Jaro and bag_distance are reusable local methods" do
    for method <- [:jaro, :bag_distance] do
      assert {:ok, router} =
               Router.new(%{"refund" => %{to: "refund", match: %{method => ["money back"]}}},
                 via: [method]
               )

      assert {:ok, selected} = Router.route(router, "money back")
      assert selected.via == Atom.to_string(method)
      assert selected.score == 1.0
    end
  end

  test "two exact regex matches are ambiguous, independent of map iteration order" do
    rules = %{"b" => %{to: "b", match: %{regex: ".*"}}, "a" => %{to: "a", match: %{regex: ".*"}}}
    assert {:ok, router} = Router.new(rules, via: [:regex])
    assert {:ambiguous, ["a", "b"]} = Router.route(router, "anything")
  end

  test "an ambiguous method can defer to a later unique matcher" do
    rules = %{
      "a" => %{to: "a", match: %{regex: ".*", binary: "yes"}},
      "b" => %{to: "b", match: %{regex: ".*"}}
    }

    assert {:ok, router} =
             Router.new(rules, via: [:regex, :binary], adapters: [binary: BinaryMatcher])

    assert {:ok, %{candidate: "a", via: "binary"}} = Router.route(router, "yes")
    assert {:ambiguous, ["a", "b"]} = Router.route(router, "no")
  end

  test "strict lead and acceptance thresholds prevent weak or tied nominations" do
    rules = %{"a" => %{to: "a", match: %{binary: "x"}}, "b" => %{to: "b", match: %{binary: "x"}}}
    reply = {:ok, [%{rule: "a", score: 0.9}, %{rule: "b", score: 0.85}]}

    assert {:ok, router} =
             Router.new(rules,
               via: [:binary],
               margin: 0.1,
               adapters: [binary: {ReplyMatcher, reply: reply}]
             )

    assert {:ambiguous, ["a", "b"]} = Router.route(router, "x")

    assert {:ok, router} =
             Router.new(rules,
               via: [:binary],
               accept: 0.95,
               adapters: [binary: {ReplyMatcher, reply: reply}]
             )

    assert :no_match = Router.route(router, "x")
  end

  test "a matcher cannot nominate an existing but invisible rule" do
    rules = Map.put(rule(), "hidden", %{to: "admin", match: %{regex: ".*"}})
    reply = {:ok, [%{rule: "hidden", score: 1}]}

    assert {:ok, router} =
             Router.new(rules, via: [:binary], adapters: [binary: {ReplyMatcher, reply: reply}])

    assert {:error, :invalid_router_nomination} = Router.route(router, "yes")
  end

  test "oversized or duplicate result sets cannot smuggle extra nominations" do
    for results <- [
          List.duplicate(%{rule: "match", score: 1}, 2),
          List.duplicate(%{rule: "match", score: 1}, 33)
        ] do
      assert {:error, _} = route_reply({:ok, results})
    end
  end

  test "adapter scores and reply envelopes are validated rather than coerced" do
    for reply <- [
          :ok,
          nil,
          {:ok, %{}},
          {:ok, [:invalid]},
          {:ok, [%{rule: "match", score: "1"}]},
          {:ok, [%{rule: "match", score: -1}]},
          {:ok, [%{rule: "match", score: 2}]}
        ] do
      assert {:error, _} = route_reply(reply)
    end
  end

  test "adapter diagnostics cannot carry capabilities or unbounded input copies" do
    for matched <- [self(), fn -> :power end, make_ref(), String.duplicate("x", 5000)] do
      assert {:error, _} = route_reply({:ok, [%{rule: "match", score: 1, matched: matched}]})
    end

    assert {:error, _} = route_reply({:ok, [%{rule: "match", score: 1, executor: "forged"}]})
  end

  test "failures are explicit and exceptions do not leak details" do
    assert {:error, :backend_unavailable} = route_reply({:error, :backend_unavailable})
    assert {:ok, router} = Router.new(rule(), via: [:binary], adapters: [binary: CrashingMatcher])

    assert {:error, {:adapter_callback_exception, CrashingMatcher, :evaluate, RuntimeError}} =
             Router.route(router, "secret")
  end

  test "skip and an empty result are genuine misses" do
    assert :no_match = route_reply(:skip)
    assert :no_match = route_reply({:ok, []})
  end

  test "registry refuses duplicate aliases, built-in overrides and unknown methods" do
    assert {:error, _} =
             Router.new(rule(),
               via: [:binary],
               adapters: [binary: BinaryMatcher, binary: ReplyMatcher]
             )

    assert {:error, _} = Router.new(rule(), adapters: [regex: BinaryMatcher])
    assert {:error, _} = Router.new(rule(), via: [:missing])

    assert {:error, _} =
             Router.new(rule(),
               via: [:binary],
               adapters: %{"binary" => ReplyMatcher, binary: BinaryMatcher}
             )
  end

  test "malformed configuration and method data do not crash" do
    for opts <- [
          [via: []],
          [via: [:regex, "regex"]],
          [via: [:regex | :improper]],
          [accept: 1.1],
          [margin: -1],
          [adapters: [:bad]]
        ] do
      assert {:error, _} = Router.new(rule(), opts)
    end

    for data <- ["[", %{"source" => ".*", "options" => "invalid"}, %{source: 1, options: ""}] do
      assert {:error, _} = Router.new(%{"a" => %{to: "a", match: %{regex: data}}}, via: [:regex])
    end
  end

  test "the router grammar rejects malformed rules and preparation replies at construction" do
    assert {:ok, empty} = Router.new(%{})
    assert :no_match = Router.route(empty, "anything")
    assert {:error, :invalid_router_rules} = Router.rules(nil)

    for attrs <- [
          [to: "target", match: []],
          [to: "target", match: [:not_a_keyword]],
          [to: "target", match: nil],
          [to: "target", match: %{nil => "value"}]
        ] do
      assert {:error, _reason} = Rule.new("rule", attrs)
    end

    assert {:error, {:invalid_declaration_path, 42}} = Rule.path(42)
    assert {:error, :invalid_router_method} = Rule.method(nil)

    assert {:error, :invalid_router_adapter_options} =
             Router.new(rule(),
               via: [:binary],
               adapters: [binary: {BinaryMatcher, [:not_a_keyword]}]
             )

    assert {:error, _reason} =
             Router.new(rule(), via: [:binary], adapters: [binary: String])

    for reply <- [:invalid, {:error, :cannot_prepare}] do
      assert {:error, _reason} =
               Router.new(rule(),
                 via: [:binary],
                 adapters: [
                   binary: {ConfigurablePrepareMatcher, prepare_reply: reply}
                 ]
               )
    end
  end

  test "input limits and malformed UTF-8 are rejected before scoring" do
    assert {:ok, router} =
             Router.new(%{"a" => %{to: "a", match: %{string_bag: "yes"}}}, via: [:string_bag])

    assert {:error, _} = Router.route(router, String.duplicate("x", 65_537))
    assert {:error, :invalid_router_text} = Router.route(router, <<255>>)
    assert {:error, _} = Router.route(router, %{grant: self()})
  end

  test "normalized rule method aliases cannot collide or create atoms" do
    assert {:error, _} = Rule.new("a", to: "a", match: %{"regex" => "x", regex: ".*"})
    id = "new-method-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Rule.new("a", to: "a", match: %{id => "x"})
    assert_raise ArgumentError, fn -> String.to_existing_atom(id) end
  end

  test "changing route data changes the Definition and invalidates the loaded code pin" do
    original = Billing.definition()

    body =
      put_in(
        original.body,
        ["authoring", "plan", :flows, "refunds", :routes, "refund", :rule, "match", "binary"],
        <<3>>
      )

    {:ok, revised} = Definition.revise(original, body, 1)
    refute revised.ref == original.ref
    assert {:error, _} = Agent.verify_definition(Billing, revised)
    {:ok, first} = Agent.flow(original, "refunds", adapters: [binary: BinaryMatcher])
    {:ok, second} = Agent.flow(revised, "refunds", adapters: [binary: BinaryMatcher])
    assert {:ok, _} = Flow.route(first, <<1, 2>>)
    assert :no_match = Flow.route(second, <<1, 2>>)
    assert {:ok, _} = Flow.route(second, <<3>>)
  end

  test "stored route targets and configuration cannot bypass the compiled grammar" do
    original = Billing.definition()

    body =
      put_in(
        original.body,
        ["authoring", "plan", :flows, "refunds", :routes, "refund", :rule, "to"],
        "admin"
      )

    {:ok, revised} = Definition.revise(original, body, 1)
    assert {:error, _} = Agent.declarations(revised)
    assert {:error, _} = Agent.flow(original, "refunds", via: [:regex])
  end

  test "extension contributions and port options are validated at the shared boundary" do
    assert {:error, :invalid_extension_reply} = Extension.configure(WrongContribution, [])
    assert {:error, _} = Extension.configure(WrongPorts, [])
    assert {:error, _} = Extension.configure(Package, [:bad])
    assert {:ok, %{ports: ports}} = Extension.configure(Package, [])
    assert ports[{:router, :binary}] == {BinaryMatcher, []}
  end

  test "duplicate extensions and misplaced routes fail compilation" do
    assert_raise CompileError, fn ->
      compile(
        quote do
          install(unquote(Package), [])
          install(unquote(Package), [])
        end
      )
    end

    assert_raise CompileError, fn ->
      compile(quote do: route(:bad, match: [regex: ".*"]))
    end
  end

  defp rule, do: %{"match" => %{to: "proposal", match: %{binary: "yes"}}}

  defp route_reply(reply) do
    {:ok, router} =
      Router.new(rule(), via: [:binary], adapters: [binary: {ReplyMatcher, reply: reply}])

    Router.route(router, "yes")
  end

  defp compile(body) do
    module = Module.concat(__MODULE__, "Compiled#{System.unique_integer([:positive])}")

    Module.create(
      module,
      quote do
        use Spectre.Agent, namespace: "router-test", name: "compiled"
        unquote(body)
      end,
      Macro.Env.location(__ENV__)
    )
  end
end
