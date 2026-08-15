defmodule Spectre.Prompt.AssetAudit do
  @moduledoc false

  alias Spectre.Definition
  alias Spectre.Skill.Mount

  @tainted_assign ~r/@(input|recent_chat|memory)(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*/
  @output_expression ~r/<%=\s*(.*?)\s*%>/s
  @safe_data_expression ~r/^\s*Spectre\.Prompt\.data\(\s*@(input|recent_chat|memory)(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*\s*\)\s*$/

  @spec audit(Definition.t()) :: {:ok, [map()]} | {:error, term()}
  def audit(%Definition{} = definition) do
    definition
    |> roots()
    |> Enum.reduce_while({:ok, []}, fn root, {:ok, findings} ->
      case audit_root(root) do
        {:ok, root_findings} -> {:cont, {:ok, root_findings ++ findings}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, findings} -> {:ok, Enum.sort_by(findings, &{&1.path, &1.line})}
      {:error, _reason} = error -> error
    end
  end

  defp roots(definition) do
    agent = [%{scope: :agent, root: definition.prompt_root}]

    skills =
      Enum.flat_map(definition.skills, fn %Mount{} = mount ->
        case Definition.fetch(mount.module) do
          {:ok, skill} -> [%{scope: Mount.scope(mount), root: skill.prompt_root}]
          {:error, _reason} -> []
        end
      end)

    Enum.uniq_by(agent ++ skills, &{&1.scope, Path.expand(&1.root)})
  end

  defp audit_root(%{root: root} = entry) when is_binary(root) do
    expanded = Path.expand(root)

    if File.dir?(expanded) do
      audit_assets(expanded, entry.scope)
    else
      {:ok, []}
    end
  end

  defp audit_assets(root, scope) do
    root
    |> Path.join("**/*.text.heex")
    |> Path.wildcard(match_dot: false)
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, findings} ->
      case audit_asset(path, scope) do
        {:ok, found} -> {:cont, {:ok, found ++ findings}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp audit_asset(path, scope) do
    case File.read(path) do
      {:ok, content} -> {:ok, unsafe_expressions(content, path, scope)}
      {:error, reason} -> {:error, {:prompt_asset_audit_read_failed, path, reason}}
    end
  end

  defp unsafe_expressions(content, path, scope) do
    Regex.scan(@output_expression, content, return: :index, capture: :all_but_first)
    |> Enum.flat_map(fn [{offset, length}] ->
      expression = binary_part(content, offset, length)
      assigns = tainted_assigns(expression)

      if assigns == [] or Regex.match?(@safe_data_expression, expression) do
        []
      else
        [
          %{
            scope: scope,
            path: path,
            line: line_number(content, offset),
            assigns: assigns
          }
        ]
      end
    end)
  end

  defp tainted_assigns(expression) do
    @tainted_assign
    |> Regex.scan(expression, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp line_number(content, offset) do
    content
    |> binary_part(0, offset)
    |> :binary.matches("\n")
    |> length()
    |> Kernel.+(1)
  end
end
