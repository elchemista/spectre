defmodule Spectre.Flow.Constraint do
  @moduledoc """
  Namespaced constraint contributed to a compiled flow by an extension.

  Source constraints participate in routing. Other kinds remain attached to
  the selected rule so inference or workflow extensions can consume them
  without affecting route visibility.
  """

  defstruct [:namespace, kind: :source, values: [], mode: :any, metadata: %{}]

  @type t :: %__MODULE__{
          namespace: atom() | String.t(),
          kind: :source | :inference | atom(),
          values: [term()],
          mode: :any | :all,
          metadata: map()
        }

  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = constraint), do: constraint
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    constraint =
      attrs
      |> Map.update(:values, [], &List.wrap/1)
      |> then(&struct(__MODULE__, Map.take(&1, fields())))

    validate!(constraint)
    constraint
  end

  @doc """
  Returns whether a rule's source constraints accept an input.
  """
  @spec match?([t()], Spectre.Input.t()) :: boolean()
  def match?(constraints, %Spectre.Input{} = input) when is_list(constraints) do
    constraints
    |> Enum.filter(&(&1.kind == :source))
    |> Enum.all?(&source_match?(&1, input.source))
  end

  @doc """
  Filters incompatible rules and prefers constrained rules inside the existing
  global-interrupt and ordinary-rule precedence groups.
  """
  @spec filter_and_order([Spectre.Rule.t()], Spectre.Input.t()) :: [Spectre.Rule.t()]
  def filter_and_order(rules, %Spectre.Input{} = input) when is_list(rules) do
    rules
    |> Enum.filter(&__MODULE__.match?(&1.constraints, input))
    |> Enum.with_index()
    |> Enum.sort_by(fn {rule, index} ->
      {
        if(rule.global?, do: 0, else: 1),
        if(source_specific?(rule), do: 0, else: 1),
        index
      }
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @spec source_specific?(Spectre.Rule.t()) :: boolean()
  defp source_specific?(%Spectre.Rule{constraints: constraints}),
    do: Enum.any?(constraints, &(&1.kind == :source))

  @spec source_match?(t(), Spectre.Input.Source.t() | nil) :: boolean()
  defp source_match?(%__MODULE__{}, nil), do: false

  defp source_match?(
         %__MODULE__{namespace: namespace, values: values, mode: :any},
         %Spectre.Input.Source{} = source
       ) do
    comparable(source.kind) == comparable(namespace) and
      Enum.any?(values, &(comparable(&1) == comparable(source.mount)))
  end

  defp source_match?(
         %__MODULE__{namespace: namespace, values: values, mode: :all},
         %Spectre.Input.Source{} = source
       ) do
    comparable(source.kind) == comparable(namespace) and
      Enum.all?(values, &(comparable(&1) == comparable(source.mount)))
  end

  @spec comparable(term()) :: term()
  defp comparable(value) when is_atom(value), do: Atom.to_string(value)
  defp comparable(value), do: value

  @spec validate!(t()) :: :ok
  defp validate!(%__MODULE__{} = constraint) do
    unless (is_atom(constraint.namespace) and not is_nil(constraint.namespace)) or
             (is_binary(constraint.namespace) and constraint.namespace != "") do
      raise ArgumentError, "flow constraint namespace must be a non-empty atom or string"
    end

    unless constraint.mode in [:any, :all],
      do: raise(ArgumentError, "invalid flow constraint mode: #{inspect(constraint.mode)}")

    unless is_list(constraint.values) and constraint.values != [],
      do: raise(ArgumentError, "flow constraint values must be a non-empty list")

    unless is_map(constraint.metadata),
      do: raise(ArgumentError, "flow constraint metadata must be a map")

    :ok
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
