defmodule Spectre.Rule do
  @moduledoc """
  Declarative routing rule compiled from `Spectre.Agent` DSL.
  """

  defstruct [
    :label,
    :flow,
    :handler,
    regex: [],
    training: [],
    via: [],
    global?: false,
    opts: []
  ]

  @type handler :: {:ask, term(), keyword()} | {:run, atom(), keyword()}

  @type t :: %__MODULE__{
          label: atom(),
          flow: atom() | nil,
          handler: handler(),
          regex: [Regex.t()],
          training: [String.t()],
          via: [atom()],
          global?: boolean(),
          opts: keyword()
        }

  @doc """
  Builds a normalized routing rule from DSL metadata.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_regex()
      |> normalize_training()

    struct(__MODULE__, Map.take(attrs, fields()))
  end

  @doc """
  Returns true when any deterministic regex on the rule matches the text.
  """
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{regex: []}, _text), do: false

  def match?(%__MODULE__{regex: regexes}, text) when is_binary(text) do
    Enum.any?(regexes, &Regex.match?(&1, text))
  end

  @spec normalize_regex(map()) :: map()
  defp normalize_regex(%{regex: nil} = attrs), do: %{attrs | regex: []}

  defp normalize_regex(%{regex: regex} = attrs) when is_struct(regex, Regex),
    do: %{attrs | regex: [regex]}

  defp normalize_regex(%{regex: regexes} = attrs) when is_list(regexes), do: attrs
  defp normalize_regex(attrs), do: Map.put_new(attrs, :regex, [])

  @spec normalize_training(map()) :: map()
  defp normalize_training(%{training: training} = attrs) when is_list(training), do: attrs

  defp normalize_training(%{training: training} = attrs) when is_binary(training),
    do: %{attrs | training: [training]}

  defp normalize_training(%{train: training} = attrs),
    do: attrs |> Map.delete(:train) |> Map.put(:training, List.wrap(training))

  defp normalize_training(attrs), do: Map.put_new(attrs, :training, [])

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
