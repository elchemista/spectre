defmodule Spectre.Test.Documentation do
  @moduledoc false
  import ExUnit.Callbacks, only: [on_exit: 1]

  @root Path.expand("../..", __DIR__)
  @blocks ~r/(?:<!-- spectre:example (\w+) -->\n)?```elixir\n(.*?)\n```/s

  # Every Elixir fence in the published guides needs an executable test context.
  # Removing a marker must fail, not silently reduce the examples being tested.
  def examples! do
    examples =
      for source <- Mix.Project.config()[:docs][:extras],
          example <- parse!(File.read!(Path.join(@root, source)), source),
          do: example

    names = Enum.map(examples, & &1.name)
    if names != Enum.uniq(names), do: raise("Duplicate documentation example names")
    Map.new(examples, &{&1.name, &1})
  end

  def parse!(markdown, source) do
    for [_block, name, code] <- Regex.scan(@blocks, markdown) do
      if name == "", do: raise("Unverified Elixir example in #{source}")
      %{name: name, code: code, file: Path.join(@root, source)}
    end
  end

  def eval!(name, binding \\ [], opts \\ []) do
    example = Map.fetch!(examples!(), name)
    code = wrap(example.code, opts[:within])
    file = Keyword.get(opts, :file, example.file)
    ast = Code.string_to_quoted!(code, file: file)
    register_cleanup(ast)
    Code.eval_quoted(ast, binding, file: file)
  end

  defp wrap(code, nil), do: code

  defp wrap(code, module) do
    """
    defmodule #{inspect(module)} do
      use Spectre.Agent, namespace: "guide", name: #{inspect(inspect(module))}
      #{code}
    end
    """
  end

  defp register_cleanup(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _, [{:__aliases__, _, parts}, _]} = node, modules ->
          {node, [Module.concat(parts) | modules]}

        node, modules ->
          {node, modules}
      end)

    on_exit(fn ->
      for module <- modules do
        :code.purge(module)
        :code.delete(module)
      end
    end)
  end
end
