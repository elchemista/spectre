defmodule Spectre.Server.ServicesTest do
  use ExUnit.Case, async: true
  alias Spectre.GAM.Presentation
  alias Spectre.Server.Services

  defmodule Model do
    def complete(prompt, opts) do
      send(opts[:test_pid], {:model_prompt, prompt})
      {:ok, "CONFIRM"}
    end
  end

  defmodule Provider do
    def actions(_), do: [Spectre.Action.Spec.new(name: :same, via: :foreign)]
    def execute(_, _, _), do: raise("planning must never execute a provider")
  end

  defmodule Planner do
    def clean_reply(_text, _ctx, _opts), do: "public text"

    def plan_response(_, _, _) do
      {:ok,
       %{
         reply_text: "the model claims completion",
         actions: [
           Spectre.Action.new(%{name: :same, via: :foreign, args: %{}})
         ]
       }}
    end
  end

  defmodule Definition do
    use Spectre.Agent
    model(Model)
    action_provider(:foreign, Provider)

    flow :support do
      on :PRICING, regex: ~r/^pricing$/ do
        reply("pricing")
      end
    end
  end

  defp context do
    %{
      agent: Definition,
      options: [],
      assigns: %{},
      routing: %{},
      input: %Spectre.Input{text: "yes"},
      memory: nil
    }
  end

  test "pending classifier sees public material while private pending fields stay outside its prompt" do
    {:ok, presentation} =
      Presentation.new(%{
        candidate_binding_ref: "candidate:binding",
        scope_ref: "scope:test",
        recipient_refs: ["principal:test"],
        approval_source_refs: ["ingress:test"],
        data: %{"account" => "123"},
        cost: 0,
        purpose_ref: "purpose:delete",
        purpose_params: %{},
        risk: "irreversible",
        reversibility: false,
        alternatives: ["cancel"],
        renderer_ref: "renderer:test",
        rendered_payload: "Delete account 123?",
        prepared_at: 1
      })

    pending = %{presentation: presentation, secret: "DO_NOT_DISCLOSE_INTERNAL_PENDING"}

    request = %{
      input: %Spectre.Input{text: "yes"},
      choices: [:confirm, :reject],
      context: pending
    }

    assert {:classified, :confirm} = Services.classify(request, context(), test_pid: self())
    assert_receive {:model_prompt, prompt}
    assert prompt =~ "Delete account 123?"
    assert prompt =~ "irreversible"
    refute prompt =~ "DO_NOT_DISCLOSE_INTERNAL_PENDING"
  end

  test "generation uses the Server prompt directory and recalled memory" do
    root =
      Path.join(System.tmp_dir!(), "spectre-server-prompts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "pricing.text.heex"), "SERVER_PRICING <%= @memory %>")
    on_exit(fn -> File.rm_rf(root) end)
    context = %{context() | options: [prompt_root: root], memory: "remembered prices"}

    request = %{
      input: context.input,
      prompt: :pricing,
      assigns: %{},
      planning: false,
      stream: false,
      preview: :off
    }

    assert {:generated,
            %{text: "CONFIRM", proposals: [], model_output: "CONFIRM", planning: false}} =
             Services.generate(request, context, test_pid: self())

    assert_receive {:model_prompt, prompt}
    assert prompt =~ "SERVER_PRICING"
    assert prompt =~ "remembered prices"

    assert {:generated, %{text: "public text", model_output: "CONFIRM", planning: false}} =
             Services.generate(request, context, test_pid: self(), action_planner: Planner)
  end

  test "consolidated planning retains the qualified provider, schema and trusted route owner" do
    root =
      Path.join(System.tmp_dir!(), "spectre-server-plan-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.write!(Path.join(root, "understand.text.heex"), "Plan a request")
    on_exit(fn -> File.rm_rf(root) end)
    mount = Spectre.Action.Provider.Mount.new(:foreign, Provider, [])
    route = %Spectre.Route{owner: Definition, scope: :agent}

    ctx = %{
      context()
      | options: [prompt_root: root, action_planner: Planner, action_providers: [mount]],
        routing: %{route: route}
    }

    request = %{
      input: ctx.input,
      prompt: :understand,
      assigns: %{},
      planning: true,
      stream: false,
      preview: :off
    }

    assert {:generated, %{proposals: [proposal], planning: true} = generated} =
             Services.generate(request, ctx, test_pid: self())

    refute Map.has_key?(generated, :model_output)
    assert {:ok, %{actions: [^proposal]}} = Spectre.Server.Planning.prepare("CONFIRM", ctx)

    assert proposal.operation == {:foreign, :same}
    assert proposal.metadata.provider == :foreign
    assert proposal.metadata.owner == Definition
    assert proposal.metadata.scope == :agent
    assert is_binary(proposal.metadata.schema_hash)
    assert_receive {:model_prompt, _}
  end

  test "invalid classifier choices and missing response templates preserve typed failure" do
    assert {:error, :no_llm_classifier_labels} =
             Services.classify(
               %{input: context().input, choices: [], context: "Pending question"},
               context(),
               []
             )

    assert {:error, _} = Services.respond(:a_missing_template, context(), [])
    refute_receive {:model_prompt, _}
  end

  test "scoped operation identity and schema drift are checked before a binding can execute" do
    alias Spectre.Server.Catalog
    action = Spectre.Action.new(%{name: :same, via: :foreign})
    first = {:skill, :first}
    second = {:skill, :second}
    assert Catalog.operation(action, first) != Catalog.operation(action, second)

    metadata = %{
      owner: Definition,
      scope: first,
      provider: :foreign,
      schema_hash: Spectre.Action.Spec.new(name: :same, via: :foreign).schema_hash
    }

    ctx = %{context() | routing: %{route: %Spectre.Route{owner: Definition, scope: first}}}
    assert :ok = Catalog.validate({first, :foreign, :same}, metadata, %{}, ctx)

    assert {:error, :proposal_scope_binding_required} =
             Catalog.validate(:same, metadata, %{}, ctx)

    assert {:error, :proposal_scope_binding_required} =
             Catalog.validate({second, :foreign, :same}, metadata, %{}, ctx)

    assert {:error, :proposal_schema_mismatch} =
             Catalog.validate(
               {first, :foreign, :same},
               metadata,
               %{schema_hash: "new-schema"},
               ctx
             )
  end
end
