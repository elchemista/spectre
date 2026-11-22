defmodule Example.LocalModel do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl true
  def complete(prompt, _options) do
    case Regex.run(~r/^Message: (.+)$/m, prompt) do
      [_, "simulate provider failure"] -> {:error, :unavailable}
      [_, message] -> {:ok, "Hello, #{message}!"}
      nil -> {:error, :missing_chat_message}
    end
  end
end

defmodule Example.ChatServer do
  use Spectre.Server, prompt_root: Path.join(__DIR__, "prompts")

  @impl true
  def handle_flow(:unmatched, _input, ctx), do: generate(ctx, :chat)
end

defmodule Example.HelloAgent do
  use Spectre.Agent, server: Example.ChatServer

  model(Example.LocalModel)
end

defmodule Example.Documents.Flow do
  use Spectre.Flow.Port

  @impl true
  def routes, do: [on(:read, regex: ~r/^show document (?<id>D[0-9]+)$/i)]

  @impl true
  def handle_flow(:read, _input, %{routing: %{params: %{"id" => id}}} = ctx),
    do: call_tool(ctx, {:documents, :read}, %{id: id})

  @impl true
  def handle_result(:read, {:ok, document}, ctx), do: respond(ctx, document.title)
end

defmodule Example.Documents do
  use Spectre.Stack.Installable, id: :documents, version: "1.0.0"

  @impl true
  def integration(_config) do
    Spectre.Integration.new()
    |> Spectre.Integration.tool(:read, __MODULE__, args: [id: :string])
    |> Spectre.Integration.flow(:browse, Example.Documents.Flow)
  end

  def prepare(:read, %{id: id}, _context) when is_binary(id), do: {:ok, id}
  def prepare(:read, _input, _context), do: {:error, :invalid_document_id}

  def invoke(:read, "D12", _context), do: {:ok, %{id: "D12", title: "Project brief"}}
  def invoke(:read, _id, _context), do: {:error, :document_not_found}

  def project(:read, result), do: {:ok, result}
end

defmodule Example.DocumentsStack do
  use Spectre.Stack

  install(Example.Documents)
end

defmodule Example.DocumentsAgent do
  use Spectre.Agent, stack: Example.DocumentsStack, server: Example.ChatServer

  model(Example.LocalModel)
  router(strategies: [:regex])
  expose(:documents)
end
