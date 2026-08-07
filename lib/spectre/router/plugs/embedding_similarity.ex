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
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Router.Candidate
  alias Spectre.Router.Context
  alias Spectre.Router.SemanticCache.Owner
  alias Spectre.Router.Support

  @example_cache_table Module.concat(__MODULE__, Cache)
  @default_example_cache_capacity 2_048

  @impl Spectre.Router.Plug
  def init(opts), do: opts

  @impl Spectre.Router.Plug
  def call(%Context{} = context, _state) do
    cond do
      Context.halted?(context) ->
        {:cont, context}

      Context.hard_candidate_locked?(context) ->
        {:cont, Context.put_trace(context, {:embedding_skip, :hard_candidate})}

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
        case embed_example(example, opts) do
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

  defp embedding_rules?(%Context{rules: rules, input: input}) do
    rules
    |> Support.rules_for(:embedding, input)
    |> Enum.any?(fn %Spectre.Rule{embedding: examples} -> examples != [] end)
  end

  defp embed(text, opts) do
    call_opts = embedding_call_opts(opts)
    adapter_opts = Call.adapter_opts(call_opts)

    case Call.run(
           :embedding,
           fn ->
             text
             |> dispatch_embedding(adapter_opts)
             |> normalize_embedding_reply()
           end,
           call_opts
         ) do
      {:ok, vector} when is_list(vector) -> {:ok, vector}
      {:error, _reason} = error -> error
    end
  end

  defp embed_example(text, opts) do
    if Keyword.get(opts, :embedding_example_cache?, true) do
      key = {embedding_cache_identity(opts), text}

      case cached_embedding(key) do
        {:ok, vector} ->
          {:ok, vector}

        :miss ->
          text |> embed(opts) |> cache_example_result(key, opts)
      end
    else
      embed(text, opts)
    end
  end

  defp cache_example_result({:ok, vector} = result, key, opts) do
    cache_embedding(key, vector, opts)
    result
  end

  defp cache_example_result({:error, _reason} = error, _key, _opts), do: error

  defp embedding_cache_identity(opts) do
    {
      Keyword.get(opts, :spectre_agent),
      Keyword.get(opts, :embedding),
      Keyword.get(opts, :embedding_model),
      Keyword.get(opts, :embedding_cache_namespace)
    }
  end

  defp cached_embedding(key) do
    case embedding_cache_table() do
      {:ok, table} ->
        case :ets.lookup(table, key) do
          [{^key, vector, _inserted_at}] -> {:ok, vector}
          [] -> :miss
        end

      {:error, _reason} ->
        :miss
    end
  end

  defp cache_embedding(key, vector, opts) do
    case embedding_cache_table() do
      {:ok, table} ->
        :ets.insert_new(table, {key, vector, System.unique_integer([:positive, :monotonic])})
        enforce_example_cache_capacity(table, example_cache_capacity(opts))

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  defp embedding_cache_table do
    Owner.ensure_table(@example_cache_table, [
      :named_table,
      :public,
      :set,
      :compressed,
      read_concurrency: true,
      write_concurrency: true
    ])
  end

  defp enforce_example_cache_capacity(_table, :unlimited), do: :ok

  defp enforce_example_cache_capacity(table, capacity) do
    overflow = :ets.info(table, :size) - capacity

    if overflow > 0 do
      table
      |> :ets.tab2list()
      |> Enum.sort_by(fn {_key, _vector, inserted_at} -> inserted_at end)
      |> Enum.take(overflow)
      |> Enum.each(fn {key, _vector, _inserted_at} -> :ets.delete(table, key) end)
    end

    :ok
  end

  defp example_cache_capacity(opts) do
    case Keyword.get(opts, :embedding_example_cache_capacity, @default_example_cache_capacity) do
      :unlimited -> :unlimited
      value when is_integer(value) and value > 0 -> value
      _invalid -> @default_example_cache_capacity
    end
  end

  @spec normalize_embedding_reply(term()) :: {:ok, [number()]} | {:error, term()} | term()
  defp normalize_embedding_reply({:ok, vector}) when is_list(vector), do: validate_vector(vector)

  defp normalize_embedding_reply({:ok, other}),
    do: {:error, Failure.invalid_reply(:embedding, other)}

  defp normalize_embedding_reply({:error, _reason} = error), do: error
  defp normalize_embedding_reply(other), do: other

  @spec dispatch_embedding(String.t(), keyword()) :: term()
  defp dispatch_embedding(text, opts) do
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
  end

  @spec embedding_call_opts(keyword()) :: keyword()
  defp embedding_call_opts(opts) do
    case Keyword.get(opts, :embedding) do
      {_module, adapter_opts} when is_list(adapter_opts) -> Keyword.merge(adapter_opts, opts)
      _other -> opts
    end
  end

  @spec validate_vector([term()]) :: {:ok, [number()]} | {:error, Failure.t()}
  defp validate_vector([_value | _rest] = vector) do
    if Enum.all?(vector, &is_number/1),
      do: {:ok, vector},
      else: {:error, Failure.invalid_reply(:embedding, vector)}
  end

  defp validate_vector([]), do: {:error, Failure.invalid_reply(:embedding, [])}
end
