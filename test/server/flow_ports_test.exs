defmodule Spectre.Server.FlowPortsTest do
  use ExUnit.Case, async: true

  alias Spectre.Server

  @timeout 5_000

  defmodule DocumentFlow do
    use Spectre.Flow.Port

    @impl true
    def routes do
      [
        on(:read, regex: ~r/^mostrami il documento(?: (?<id>D[0-9]+))?$/i, protected: true),
        on(:publish, regex: ~r/^pubblica (?<id>D[0-9]+)$/i, protected: true)
      ]
    end

    @impl true
    def handle_flow(:read, _input, %{routing: %{protected: true, params: params}} = ctx) do
      case params do
        %{"id" => "D" <> _ = id} -> load_document(ctx, id)
        _ -> ask_for_document(ctx)
      end
    end

    def handle_flow(:publish, _input, %{routing: %{params: %{"id" => id}}} = ctx),
      do: call_tool(ctx, {:documents, :publish}, %{id: id}, on_result: :publication)

    @impl true
    def handle_result(:document_id, {:ok, input}, ctx), do: load_document(ctx, input.text)

    def handle_result(:document, {:ok, document}, ctx), do: respond(ctx, document.title)

    def handle_result(
          :publication,
          {:governed, %{outcome: %{status: :succeeded}}},
          %{routing: %{params: %{"id" => id}}} = ctx
        ),
        do: respond(ctx, "Pubblicato #{id}")

    defp ask_for_document(ctx) do
      await_input(ctx, :document_id,
        accept: ~r/^D[0-9]+$/i,
        prompt: "Quale documento?",
        timeout: 5_000
      )
    end

    defp load_document(ctx, id),
      do: call_tool(ctx, {:documents, :read}, %{id: id}, on_result: :document)
  end

  defmodule AttachmentFlow do
    use Spectre.Flow.Port

    @impl true
    def routes, do: [on(:attachment, regex: ~r/^mostrami allegato$/i, protected: true)]

    @impl true
    def handle_flow(:attachment, input, ctx), do: DocumentFlow.handle_flow(:read, input, ctx)

    @impl true
    def handle_result(:document, {:ok, document}, ctx),
      do: respond(ctx, "Allegato #{document.title}")

    def handle_result(tag, result, ctx), do: DocumentFlow.handle_result(tag, result, ctx)
  end

  defmodule Documents do
    use Spectre.Stack.Installable, id: :documents, version: "1.0.0"

    @behaviour Spectre.Server.GAM.EffectAdapter

    @impl true
    def integration(_config) do
      Spectre.Integration.new()
      |> Spectre.Integration.tool(:read, __MODULE__, args: [id: :string])
      |> Spectre.Integration.tool(:publish, __MODULE__, args: [id: :string], governed: :publish)
      |> Spectre.Integration.flow(:browse, DocumentFlow)
      |> Spectre.Integration.flow(:attachments, AttachmentFlow)
    end

    @impl Spectre.Stack.Installable
    def effects(_config) do
      %{
        publish: %{
          contract: 1,
          adapter: __MODULE__,
          operation: :publish,
          side_effect: :idempotent,
          material: :arguments,
          partition: [:subject],
          schema_hash: nil,
          config: %{}
        }
      }
    end

    def prepare(:read, %{id: id}, %{routing: %{protected: true}}), do: {:ok, id}
    def prepare(:publish, %{id: _} = args, _context), do: {:ok, args}
    def invoke(:read, id, _context), do: {:ok, %{title: "Documento #{id}"}}
    def project(_operation, result), do: {:ok, result}

    @impl Spectre.Server.GAM.EffectAdapter
    def execute_effect(:publish, %{id: id}, _context), do: {:ok, %{published: id}}
  end

  defmodule Stack do
    use Spectre.Stack
    install(Documents)
  end

  defmodule Root do
    use Spectre.Server

    def handle_flow({:general, :guide}, _input, ctx), do: respond(ctx, "Guida del Root")

    def handle_result(tag, _result, ctx), do: respond(ctx, "Risultato del Root: #{inspect(tag)}")
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: Root
    router(strategies: [:regex])

    expose(flows: [{:documents, :browse}, {:documents, :attachments}])

    flow :general do
      on(:guide, regex: ~r/^apri la guida$/i)
    end
  end

  test "the selected Flow owns its capture, protection and tool continuation" do
    root = start_root()

    assert {:ok, turn} = Server.input(root, "mostrami il documento D12")
    assert_receive {Server, ^root, {:response, ^turn, "Documento D12", _}}, @timeout
  end

  test "a confirmed governed tool result returns to the Flow that proposed it" do
    root =
      start_root(
        identity: %{subject: "publication"},
        gam: [operations: %{publish: [confirm: true]}]
      )

    assert {:ok, turn} = Server.input(root, "pubblica D12")

    assert_receive {Server.GAM.Managed, _owner,
                    {:presentation, %{"presentation_ref" => presentation}}},
                   @timeout

    assert :ok = Server.presented(root, presentation)
    assert_receive {Server, ^root, {:pending, ^turn, _}}, @timeout
    refute_received {Server, ^root, {:response, _, "Pubblicato D12", _}}

    assert {:ok, decision} = Server.decide(root, nil, presentation, :confirm)
    assert_receive {Server, ^root, {:response, ^decision, "Pubblicato D12", _}}, @timeout
    refute_received {Server, ^root, {:response, _, "Risultato del Root: :publication", _}}
  end

  test "a matching ordinary follow-up resolves the focused Flow wait" do
    root = start_root()
    _wait = ask_for_document(root)

    assert {:ok, answer} = Server.input(root, "D12")
    assert_receive {Server, ^root, {:response, ^answer, "Documento D12", _}}, @timeout
  end

  test "a matcher miss routes once and the original Flow still accepts a targeted answer" do
    root = start_root()
    %{id: id, revision: revision} = ask_for_document(root)

    assert {:ok, guide} = Server.input(root, "Apri la guida")
    assert_receive {Server, ^root, {:response, ^guide, "Guida del Root", _}}, @timeout
    refute_received {Server, ^root, {:response, ^guide, _, _}}

    target = {id, revision}
    assert {:ok, answer} = Server.input(root, "D34", pending: target)
    assert_receive {Server, ^root, {:response, ^answer, "Documento D34", _}}, @timeout
    assert {:error, :stale_pending} = Server.input(root, "D56", pending: target)
  end

  test "two Flow scopes can use the same local wait name" do
    root = start_root()
    first = ask_for_document(root)
    second = ask_for_document(root, "Mostrami allegato")
    refute first.id == second.id

    assert {:ok, document} = Server.input(root, "D12", pending: {first.id, first.revision})
    assert_receive {Server, ^root, {:response, ^document, "Documento D12", _}}, @timeout

    assert {:ok, attachment} = Server.input(root, "D34", pending: {second.id, second.revision})

    assert_receive {Server, ^root, {:response, ^attachment, "Allegato Documento D34", _}},
                   @timeout
  end

  @tag :tmp_dir
  test "a restored Flow wait keeps its original owner and reply target", %{tmp_dir: directory} do
    opts = [
      agent: Agent,
      consumer: self(),
      identity: %{subject: "documents"},
      gam: [storage: {:disk, directory}]
    ]

    assert {:ok, original} = Server.start_link(opts)
    %{id: id, revision: revision} = ask_for_document(original)
    assert :ok = GenServer.stop(original)

    assert {:ok, restored} = Server.start_link(opts)
    assert {:ok, answer} = Server.input(restored, "D12", pending: {id, revision})
    assert_receive {Server, ^restored, {:response, ^answer, "Documento D12", _}}, @timeout
    assert :ok = GenServer.stop(restored)
  end

  defp start_root(overrides \\ []) do
    opts = Keyword.merge([agent: Agent, consumer: self()], overrides)
    start_supervised!({Server, opts})
  end

  defp ask_for_document(root, text \\ "Mostrami il documento") do
    assert {:ok, _} = Server.input(root, text)

    assert_receive {Server, ^root,
                    {:waiting_input, %{id: id, revision: rev, prompt: "Quale documento?"} = wait}},
                   @timeout

    assert is_binary(id)
    assert is_integer(rev)
    wait
  end
end
