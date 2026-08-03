defmodule Spectre.Rule do
  @moduledoc """
  Declarative routing rule compiled from `Spectre.Agent` DSL.

  Rules are internal domain data. They normalize DSL options such as regexes,
  examples, checks, and handler declarations before any router plug sees them.

      rule =
        Spectre.Rule.new(%{
          label: :help,
          flow: :support,
          regex: ~r/^help$/i,
          handler: {:reply, :help, []}
        })
  """

  defstruct [
    :label,
    :flow,
    :handler,
    :owner,
    flow_path: [],
    scope: :agent,
    regex: [],
    bag: [],
    jaro: [],
    embedding: [],
    cache: true,
    learn: false,
    checks: [],
    via: [],
    injections: [],
    definition_injections: [],
    constraints: [],
    global?: false,
    opts: []
  ]

  @type handler ::
          {:ask, term(), keyword()}
          | {:reason, term(), keyword()}
          | {:act, term(), keyword()}
          | {:run, atom(), keyword()}
          | {:work, module(), keyword()}
          | {:reply, term(), keyword()}
          | {:action, Spectre.Action.ref(), keyword()}

  @type t :: %__MODULE__{
          label: atom(),
          flow: atom() | nil,
          flow_path: [atom()],
          handler: handler(),
          owner: module() | nil,
          scope: Spectre.Definition.scope(),
          regex: [Regex.t()],
          bag: [String.t()],
          jaro: [String.t()],
          embedding: [String.t()],
          cache: boolean(),
          learn: boolean(),
          checks: [{atom() | String.t(), term()}],
          via: [atom()],
          injections: [Spectre.Prompt.Operation.t()],
          definition_injections: [Spectre.Prompt.Operation.t()],
          constraints: [Spectre.Flow.Constraint.t()],
          global?: boolean(),
          opts: keyword()
        }

  @doc """
  Builds a normalized routing rule from DSL metadata.

      %Spectre.Rule{} = Spectre.Rule.new(%{label: :hello, regex: ~r/hello/})
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_regex()
      |> reject_training_metadata()
      |> normalize_checks()
      |> normalize_flow_path()

    struct(__MODULE__, Map.take(attrs, fields()))
  end

  @doc """
  Returns true when any deterministic regex on the rule matches the text.

      Spectre.Rule.match?(rule, "hello")
  """
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{regex: []}, _text), do: false

  def match?(%__MODULE__{regex: regexes}, text) when is_binary(text) do
    Enum.any?(regexes, &Regex.match?(&1, text))
  end

  @doc """
  Returns true when all checks pass against an input.

      Spectre.Rule.checks_match?(rule, input)
  """
  @spec checks_match?(t(), Spectre.Input.t()) :: boolean()
  def checks_match?(%__MODULE__{checks: []}, %Spectre.Input{}), do: true

  def checks_match?(%__MODULE__{checks: checks}, %Spectre.Input{} = input) do
    Enum.all?(checks, fn {field, expected} ->
      case check_value(input, field) do
        {:ok, actual} -> value_allowed?(actual, expected)
        :error -> false
      end
    end)
  end

  @spec normalize_regex(map()) :: map()
  defp normalize_regex(%{regex: nil} = attrs), do: %{attrs | regex: []}

  defp normalize_regex(%{regex: regex} = attrs) when is_struct(regex, Regex),
    do: %{attrs | regex: [regex]}

  defp normalize_regex(%{regex: regexes} = attrs) when is_list(regexes), do: attrs
  defp normalize_regex(attrs), do: Map.put_new(attrs, :regex, [])

  @spec reject_training_metadata(map()) :: map()
  defp reject_training_metadata(%{train: value}), do: invalid_training!(:train, value)
  defp reject_training_metadata(%{training: value}), do: invalid_training!(:training, value)
  defp reject_training_metadata(attrs), do: attrs

  defp invalid_training!(key, value) do
    raise ArgumentError,
          "#{inspect(key)} is not supported; keep examples in labeled dataset files, got: #{inspect(value)}"
  end

  @spec normalize_flow_path(map()) :: map()
  defp normalize_flow_path(attrs) do
    case Map.get(attrs, :flow_path) do
      [_head | _tail] -> attrs
      _missing_or_empty -> Map.put(attrs, :flow_path, attrs |> Map.get(:flow) |> List.wrap())
    end
  end

  @spec normalize_checks(map()) :: map()
  defp normalize_checks(attrs) do
    checks =
      attrs
      |> Map.get(:checks, [])
      |> List.wrap()
      |> Kernel.++(named_check(attrs))
      |> Enum.flat_map(&normalize_check/1)

    Map.put(attrs, :checks, checks)
  end

  defp named_check(%{check: check}), do: List.wrap(check)
  defp named_check(_attrs), do: []

  defp normalize_check({field, expected}), do: [{field, expected}]
  defp normalize_check(other), do: raise(ArgumentError, "invalid rule check: #{inspect(other)}")

  @spec check_value(Spectre.Input.t(), atom() | String.t()) :: {:ok, term()} | :error
  defp check_value(%Spectre.Input{} = input, :text), do: {:ok, input.text}
  defp check_value(%Spectre.Input{} = input, "text"), do: {:ok, input.text}
  defp check_value(%Spectre.Input{} = input, field), do: Spectre.Input.fetch_meta(input, field)

  @spec value_allowed?(term(), term()) :: boolean()
  defp value_allowed?(actual, expected) when is_list(expected),
    do: Enum.any?(expected, &value_allowed?(actual, &1))

  defp value_allowed?(actual, expected), do: comparable(actual) == comparable(expected)

  @spec comparable(term()) :: term()
  defp comparable(value) when is_binary(value), do: value |> String.downcase() |> String.trim()
  defp comparable(value) when is_atom(value), do: value |> to_string() |> comparable()
  defp comparable(value), do: value

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
