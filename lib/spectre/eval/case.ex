defmodule Spectre.Eval.Case do
  @moduledoc """
  One version-controlled routing expectation.

  Cases can be created from ordinary maps or decoded JSONL objects. Labels and
  strategies remain strings so loading an external corpus never creates atoms.
  """

  @outcomes %{
    "route" => :route,
    "clarify" => :clarify,
    "unknown" => :unknown,
    "error" => :error
  }

  @llm_policies %{
    "forbidden" => :forbidden,
    "allowed" => :allowed,
    "required" => :required
  }

  @fields [
    :id,
    :input,
    :expected_route,
    :expected_strategy,
    :expected_output,
    :max_duration_us,
    :expected_outcome,
    :allowed_routes,
    :llm,
    :state,
    :tags,
    :context
  ]

  alias Spectre.Canonical.Value

  defstruct [
    :id,
    :input,
    :expected_route,
    :expected_strategy,
    :expected_output,
    :max_duration_us,
    expected_outcome: :route,
    allowed_routes: [],
    llm: :allowed,
    state: %{},
    tags: [],
    context: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          input: String.t() | map(),
          expected_route: String.t() | nil,
          expected_strategy: String.t() | nil,
          expected_output: String.t() | nil,
          context: map(),
          expected_outcome: Spectre.Router.Receipt.outcome(),
          allowed_routes: [String.t()],
          llm: :forbidden | :allowed | :required,
          state: map() | keyword(),
          tags: [String.t()],
          max_duration_us: pos_integer() | nil
        }

  @doc """
  Validates and normalizes a case map.
  """
  @spec new(t() | map()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = evaluation_case), do: evaluation_case |> Map.from_struct() |> new()

  def new(attrs) when is_map(attrs) do
    with :ok <- exact_fields(attrs),
         {:ok, id} <- required_binary(attrs, :id),
         {:ok, input} <- input(attrs),
         {:ok, outcome} <- enum_value(attrs, :expected_outcome, @outcomes, :route),
         {:ok, llm} <- enum_value(attrs, :llm, @llm_policies, :allowed),
         {:ok, expected_route} <- optional_label(attrs, :expected_route),
         {:ok, allowed_routes} <- labels(attrs, :allowed_routes),
         {:ok, expected_strategy} <- optional_label(attrs, :expected_strategy),
         {:ok, expected_output} <- optional_binary(attrs, :expected_output),
         {:ok, context} <- context(attrs),
         {:ok, state} <- state(attrs),
         {:ok, tags} <- tags(attrs),
         {:ok, max_duration_us} <- max_duration_us(attrs) do
      {:ok,
       %__MODULE__{
         id: id,
         input: input,
         expected_route: expected_route,
         expected_strategy: expected_strategy,
         expected_output: expected_output,
         context: context,
         expected_outcome: outcome,
         allowed_routes: allowed_routes,
         llm: llm,
         state: state,
         tags: tags,
         max_duration_us: max_duration_us
       }}
    end
  end

  def new(other), do: {:error, {:case_must_be_an_object, other}}

  @doc "Returns the complete portable shape used to identify an evaluation case."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = evaluation_case) do
    data = %{
      "id" => evaluation_case.id,
      "input" => evaluation_case.input,
      "expected_route" => evaluation_case.expected_route,
      "expected_strategy" => evaluation_case.expected_strategy,
      "expected_outcome" => Atom.to_string(evaluation_case.expected_outcome),
      "allowed_routes" => evaluation_case.allowed_routes,
      "llm" => Atom.to_string(evaluation_case.llm),
      "state" => evaluation_case.state,
      "tags" => evaluation_case.tags,
      "max_duration_us" => evaluation_case.max_duration_us
    }

    data
    |> maybe_put("expected_output", evaluation_case.expected_output, nil)
    |> maybe_put("context", evaluation_case.context, %{})
  end

  @doc """
  Returns all accepted route labels for this case in canonical form.
  """
  @spec expected_routes(t()) :: [String.t()]
  def expected_routes(%__MODULE__{} = evaluation_case) do
    [evaluation_case.expected_route | evaluation_case.allowed_routes]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&canonical/1)
    |> Enum.uniq()
  end

  @doc false
  @spec canonical(atom() | String.t() | nil) :: String.t() | nil
  def canonical(nil), do: nil

  def canonical(value) do
    value
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
    |> String.trim("_")
  end

  @spec required_binary(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  defp required_binary(attrs, key) do
    case value(attrs, key) do
      binary when is_binary(binary) and byte_size(binary) > 0 -> {:ok, binary}
      nil -> {:error, {:missing_field, key}}
      other -> {:error, {:invalid_field, key, other}}
    end
  end

  @spec input(map()) :: {:ok, String.t() | map()} | {:error, term()}
  defp input(attrs) do
    case value(attrs, :input) do
      input when is_binary(input) -> {:ok, input}
      input when is_map(input) and not is_struct(input) -> portable(input, :input)
      nil -> {:error, {:missing_field, :input}}
      other -> {:error, {:invalid_field, :input, other}}
    end
  end

  @spec enum_value(map(), atom(), map(), atom()) :: {:ok, atom()} | {:error, term()}
  defp enum_value(attrs, key, allowed, default) do
    case value(attrs, key) do
      nil ->
        {:ok, default}

      value when is_atom(value) ->
        enum_value(Map.put(attrs, key, Atom.to_string(value)), key, allowed, default)

      value when is_binary(value) ->
        fetch_enum(allowed, String.downcase(value), key, value)

      value ->
        {:error, {:invalid_field, key, value}}
    end
  end

  @spec fetch_enum(map(), String.t(), atom(), term()) :: {:ok, atom()} | {:error, term()}
  defp fetch_enum(allowed, normalized, key, original) do
    case Map.fetch(allowed, normalized) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_field, key, original}}
    end
  end

  @spec optional_label(map(), atom()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_label(attrs, key) do
    case value(attrs, key) do
      nil -> {:ok, nil}
      label when is_atom(label) or is_binary(label) -> {:ok, to_string(label)}
      other -> {:error, {:invalid_field, key, other}}
    end
  end

  @spec optional_binary(map(), atom()) :: {:ok, String.t() | nil} | {:error, term()}
  defp optional_binary(attrs, key) do
    case value(attrs, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      value -> {:error, {:invalid_field, key, value}}
    end
  end

  @spec context(map()) :: {:ok, map()} | {:error, term()}
  defp context(attrs) do
    case value(attrs, :context) do
      nil ->
        {:ok, %{}}

      context when is_map(context) and not is_struct(context) ->
        case Value.validate(context) do
          :ok -> {:ok, context}
          {:error, reason} -> {:error, {:invalid_field, :context, reason}}
        end

      value ->
        {:error, {:invalid_field, :context, value}}
    end
  end

  defp maybe_put(map, _key, value, value), do: map
  defp maybe_put(map, key, value, _default), do: Map.put(map, key, value)

  defp exact_fields(attrs) do
    string_fields = Enum.map(@fields, &Atom.to_string/1)

    unknown =
      attrs
      |> Map.keys()
      |> Enum.reject(&(&1 in @fields or &1 in string_fields))

    collision =
      Enum.find(@fields, fn field ->
        Map.has_key?(attrs, field) and Map.has_key?(attrs, Atom.to_string(field))
      end)

    cond do
      unknown != [] -> {:error, {:unknown_case_fields, Enum.sort_by(unknown, &inspect/1)}}
      collision -> {:error, {:duplicate_case_field, collision}}
      true -> :ok
    end
  end

  @spec labels(map(), atom()) :: {:ok, [String.t()]} | {:error, term()}
  defp labels(attrs, key) do
    case value(attrs, key, []) do
      labels when is_list(labels) -> normalize_labels(labels, key)
      other -> {:error, {:invalid_field, key, other}}
    end
  end

  @spec normalize_labels([term()], atom()) :: {:ok, [String.t()]} | {:error, term()}
  defp normalize_labels(labels, key) do
    if Enum.all?(labels, &(is_atom(&1) or is_binary(&1))) do
      {:ok, Enum.map(labels, &to_string/1)}
    else
      {:error, {:invalid_field, key, labels}}
    end
  end

  @spec state(map()) :: {:ok, map() | keyword() | Spectre.State.t()} | {:error, term()}
  defp state(attrs) do
    case value(attrs, :state, %{}) do
      state when (is_map(state) and not is_struct(state)) or is_list(state) ->
        portable(state, :state)

      other ->
        {:error, {:invalid_field, :state, other}}
    end
  end

  defp portable(value, field) do
    case Value.validate(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_field, field, reason}}
    end
  end

  @spec tags(map()) :: {:ok, [String.t()]} | {:error, term()}
  defp tags(attrs) do
    case value(attrs, :tags, []) do
      tags when is_list(tags) ->
        if Enum.all?(tags, &is_binary/1),
          do: {:ok, Enum.uniq(tags)},
          else: {:error, {:invalid_field, :tags, tags}}

      other ->
        {:error, {:invalid_field, :tags, other}}
    end
  end

  @spec max_duration_us(map()) :: {:ok, pos_integer() | nil} | {:error, term()}
  defp max_duration_us(attrs) do
    case value(attrs, :max_duration_us) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      other -> {:error, {:invalid_field, :max_duration_us, other}}
    end
  end

  @spec value(map(), atom(), term()) :: term()
  defp value(attrs, key, default \\ nil) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
