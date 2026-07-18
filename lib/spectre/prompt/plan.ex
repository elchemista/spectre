defmodule Spectre.Prompt.Plan do
  @moduledoc """
  Pure, typed prompt composition plan.

  Operations are resolved outside this module. The plan applies scoped
  start/end/replace semantics independently to instructions, context, and task
  sections, then serializes those sections for the current string LLM adapter.
  """

  alias Spectre.Prompt.Fragment
  alias Spectre.Prompt.Operation

  @targets [:instructions, :context, :task]

  defstruct protected: [],
            instructions: [],
            context: [],
            examples: [],
            task: [],
            operations: [],
            metadata: %{},
            rendered: ""

  @type resolution :: %{
          required(:operation) => Operation.t(),
          required(:status) => :applied | :skipped | :failed,
          optional(:content) => String.t(),
          optional(:reason) => term(),
          optional(:metadata) => map()
        }

  @type t :: %__MODULE__{
          protected: [Fragment.t()],
          instructions: [Fragment.t()],
          context: [Fragment.t()],
          examples: [Fragment.t()],
          task: [Fragment.t()],
          operations: [map()],
          metadata: map(),
          rendered: String.t()
        }

  @doc """
  Composes a base task and resolved operations across an outer-to-inner scope
  path.
  """
  @spec compose(String.t(), [resolution()], [term()]) :: {:ok, t()} | {:error, term()}
  def compose(base_task, resolutions, scopes)
      when is_binary(base_task) and is_list(resolutions) and is_list(scopes) do
    applied = Enum.filter(resolutions, &(&1.status == :applied))

    case validate_replacements(applied) do
      :ok -> {:ok, compose_plan(base_task, applied, resolutions, scopes)}
      {:error, _reason} = error -> error
    end
  end

  @spec compose_plan(String.t(), [resolution()], [resolution()], [term()]) :: t()
  defp compose_plan(base_task, applied, resolutions, scopes) do
    fragments = Enum.map(applied, &fragment/1)
    sections = resolve_sections(base_task, fragments, scopes)
    rendered = render_sections(sections)
    operations = Enum.map(resolutions, &resolution_summary/1)

    %__MODULE__{
      instructions: Map.fetch!(sections, :instructions),
      context: Map.fetch!(sections, :context),
      task: Map.fetch!(sections, :task),
      operations: operations,
      rendered: rendered,
      metadata: %{
        hash: hash(rendered),
        bytes: byte_size(rendered),
        operations: operations
      }
    }
  end

  @spec resolve_sections(String.t(), [Fragment.t()], [term()]) :: map()
  defp resolve_sections(base_task, fragments, scopes) do
    Map.new(@targets, fn target ->
      inner = if target == :task, do: [Fragment.base(base_task)], else: []
      {target, resolve_target(target, fragments, scopes, inner)}
    end)
  end

  @doc """
  Returns privacy-safe metadata for a resolved plan.
  """
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = plan), do: plan.metadata

  @spec validate_replacements([resolution()]) :: :ok | {:error, term()}
  defp validate_replacements(resolutions) do
    duplicate =
      resolutions
      |> Enum.filter(&(&1.operation.position == :replace))
      |> Enum.group_by(&{&1.operation.scope, &1.operation.target})
      |> Enum.find(fn {_key, operations} -> length(operations) > 1 end)

    case duplicate do
      nil -> :ok
      {{scope, target}, _operations} -> {:error, {:multiple_prompt_replacements, scope, target}}
    end
  end

  @spec fragment(resolution()) :: Fragment.t()
  defp fragment(%{operation: operation, content: content} = resolution) do
    Fragment.new(operation, content, Map.get(resolution, :metadata, %{}))
  end

  @spec resolve_target(atom(), [Fragment.t()], [term()], [Fragment.t()]) :: [Fragment.t()]
  defp resolve_target(target, fragments, scopes, inner) do
    scopes
    |> Enum.reverse()
    |> Enum.reduce(inner, fn scope, content ->
      scoped = Enum.filter(fragments, &(&1.scope == scope and &1.target == target))
      starts = Enum.filter(scoped, &(&1.position == :start))
      ends = Enum.filter(scoped, &(&1.position == :end))
      replacement = Enum.find(scoped, &(&1.position == :replace))
      starts ++ List.wrap(replacement || content) ++ ends
    end)
  end

  @spec render_sections(map()) :: String.t()
  defp render_sections(sections) do
    @targets
    |> Enum.flat_map(&Map.fetch!(sections, &1))
    |> Enum.map(& &1.content)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @spec resolution_summary(resolution()) :: map()
  defp resolution_summary(%{operation: operation, status: status} = resolution) do
    base = %{
      id: operation.id,
      scope: operation.scope,
      target: operation.target,
      position: operation.position,
      trust: operation.trust,
      status: status,
      required?: operation.required?
    }

    base
    |> maybe_put(:reason, reason_code(Map.get(resolution, :reason)))
    |> Map.merge(Map.take(Map.get(resolution, :metadata, %{}), [:bytes, :duration_us]))
  end

  @spec maybe_put(map(), atom(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec reason_code(term()) :: atom() | nil
  defp reason_code(nil), do: nil
  defp reason_code(reason) when is_atom(reason), do: reason

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> code
      _other -> :prompt_operation_failed
    end
  end

  defp reason_code(%{kind: kind}) when is_atom(kind), do: kind
  defp reason_code(_reason), do: :prompt_operation_failed

  @spec hash(String.t()) :: String.t()
  defp hash(rendered) do
    rendered
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
