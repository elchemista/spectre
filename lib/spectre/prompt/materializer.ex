defmodule Spectre.Prompt.Materializer do
  @moduledoc """
  Closed renderer for canonical prompt fragments.

  Only declared scalar placeholders are resolved. The resulting typed
  `Spectre.Prompt.Plan` and `Spectre.Prompt.Receipt` are deterministic for the
  same Definition fragment and resolved evidence.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Effect
  alias Spectre.Input
  alias Spectre.Prompt.Fragment
  alias Spectre.Prompt.Operation
  alias Spectre.Prompt.Plan
  alias Spectre.Prompt.Predicate
  alias Spectre.Prompt.Receipt
  alias Spectre.Prompt.Value, as: PromptValue

  @placeholder ~r/\{\{([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\}\}/

  @doc "Renders one canonical fragment and produces its effective receipt."
  @spec materialize(Fragment.t(), term(), map(), String.t(), keyword()) ::
          {:ok, Plan.t(), Receipt.t()} | {:error, term()}
  def materialize(fragment, input, context, definition_ref, opts \\ [])

  def materialize(%Fragment{} = fragment, input, context, definition_ref, opts)
      when is_map(context) and is_list(opts) do
    with {:ok, fragment} <- canonical_fragment(fragment),
         {:ok, input} <- normalize_input(input),
         {:ok, condition?, condition_evidence} <-
           Predicate.evaluate(fragment.condition_ref, input, context, opts),
         {:ok, rendered, placeholder_evidence, status} <-
           render_condition(condition?, fragment, input, context),
         evidence <- Map.merge(placeholder_evidence, condition_evidence),
         :ok <- rendered_budget(fragment, rendered),
         {:ok, plan} <- plan(fragment, rendered, status, placeholder_evidence),
         {:ok, receipt} <-
           Receipt.new(fragment, Plan.legacy(plan), definition_ref, evidence) do
      {:ok, plan, receipt}
    end
  end

  def materialize(%Fragment{}, _input, context, _definition_ref, _opts),
    do: {:error, {:invalid_prompt_materialization_context, shape(context)}}

  @doc "Renders one canonical fragment without exposing arbitrary string protocols."
  @spec render(Fragment.t(), Input.t() | term(), map(), keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
  def render(fragment, input, context, opts \\ [])

  def render(%Fragment{} = fragment, input, context, opts)
      when is_map(context) and is_list(opts) do
    with {:ok, fragment} <- canonical_fragment(fragment),
         {:ok, input} <- normalize_input(input),
         {:ok, condition?, condition_evidence} <-
           Predicate.evaluate(fragment.condition_ref, input, context, opts),
         {:ok, rendered, placeholder_evidence, _status} <-
           render_condition(condition?, fragment, input, context),
         :ok <- rendered_budget(fragment, rendered) do
      {:ok, rendered, Map.merge(placeholder_evidence, condition_evidence)}
    end
  end

  def render(%Fragment{}, _input, context, _opts),
    do: {:error, {:invalid_prompt_materialization_context, shape(context)}}

  defp render_condition(true, fragment, input, context) do
    with {:ok, rendered, evidence} <- render_fragment(fragment, input, context) do
      {:ok, rendered, evidence, :applied}
    end
  end

  defp render_condition(false, _fragment, _input, _context),
    do: {:ok, "", %{}, :skipped}

  @spec render_fragment(Fragment.t(), Input.t(), map()) ::
          {:ok, String.t(), map()} | {:error, term()}
  defp render_fragment(%Fragment{content: nil, id: id}, _input, _context),
    do: {:error, {:dynamic_prompt_fragment_not_materializable, id}}

  defp render_fragment(
         %Fragment{content: content, placeholders: placeholders},
         input,
         context
       ) do
    values =
      context
      |> Map.delete("input")
      |> Map.put(:input, %{
        text: input.text,
        meta: input.meta,
        trust: Input.trust(input),
        source: Input.source_evidence(input)
      })

    render_placeholders(placeholders, content, values)
  end

  @spec canonical_fragment(Fragment.t()) :: {:ok, Fragment.t()} | {:error, term()}
  defp canonical_fragment(%Fragment{} = fragment) do
    case fragment |> Map.from_struct() |> Fragment.canonical() do
      {:ok, %Fragment{digest: digest} = canonical} when digest == fragment.digest ->
        {:ok, canonical}

      {:ok, %Fragment{}} ->
        {:error, :prompt_materialization_fragment_digest_mismatch}

      {:error, reason} ->
        {:error, {:invalid_prompt_materialization_fragment, reason}}
    end
  end

  @spec render_placeholders(map(), String.t(), map()) ::
          {:ok, String.t(), map()} | {:error, term()}
  defp render_placeholders(placeholders, content, values) do
    placeholders
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {name, spec}, {:ok, replacements, evidence} ->
      case resolve_placeholder(name, spec, values) do
        {:ok, scalar, value_evidence} ->
          {:cont,
           {:ok, Map.put(replacements, name, scalar), Map.put(evidence, name, value_evidence)}}

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
    with {:ok, value, source_evidence} <- fetch_path(values, get(spec, :path, [])),
         {:ok, scalar} <- render_value(value, get(spec, :renderer_ref, nil)) do
      {:ok, scalar, resolved_evidence(value, source_evidence)}
    else
      :error ->
        {:error, {:missing_runtime_prompt_value, name}}

      {:error, {:invalid_prompt_value_evidence, reason}} ->
        {:error, {:invalid_runtime_prompt_evidence, name, reason}}

      {:error, shape} ->
        {:error, {:non_scalar_runtime_prompt_value, name, shape}}
    end
  end

  @spec render_value(term(), term()) :: {:ok, String.t()} | {:error, atom()}
  defp render_value(value, "spectre.renderer.text/1"), do: scalar(value)

  defp render_value(value, "spectre.renderer.inspect/1") do
    case Value.validate(value) do
      :ok -> {:ok, inspect(value, limit: :infinity, printable_limit: 4_096)}
      {:error, _reason} -> {:error, shape(value)}
    end
  end

  defp render_value(value, "spectre.renderer.data/1"), do: {:ok, Spectre.Prompt.data(value)}

  defp render_value(_value, _renderer_ref), do: {:error, :unsupported_renderer}

  @spec plan(Fragment.t(), String.t(), :applied | :skipped, map()) ::
          {:ok, Plan.t()} | {:error, term()}
  defp plan(fragment, rendered, status, evidence) do
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

    metadata = fragment_metadata(rendered, evidence)

    Plan.compose(
      "",
      [
        %{
          operation: operation,
          status: status,
          reason: if(status == :skipped, do: :prompt_predicate_false, else: nil),
          content: rendered,
          metadata: metadata
        }
      ],
      [fragment.scope]
    )
  end

  defp rendered_budget(%Fragment{token_cap: nil}, _rendered), do: :ok

  defp rendered_budget(%Fragment{id: id, token_cap: cap}, rendered) do
    estimated = estimated_tokens(rendered)

    if estimated <= cap,
      do: :ok,
      else: {:error, {:rendered_prompt_fragment_over_budget, id, estimated, cap}}
  end

  defp estimated_tokens(""), do: 0
  defp estimated_tokens(content), do: div(byte_size(content) + 3, 4)

  @spec scalar(term()) :: {:ok, String.t()} | {:error, atom()}
  defp scalar(value) when is_binary(value), do: {:ok, value}

  defp scalar(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: {:ok, to_string(value)}

  defp scalar(value) when is_atom(value) and not is_nil(value), do: {:ok, Atom.to_string(value)}
  defp scalar(value), do: {:error, shape(value)}

  @spec fetch_path(term(), [String.t()]) ::
          {:ok, term(), map() | nil} | :error | {:error, term()}
  defp fetch_path(%PromptValue{} = wrapped, path) do
    with :ok <- PromptValue.validate(wrapped),
         {:ok, value, nested_evidence} <- fetch_path(wrapped.value, path) do
      {:ok, value, nested_evidence || PromptValue.evidence(wrapped)}
    else
      {:error, reason} -> {:error, {:invalid_prompt_value_evidence, reason}}
      :error -> :error
    end
  end

  # Keeping a completed Effect in assigns or memory is sufficient to retain
  # its evidence. `Effect.prompt_result/1` provides the same behavior after a
  # host extracts only the result value.
  defp fetch_path(%Effect{status: :completed} = effect, ["result" | rest]) do
    effect
    |> Effect.prompt_result()
    |> fetch_path(rest)
  end

  defp fetch_path(value, []), do: {:ok, value, nil}

  defp fetch_path(value, [segment | rest]) when is_map(value) do
    if Map.has_key?(value, segment) do
      fetch_path(Map.fetch!(value, segment), rest)
    else
      case Enum.find(Map.keys(value), &(is_atom(&1) and Atom.to_string(&1) == segment)) do
        nil -> :error
        key -> fetch_path(Map.fetch!(value, key), rest)
      end
    end
  end

  defp fetch_path(_value, _path), do: :error

  defp resolved_evidence(value, nil), do: value

  defp resolved_evidence(value, source_evidence) do
    Map.put(source_evidence, :value, value)
  end

  defp fragment_evidence(evidence) do
    Enum.reduce(evidence, %{}, fn
      {name, %{trust: trust, provenance: provenance, authenticity: authenticity}}, acc ->
        Map.put(acc, name, %{
          trust: trust,
          provenance: provenance,
          authenticity: authenticity
        })

      {_name, _unclassified}, acc ->
        acc
    end)
  end

  defp fragment_metadata(rendered, evidence) do
    case fragment_evidence(evidence) do
      evidence when map_size(evidence) == 0 -> %{bytes: byte_size(rendered)}
      evidence -> %{bytes: byte_size(rendered), resolved_evidence: evidence}
    end
  end

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

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
