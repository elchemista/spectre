defmodule Spectre.Prompt.Operation do
  @moduledoc """
  One typed prompt-composition declaration compiled from `inject`.
  """

  @targets [:instructions, :context, :task]
  @positions [:start, :end, :replace]

  defstruct [
    :id,
    :source,
    :scope,
    :target,
    :position,
    :condition,
    :source_line,
    required?: true,
    trust: :data,
    opts: []
  ]

  @type target :: :instructions | :context | :task
  @type position :: :start | :end | :replace
  @type source :: {:prompt, atom() | String.t()} | {:provider, module(), atom()}

  @type t :: %__MODULE__{
          id: term(),
          source: source(),
          scope: term(),
          target: target(),
          position: position(),
          condition: nil | {module(), atom()} | function(),
          source_line: non_neg_integer() | nil,
          required?: boolean(),
          trust: :instruction | :data,
          opts: keyword()
        }

  @doc """
  Builds and validates an injection operation.
  """
  @spec new(term(), keyword(), term()) :: t()
  def new(id, opts, scope \\ :definition) when is_list(opts) do
    target = Keyword.get(opts, :into)
    position = Keyword.get(opts, :position, :end)
    source = source(id, Keyword.get(opts, :from))
    trust = trust(target, source)

    operation = %__MODULE__{
      id: id,
      source: source,
      scope: scope,
      target: target,
      position: position,
      condition: Keyword.get(opts, :when),
      source_line: Keyword.get(opts, :source_line),
      required?: Keyword.get(opts, :required, true),
      trust: trust,
      opts:
        Keyword.drop(opts, [
          :into,
          :position,
          :from,
          :when,
          :required,
          :source_line,
          :prompt
        ])
    }

    validate!(operation)
  end

  @doc """
  Normalizes handler/runtime `inject:` specifications into operations.

  A specification may be an operation, a prompt atom/string, a keyword list,
  or a list containing those shapes.
  """
  @spec normalize(term(), term()) :: [t()]
  def normalize(nil, _scope), do: []
  def normalize([], _scope), do: []

  def normalize(%__MODULE__{} = operation, scope),
    do: [%{operation | scope: scope}]

  def normalize(prompt, scope) when is_atom(prompt) or is_binary(prompt) do
    [new(prompt, [into: :task], scope)]
  end

  def normalize(spec, scope) when is_list(spec) do
    if Keyword.keyword?(spec) and Keyword.has_key?(spec, :prompt) do
      prompt = Keyword.fetch!(spec, :prompt)
      [new(prompt, Keyword.delete(spec, :prompt), scope)]
    else
      Enum.flat_map(spec, &normalize(&1, scope))
    end
  end

  def normalize(spec, _scope) do
    raise ArgumentError, "invalid inject specification: #{inspect(spec)}"
  end

  @doc """
  Assigns a materialized runtime scope to an operation.
  """
  @spec put_scope(t(), term()) :: t()
  def put_scope(%__MODULE__{} = operation, scope), do: %{operation | scope: scope}

  @spec source(term(), term()) :: source()
  defp source(id, nil) when is_atom(id) or is_binary(id), do: {:prompt, id}

  defp source(_id, {module, function}) when is_atom(module) and is_atom(function),
    do: {:provider, module, function}

  defp source(_id, source) do
    raise ArgumentError, "inject from: expects {Module, :function}, got: #{inspect(source)}"
  end

  @spec trust(target() | term(), source()) :: :instruction | :data
  defp trust(:context, _source), do: :data
  defp trust(target, {:prompt, _prompt}) when target in [:instructions, :task], do: :instruction

  defp trust(target, {:provider, _module, _function}) when target in [:instructions, :task] do
    raise ArgumentError,
          "dynamic inject providers may only target :context, got: #{inspect(target)}"
  end

  defp trust(_target, _source), do: :data

  @spec validate!(t()) :: t()
  defp validate!(%__MODULE__{id: nil}), do: raise(ArgumentError, "inject requires an identifier")

  defp validate!(%__MODULE__{target: target}) when target not in @targets do
    raise ArgumentError,
          "inject into: must be one of #{inspect(@targets)}, got: #{inspect(target)}"
  end

  defp validate!(%__MODULE__{position: position}) when position not in @positions do
    raise ArgumentError,
          "inject position: must be one of #{inspect(@positions)}, got: #{inspect(position)}"
  end

  defp validate!(%__MODULE__{required?: required?}) when not is_boolean(required?) do
    raise ArgumentError, "inject required: must be a boolean, got: #{inspect(required?)}"
  end

  defp validate!(%__MODULE__{condition: condition} = operation) do
    if valid_condition?(condition) do
      operation
    else
      raise ArgumentError,
            "inject when: expects {Module, :function} or a function, got: #{inspect(condition)}"
    end
  end

  @spec valid_condition?(term()) :: boolean()
  defp valid_condition?(nil), do: true

  defp valid_condition?({module, function}) when is_atom(module) and is_atom(function), do: true
  defp valid_condition?(condition) when is_function(condition), do: true
  defp valid_condition?(_condition), do: false
end
