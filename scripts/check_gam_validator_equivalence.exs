defmodule Spectre.GAM.ValidatorEquivalenceCheck do
  @moduledoc false

  def run do
    for file <- ["decision.ex", "act.ex"] do
      {source, 0} = System.cmd("git", ["show", "6906258:lib/spectre/core/#{file}"])
      original = source |> then(&Regex.replace(~r/\bSpectre\b/, &1, "Spectre.GAM")) |> parse()
      imported = "lib/spectre/gam/#{file}" |> File.read!() |> parse()
      before = definitions(original)
      after_refactor = definitions(imported)
      {argument, old_body} = Map.fetch!(before, :validate_refs)
      {^argument, new_body} = Map.fetch!(after_refactor, :validate_refs)
      old_checks = expand(old_body, before, argument)
      new_checks = expand(new_body, after_refactor, argument)

      unless old_checks == new_checks,
        do: raise("#{file}: validation expressions or lazy order changed")

      unless without_validators(original) == without_validators(imported),
        do: raise("#{file}: unrelated kernel AST changed")

      IO.inspect(%{file: file, ordered_lazy_checks: length(old_checks), equivalent: true})
    end
  end

  defp parse(source) do
    source
    |> Code.string_to_quoted!()
    |> Macro.prewalk(fn
      {form, metadata, arguments} when is_list(metadata) -> {form, [], arguments}
      other -> other
    end)
  end

  defp definitions(ast) do
    {_, definitions} =
      Macro.prewalk(ast, %{}, fn
        {:defp, _, [{name, _, [argument]}, [do: body]]} = node, definitions ->
          {node, Map.put(definitions, name, {argument, body})}

        node, definitions ->
          {node, definitions}
      end)

    definitions
  end

  defp expand({:with, _, clauses}, definitions, argument) do
    {[do: tail], prefix} = List.pop_at(clauses, -1)

    Enum.flat_map(prefix, fn {:<-, _, [:ok, check]} ->
      expand(check, definitions, argument)
    end) ++ expand(tail, definitions, argument)
  end

  defp expand({name, _, [argument]} = call, definitions, argument) when is_atom(name) do
    if helper?(name) do
      {^argument, body} = Map.fetch!(definitions, name)
      expand(body, definitions, argument)
    else
      [call]
    end
  end

  defp expand(check, _definitions, _argument), do: [check]

  defp without_validators(ast) do
    Macro.prewalk(ast, fn
      {:__block__, metadata, expressions} ->
        expressions =
          Enum.reject(expressions, fn
            {:defp, _, [{name, _, [_]}, _]} -> name == :validate_refs or helper?(name)
            _ -> false
          end)

        {:__block__, metadata, expressions}

      node ->
        node
    end)
  end

  defp helper?(name), do: String.starts_with?(Atom.to_string(name), "validate_refs_group_")
end

Spectre.GAM.ValidatorEquivalenceCheck.run()
