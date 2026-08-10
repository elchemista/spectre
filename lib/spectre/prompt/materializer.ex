defmodule Spectre.Prompt.Materializer do
  @moduledoc """
  Closed renderer for canonical prompt fragments.

  Only declared scalar placeholders are resolved. The resulting typed
  `Spectre.Prompt.Plan` and `Spectre.Prompt.Receipt` are deterministic for the
  same Definition fragment and resolved evidence.
  """

  alias Spectre.Input
  alias Spectre.Prompt.Fragment
  alias Spectre.Prompt.Operation
  alias Spectre.Prompt.Plan
  alias Spectre.Prompt.Receipt

  @placeholder ~r/\{\{([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\}\}/

  @doc "Renders one canonical fragment and produces its effective receipt."
  @spec materialize(Fragment.t(), term(), map(), String.t()) ::
          {:ok, Plan.t(), Receipt.t()} | {:error, term()}
  def materialize(%Fragment{} = fragment, input, context, definition_ref)
      when is_map(context) do
    with {:ok, input} <- normalize_input(input),
         {:ok, rendered, evidence} <- render(fragment, input, context),
         {:ok, plan} <- plan(fragment, rendered),
         {:ok, receipt} <- Receipt.new(fragment, rendered, definition_ref, evidence) do
      {:ok, plan, receipt}
    end
  end

  def materialize(%Fragment{}, _input, context, _definition_ref),
    do: {:error, {:invalid_prompt_materialization_context, shape(context)}}

  @doc "Renders one canonical fragment without exposing arbitrary string protocols."
  @spec render(Fragment.t(), Input.t() | term(), map()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def render(%Fragment{content: content, placeholders: placeholders}, input, context)
      when is_map(context) do
    with {:ok, input} <- normalize_input(input) do
      values = Map.put(context, :input, %{text: input.text, meta: input.meta})
      render_placeholders(placeholders, content, values)
    end
  end

  def render(%Fragment{}, _input, context),
    do: {:error, {:invalid_prompt_materialization_context, shape(context)}}

  @spec render_placeholders(map(), String.t(), map()) ::
          {:ok, String.t(), map()} | {:error, term()}
  defp render_placeholders(placeholders, content, values) do
    placeholders
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {name, spec}, {:ok, replacements, evidence} ->
      case resolve_placeholder(name, spec, values) do
        {:ok, scalar, value} ->
          {:cont, {:ok, Map.put(replacements, name, scalar), Map.put(evidence, name, value)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, replacements, evidence} ->
        rendered =
          Regex.replace(@placeholder, content, fn _placeholder, name ->
            Map.fetch!(replacements, name)
          end)

        {:ok, rendered, evidence}

      {:error, _reason} = error ->
        error
    end
  end

  @spec resolve_placeholder(String.t(), map(), map()) ::
          {:ok, String.t(), term()} | {:error, term()}
  defp resolve_placeholder(name, spec, values) do
    with {:ok, value} <- fetch_path(values, get(spec, :path, [])),
         {:ok, scalar} <- scalar(value) do
      {:ok, scalar, value}
    else
      :error -> {:error, {:missing_runtime_prompt_value, name}}
      {:error, shape} -> {:error, {:non_scalar_runtime_prompt_value, name, shape}}
    end
  end

  @spec plan(Fragment.t(), String.t()) :: {:ok, Plan.t()} | {:error, term()}
  defp plan(fragment, rendered) do
    operation = %Operation{
      id: fragment.id,
      source: {:prompt, fragment.id},
      scope: fragment.scope,
      target: fragment.target,
      position: fragment.position,
      condition: nil,
      required?: true,
      trust: fragment.trust,
      opts: []
    }

    Plan.compose(
      "",
      [
        %{
          operation: operation,
          status: :applied,
          content: rendered,
          metadata: %{bytes: byte_size(rendered)}
        }
      ],
      [fragment.scope]
    )
  end

  @spec scalar(term()) :: {:ok, String.t()} | {:error, atom()}
  defp scalar(value) when is_binary(value), do: {:ok, value}

  defp scalar(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: {:ok, to_string(value)}

  defp scalar(value) when is_atom(value) and not is_nil(value), do: {:ok, Atom.to_string(value)}
  defp scalar(value), do: {:error, shape(value)}

  @spec fetch_path(term(), [String.t()]) :: {:ok, term()} | :error
  defp fetch_path(value, []), do: {:ok, value}

  defp fetch_path(value, [segment | rest]) when is_map(value) do
    atom = existing_atom(segment)

    cond do
      Map.has_key?(value, segment) -> fetch_path(Map.fetch!(value, segment), rest)
      not is_nil(atom) and Map.has_key?(value, atom) -> fetch_path(Map.fetch!(value, atom), rest)
      true -> :error
    end
  end

  defp fetch_path(_value, _path), do: :error

  @spec normalize_input(term()) :: {:ok, Input.t()} | {:error, term()}
  defp normalize_input(%Input{} = input), do: {:ok, input}

  defp normalize_input(input) do
    {:ok, Input.new(input)}
  rescue
    _error in [ArgumentError, Protocol.UndefinedError] ->
      {:error, {:invalid_skill_input, shape(input)}}
  end

  @spec get(map(), atom(), term()) :: term()
  defp get(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  @spec existing_atom(String.t()) :: atom() | nil
  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
