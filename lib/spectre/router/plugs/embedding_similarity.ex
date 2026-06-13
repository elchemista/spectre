defmodule Spectre.Router.Plugs.EmbeddingSimilarity do
  @moduledoc """
  Embedding similarity evidence provider.

  The plug embeds the current user text and compares it with per-rule examples.
  It logs and traces adapter failures as a skip instead of failing the whole
  turn, because embedding search is optional evidence: the agent can still be
  routed by regex, classifier, semantic cache, or LLM fallback.

      on :shipping_question,
        embedding: ["where is my package?", "track my order"] do
        ask :shipping_answer
      end
  """

  @behaviour Spectre.Router.Plug

  alias Spectre.Classifier.Math
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.Support

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(%Context{} = context, _state) do
    cond do
      Context.halted?(context) ->
        {:cont, context}

      not embedding_rules?(context) ->
        {:cont, context}

      true ->
        collect(context)
    end
  end

  defp collect(%Context{input: %{text: text}, rules: rules, opts: opts} = context) do
    case embed(text, opts) do
      {:ok, query} ->
        candidates =
          rules
          |> Support.rules_for(:embedding, context.input)
          |> Enum.flat_map(&candidate(&1, text, query, opts))

        {:cont, Context.add_candidates(context, candidates)}

      {:error, reason} ->
        Support.log(:debug, "embedding_skip reason=#{Support.format_reason(reason)}", opts)
        {:cont, Context.put_trace(context, {:embedding_skip, reason})}
    end
  end

  defp candidate(%Spectre.Rule{embedding: []}, _text, _query, _opts), do: []

  defp candidate(%Spectre.Rule{} = rule, text, query, opts) do
    scored =
      rule.embedding
      |> Enum.flat_map(fn example ->
        case embed(example, opts) do
          {:ok, vector} -> [{example, Math.cosine(query, vector)}]
          {:error, _reason} -> []
        end
      end)
      |> Enum.sort_by(fn {_example, score} -> score end, :desc)

    case scored do
      [{example, score} | rest] ->
        second = rest |> List.first({nil, 0.0}) |> elem(1)

        [
          Candidate.from_rule(rule, :embedding, text,
            score: score,
            margin: score - second,
            matched: example,
            metadata: %{examples: rule.embedding}
          )
        ]

      [] ->
        []
    end
  end

  defp embedding_rules?(%Context{rules: rules}) do
    Enum.any?(rules, fn %Spectre.Rule{embedding: examples} -> examples != [] end)
  end

  defp embed(text, opts) do
    case Keyword.fetch(opts, :embedding) do
      {:ok, {module, adapter_opts}} when is_atom(module) and is_list(adapter_opts) ->
        module.embed(text, Keyword.merge(adapter_opts, opts))

      {:ok, module} when is_atom(module) ->
        module.embed(text, opts)

      {:ok, fun} when is_function(fun, 2) ->
        fun.(text, opts)

      {:ok, fun} when is_function(fun, 1) ->
        fun.(text)

      :error ->
        {:error, :missing_embedding_adapter}

      {:ok, other} ->
        {:error, {:invalid_embedding_adapter, other}}
    end
  rescue
    exception ->
      {:error, {:embedding_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:embedding_exit, reason}}
    kind, reason -> {:error, {:embedding_failure, kind, reason}}
  end
end
