defmodule Spectre.Server.PlanningBoundariesTest do
  use ExUnit.Case, async: true

  alias Spectre.Server.{Catalog, Context, Plan, PublicProjection}

  defmodule Projection do
    @behaviour PublicProjection
    def init(opts), do: Keyword.fetch!(opts, :init)
    def push(_text, state), do: state
    def finish(state), do: state
  end

  defmodule LocalActions do
    def __spectre_actions__, do: [Spectre.Action.Spec.new(name: :price, via: :local)]
    def price(_), do: raise("catalog validation must not execute an action")
  end

  defmodule Agent do
    use Spectre.Agent
  end

  defmodule App do
    use Spectre.Server
  end

  test "a malformed later proposal rejects the whole plan before the first command" do
    assert_raise ArgumentError, "invalid consolidated plan proposal", fn ->
      Plan.start(%Context{}, [%{operation: :price, args: %{}}, %{operation: :delete}])
    end
  end

  test "a successful final effect completes once and an ambiguous effect stops the plan" do
    completed = Plan.continue(%Context{}, [], {:governed, %{outcome: %{status: :succeeded}}})
    assert [%{kind: :respond, args: ["The operation completed."]}] = completed.commands

    waiting =
      Plan.continue(
        %Context{},
        [%{operation: :delete, args: %{}}],
        {:governed, %{outcome: %{status: :ambiguous}}}
      )

    assert [%{kind: :respond, args: ["The operation is still under verification."]}] =
             waiting.commands
  end

  test "uncertain plan continuations wait for an actual outcome before advancing" do
    remaining = [%{operation: :delete, args: %{}}]

    for result <- [
          {:governed, %{act: %{ref: "act:one"}, outcome: nil}},
          {:governed_unknown, %{command_id: "one"}}
        ] do
      pending = App.handle_result({Plan, remaining}, result, %Context{})

      assert [%{kind: :respond, args: ["The operation is still under verification."]}] =
               pending.commands
    end

    settled =
      App.handle_result(
        {Plan, remaining},
        {:governed, %{outcome: %{status: :succeeded}}},
        %Context{}
      )

    assert [%{kind: :propose, args: [:delete, %{}]}] = settled.commands
  end

  test "a refused decision with no Act does not become an uncertain execution" do
    refused = {:governed, %{decision: %{outcome: :refused}, act: nil, outcome: nil}}
    result = App.handle_result({Plan, [%{operation: :delete, args: %{}}]}, refused, %Context{})

    assert [%{kind: :respond, args: ["The operation could not be confirmed."]}] = result.commands
  end

  test "projection startup rejects malformed adapters and preserves explicit failures" do
    assert {:error, :invalid_public_projection} = PublicProjection.open(%{})

    assert {:error, :projection_unavailable} =
             PublicProjection.open({Projection, init: {:error, :projection_unavailable}})

    assert {:error, :invalid_public_projection_init} =
             PublicProjection.open({Projection, init: :wrong_reply})
  end

  test "projection failures never become public text during push or terminal flush" do
    assert {:error, :redaction_failed} =
             PublicProjection.push({Projection, {:error, :redaction_failed}}, "private")

    assert {:error, :redaction_failed} =
             PublicProjection.finish({Projection, {:error, :redaction_failed}})

    assert {:error, :invalid_public_projection_reply} =
             PublicProjection.push({Projection, {:ok, :not_text, nil}}, "private")

    assert {:error, :invalid_public_projection_reply} =
             PublicProjection.finish({Projection, {:ok, :not_text}})
  end

  test "agent action proposals require a current schema or an explicit trusted binding schema" do
    context = %{agent: Agent, options: [], routing: %{}}
    metadata = %{scope: :agent, owner: Agent, schema_hash: "host-contract"}
    assert :ok = Catalog.validate(:price, metadata, %{schema_hash: "host-contract"}, context)

    assert {:error, :proposal_schema_required} =
             Catalog.validate(:price, Map.delete(metadata, :schema_hash), %{}, context)

    assert {:error, :proposal_provider_unavailable} =
             Catalog.validate({:missing_provider, :price}, metadata, %{}, context)

    schema = Spectre.Action.Spec.new(name: :price, via: :local).schema_hash
    local = %{context | options: [actions: LocalActions]}
    assert :ok = Catalog.validate(:price, %{metadata | schema_hash: schema}, %{}, local)

    assert {:error, :proposal_schema_mismatch} =
             Catalog.validate(:price, metadata, %{}, local)
  end

  test "a host local provider override is the same catalog used for planning and admission" do
    context = %Spectre.Context{agent: Agent, opts: [actions: LocalActions]}
    opts = Catalog.planner_options(context)
    assert [%{id: :local, opts: provider_opts}] = opts[:action_providers]
    assert provider_opts[:module] == LocalActions
    assert opts[:effect_owner] == Agent
    assert opts[:effect_scope] == :agent
  end
end
