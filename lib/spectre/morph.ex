defmodule Spectre.Morph do
  @moduledoc """
  Pure, atomic changesets for immutable Definitions, before governance.

      Spectre.Morph.prepare(definition, [
        %{op: :test, path: ["assets", "prompt"], value: "old prompt"},
        %{op: :put, path: ["assets", "prompt"], value: "revised prompt"}
      ], declared_at)

  Changes use `put`, `delete` and exact `test` preconditions. Paths traverse
  maps or zero-based list indices; no module, function, code string or policy
  interpreter is loaded from a changeset. An invalid operation aborts the whole
  preparation. Agent declarations additionally retain schema/route integrity.

  A package can implement `changes/2` and use `from_adapter/4` for reflection,
  optimization or another proposal strategy. That callback receives data, not
  authority. Submit the returned Definition with `Spectre.revise_definition/4`:
  the kernel still checks the exact active predecessor and governance Mandate.
  Neither preparation nor rollback activates code or changes a live Instance.
  """

  alias Spectre.{Adapter, Definition, Portable}
  alias Spectre.Agent.Declaration

  @max_changes 128

  @type change :: map() | keyword()
  @callback changes(Definition.t(), keyword()) :: {:ok, [change()]} | {:error, term()}

  @doc "Applies a bounded changeset atomically to the exact supplied revision."
  @spec prepare(Definition.t(), [change()], integer()) :: {:ok, Definition.t()} | {:error, term()}
  def prepare(current, changes, declared_at) do
    with {:ok, current} <- Definition.new(current),
         :ok <- Portable.validate(changes),
         true <- is_list(changes) and length(changes) <= @max_changes,
         {:ok, body} <- apply_changes(current.body, changes),
         {:ok, revised} <- Definition.revise(current, body, declared_at),
         :ok <- authoring_integrity(current, revised) do
      {:ok, revised}
    else
      false -> {:error, :invalid_morph_changes}
      {:error, _} = error -> error
    end
  end

  @doc "Uses a host-selected transformation adapter to propose, never activate, a revision."
  @spec from_adapter(Definition.t(), module(), keyword(), integer()) ::
          {:ok, Definition.t()} | {:error, term()}
  def from_adapter(current, module, opts, declared_at) do
    with {:ok, current} <- Definition.new(current),
         true <- Portable.keyword?(opts),
         :ok <- Adapter.validate(module, changes: 2),
         {:ok, {:ok, changes}} <- Adapter.invoke(module, :changes, [current, opts]) do
      prepare(current, changes, declared_at)
    else
      false -> {:error, :invalid_morph_options}
      {:ok, {:error, _} = error} -> error
      {:ok, _} -> {:error, :invalid_morph_adapter_reply}
      {:error, _} = error -> error
    end
  end

  @doc "Copies an earlier same-family body into a new forward revision, preserving history."
  @spec rollback(Definition.t(), Definition.t(), integer()) ::
          {:ok, Definition.t()} | {:error, term()}
  def rollback(current, prior, declared_at) do
    with {:ok, current} <- Definition.new(current),
         {:ok, prior} <- Definition.new(prior),
         true <-
           Definition.key(current) === Definition.key(prior) and prior.revision < current.revision do
      prepare(current, [%{op: :put, path: [], value: prior.body}], declared_at)
    else
      false -> {:error, :not_a_prior_definition}
      {:error, _} = error -> error
    end
  end

  @doc """
  Produces a deterministic exact-body changeset for review or later preparation.

  Diffs exceeding the 128-operation budget use one atomic body replacement.
  The result still passes the portable-value limits; large diffs do not build
  an unbounded intermediate list of operations or require partial application.
  """
  @spec diff(Definition.t(), Definition.t()) :: {:ok, [change()]} | {:error, term()}
  def diff(before, after_definition) do
    with {:ok, before} <- Definition.new(before),
         {:ok, after_definition} <- Definition.new(after_definition) do
      changes =
        before.body
        |> differences(after_definition.body, [])
        |> Enum.take(@max_changes + 1)

      changes =
        if length(changes) > @max_changes,
          do: [%{op: :put, path: [], value: after_definition.body}],
          else: changes

      with :ok <- Portable.validate(changes), do: {:ok, changes}
    end
  end

  defp apply_changes(body, changes) do
    changes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, body}, fn {change, index}, {:ok, body} ->
      with {:ok, operation} <- operation(change),
           {:ok, next} <- update(body, operation.path, operation) do
        {:cont, {:ok, next}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_morph_change, index, reason}}}
      end
    end)
  end

  defp operation(change) do
    with {:ok, %{op: op, path: path} = attrs} <-
           Portable.normalize_attrs(change, [:op, :path, :value], :morph_change),
         true <- is_list(path) and length(path) <= 128,
         {:ok, op} <- operation_name(op),
         true <-
           (op == :delete and not Map.has_key?(attrs, :value)) or
             (op != :delete and Map.has_key?(attrs, :value)) do
      {:ok, Map.put(attrs, :op, op)}
    else
      _invalid -> {:error, :invalid_morph_operation}
    end
  end

  defp operation_name(op) when op in [:put, "put"], do: {:ok, :put}
  defp operation_name(op) when op in [:test, "test"], do: {:ok, :test}
  defp operation_name(op) when op in [:delete, "delete"], do: {:ok, :delete}
  defp operation_name(_op), do: {:error, :unknown_morph_operation}

  defp update(_body, [], %{op: :put, value: value}), do: {:ok, value}
  defp update(body, [], %{op: :test, value: value}) when body === value, do: {:ok, body}
  defp update(_body, [], %{op: :test}), do: {:error, :morph_precondition_failed}
  defp update(_body, [], %{op: :delete}), do: {:error, :cannot_delete_definition_body}

  defp update(body, [key], %{op: :delete}) when is_map(body) do
    if Map.has_key?(body, key),
      do: {:ok, Map.delete(body, key)},
      else: {:error, :morph_path_not_found}
  end

  defp update(body, [key], %{op: :put, value: value}) when is_map(body),
    do: {:ok, Map.put(body, key, value)}

  defp update(body, [key | rest], operation) when is_map(body) do
    with {:ok, value} <- fetch(Map.fetch(body, key)),
         {:ok, next} <- update(value, rest, operation) do
      {:ok, Map.put(body, key, next)}
    end
  end

  defp update(body, [index | rest], operation)
       when is_list(body) and is_integer(index) and index >= 0 do
    with {:ok, value} <- fetch(Enum.fetch(body, index)) do
      update_list(body, index, value, rest, operation)
    end
  end

  defp update(_body, _path, _operation), do: {:error, :morph_path_not_found}

  defp update_list(body, index, _value, [], %{op: :delete}),
    do: {:ok, List.delete_at(body, index)}

  defp update_list(body, index, value, rest, operation) do
    with {:ok, next} <- update(value, rest, operation),
         do: {:ok, List.replace_at(body, index, next)}
  end

  defp fetch(:error), do: {:error, :morph_path_not_found}
  defp fetch({:ok, _} = value), do: value

  defp authoring_integrity(%{body: %{"format" => "spectre-agent-declaration-v1"}}, revised) do
    case Declaration.read(revised) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp authoring_integrity(_current, _revised), do: :ok

  defp differences(before, after_value, _path) when before === after_value, do: []

  defp differences(before, after_value, path) when is_map(before) and is_map(after_value) do
    (Map.keys(before) ++ Map.keys(after_value))
    |> Enum.uniq()
    |> Enum.sort_by(&Portable.canonical_value!/1)
    |> Stream.flat_map(fn key ->
      difference(Map.fetch(before, key), Map.fetch(after_value, key), path ++ [key])
    end)
  end

  defp differences(_before, after_value, path), do: [%{op: :put, path: path, value: after_value}]

  defp difference(_before, :error, path), do: [%{op: :delete, path: path}]
  defp difference(:error, {:ok, value}, path), do: [%{op: :put, path: path, value: value}]

  defp difference({:ok, before}, {:ok, after_value}, path),
    do: differences(before, after_value, path)
end
