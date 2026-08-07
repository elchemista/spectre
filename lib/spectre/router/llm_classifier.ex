defmodule Spectre.Router.LLMClassifier do
  @moduledoc """
  One-label LLM fallback classifier for Spectre routes.
  """

  alias Spectre.Context
  alias Spectre.Inference
  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Input
  alias Spectre.Prompt.Plan
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Route
  alias Spectre.State

  @doc """
  Asks a configured LLM completion function to return exactly one label.
  """
  @spec classify(String.t(), [atom()], keyword()) :: {:ok, Route.t()} | {:error, term()}
  def classify(text, labels, opts \\ [])

  def classify(_text, [], _opts), do: {:error, :no_llm_classifier_labels}

  def classify(text, labels, opts) when is_binary(text) and is_list(labels) do
    with {:ok, prompt_text} <- prompt(text, labels, opts),
         {:ok, plan} <- Plan.compose(prompt_text, [], [:agent]),
         {:ok, model_text, inference_metadata} <- complete(plan, text, opts),
         {:ok, label} <- normalize_label(model_text, labels) do
      {:ok,
       Route.new(%{
         label: label,
         confidence: 0.0,
         margin: 0.0,
         scores: %{},
         accepted?: true,
         strategy: :llm_classifier,
         raw: model_text,
         metadata: inference_metadata
       })}
    end
  rescue
    exception ->
      {:error, {:llm_classifier_exception, exception.__struct__, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:llm_classifier_exit, reason}}
    kind, reason -> {:error, {:llm_classifier_failure, kind, reason}}
  end

  @doc """
  Returns true when LLM classification is enabled for the current router.

  `:llm_classifier?` is an explicit override for custom pipelines. Otherwise
  the strategy must be present in the router's `:via` list. Merely configuring
  a main response model does not opt an agent into LLM routing.
  """
  @spec enabled?(keyword()) :: boolean()
  def enabled?(opts) when is_list(opts) do
    case Keyword.fetch(opts, :llm_classifier?) do
      {:ok, enabled?} -> enabled? == true
      :error -> :llm_classifier in List.wrap(Keyword.get(opts, :via, []))
    end
  end

  @doc """
  Returns true when a classifier-specific or compatible main model is present.
  """
  @spec available?(keyword()) :: boolean()
  def available?(opts) when is_list(opts) do
    not is_nil(classifier_model(opts) || Keyword.get(opts, :model))
  end

  @spec complete(Plan.t(), String.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
  defp complete(plan, text, opts) do
    case classifier_model(opts) || Keyword.get(opts, :model) do
      nil ->
        {:error, :missing_llm_classifier_model}

      model ->
        complete_with_boundary(plan, text, complete_opts(opts, model, llm_opts(opts)))
    end
  end

  @spec complete_with_boundary(Plan.t(), String.t(), keyword()) ::
          {:ok, String.t(), map()} | {:error, term()}
  defp complete_with_boundary(plan, text, opts) do
    case Keyword.get(opts, :spectre_agent) do
      agent when is_atom(agent) and not is_nil(agent) ->
        input = Input.new(text)

        ctx = %Context{
          agent: agent,
          input: input,
          state: %State{},
          opts: opts
        }

        request = Request.for_classification(plan, ctx, opts)

        case Inference.complete(agent, request, ctx) do
          {:ok, response} ->
            metadata = %{
              inference: %{
                request_id: request.id,
                purpose: request.purpose,
                selection:
                  Map.take(response.selection, [
                    :level,
                    :reason,
                    :selector,
                    :profile_hash,
                    :attempt
                  ]),
                latency_ms: response.latency_ms,
                usage: response.usage
              }
            }

            {:ok, response.text, metadata}

          {:error, _reason} = error ->
            error
        end

      _no_agent ->
        case Spectre.LLM.complete(plan, opts) do
          {:ok, text} when is_binary(text) -> {:ok, text, %{}}
          {:ok, %Response{text: text}} -> {:ok, text, %{}}
          {:error, _reason} = error -> error
        end
    end
  end

  @spec classifier_model(keyword()) :: term() | nil
  defp classifier_model(opts) do
    opts
    |> classifier_config()
    |> Keyword.get(:adapter)
  end

  @spec complete_opts(keyword(), term(), keyword()) :: keyword()
  defp complete_opts(opts, model, classifier_opts) do
    opts
    |> Keyword.merge(classifier_opts)
    |> Keyword.put(:model, model)
  end

  @doc """
  Renders visible labels as a flow-grouped taxonomy block.

  Labels declared inside flows are grouped under their `flow_path`, one flow
  header per line ending with `/`, nested flows indented below their parent.
  Labels without a flow stay at the root level. When no visible rule declares
  a flow the output is the plain flat label list, one label per line.

  Each label carries up to `:examples` (default 2) example phrases taken from
  the rule's `embedding:`, `bag:`, and `jaro:` declarations, rendered as
  `LABEL — e.g. "phrase"; "phrase"`. Pass `examples: 0` to disable.

      tree = Spectre.Router.LLMClassifier.label_tree([:PAY_CARD], rules)
  """
  @spec label_tree([atom()], [Spectre.Rule.t() | map()], keyword()) :: String.t()
  def label_tree(labels, rules, opts \\ []) when is_list(labels) and is_list(rules) do
    examples = Keyword.get(opts, :examples, 2)

    meta =
      Map.new(rules, &{Map.get(&1, :label), {rule_flow_path(&1), rule_examples(&1, examples)}})

    entries =
      Enum.map(labels, fn label ->
        {path, phrases} = Map.get(meta, label, {[], []})
        {path, label, phrases}
      end)

    entries
    |> Enum.reduce(new_tree_node(), fn {path, label, phrases}, tree ->
      put_tree_entry(tree, path, label, phrases)
    end)
    |> render_tree_node(0)
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  @spec rule_flow_path(Spectre.Rule.t() | map()) :: [atom()]
  defp rule_flow_path(rule) do
    case Map.get(rule, :flow_path) do
      [_head | _tail] = path -> path
      _missing_or_empty -> rule |> Map.get(:flow) |> List.wrap()
    end
  end

  @spec rule_examples(Spectre.Rule.t() | map(), non_neg_integer()) :: [String.t()]
  defp rule_examples(_rule, 0), do: []

  defp rule_examples(rule, limit) do
    [:embedding, :bag, :jaro]
    |> Enum.flat_map(&List.wrap(Map.get(rule, &1, [])))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.take(limit)
  end

  @spec new_tree_node() :: map()
  defp new_tree_node, do: %{labels: [], child_order: [], children: %{}}

  @spec put_tree_entry(map(), [atom()], atom(), [String.t()]) :: map()
  defp put_tree_entry(tree, [], label, phrases) do
    %{tree | labels: [{label, phrases} | tree.labels]}
  end

  defp put_tree_entry(tree, [segment | rest], label, phrases) do
    case Map.fetch(tree.children, segment) do
      {:ok, child} ->
        updated_child = put_tree_entry(child, rest, label, phrases)
        %{tree | children: Map.put(tree.children, segment, updated_child)}

      :error ->
        child = put_tree_entry(new_tree_node(), rest, label, phrases)

        %{
          tree
          | child_order: [segment | tree.child_order],
            children: Map.put(tree.children, segment, child)
        }
    end
  end

  @spec render_tree_node(map(), non_neg_integer()) :: iodata()
  defp render_tree_node(tree, depth) do
    indent = String.duplicate("  ", depth)

    direct_lines =
      tree.labels
      |> Enum.reverse()
      |> Enum.map(fn {label, phrases} ->
        [indent, to_string(label), example_suffix(phrases), "\n"]
      end)

    nested_blocks =
      tree.child_order
      |> Enum.reverse()
      |> Enum.map(fn segment ->
        [
          [indent, to_string(segment), "/\n"],
          tree.children |> Map.fetch!(segment) |> render_tree_node(depth + 1)
        ]
      end)

    [direct_lines, nested_blocks]
  end

  @spec example_suffix([String.t()]) :: iodata()
  defp example_suffix([]), do: []

  defp example_suffix(phrases) do
    [" — e.g. ", Enum.map_join(phrases, "; ", &"\"#{&1}\"")]
  end

  @spec prompt(String.t(), [atom()], keyword()) :: {:ok, String.t()} | {:error, term()}
  defp prompt(text, labels, opts) do
    rules = Keyword.get(opts, :spectre_rules, [])
    visible_labels = MapSet.new(labels)

    base = %{
      text: text,
      labels: labels,
      label_tree: label_tree(labels, rules, examples: label_example_limit(opts)),
      label_groups?:
        Enum.any?(rules, fn rule ->
          MapSet.member?(visible_labels, Map.get(rule, :label)) and rule_flow_path(rule) != []
        end),
      agent: Keyword.get(opts, :spectre_agent),
      agent_context: opts |> classifier_config() |> Keyword.get(:context),
      recent_chat: Keyword.get(opts, :recent_chat, "none"),
      evidence: Keyword.get(opts, :classifier_evidence, [])
    }

    assigns =
      opts
      |> Keyword.get(:classifier_assigns, %{})
      |> normalize_assigns()
      |> Map.merge(base)
      |> put_active_flow(rules)

    case classifier_prompt(opts) do
      fun when is_function(fun, 1) ->
        Call.run(
          :prompt,
          fn -> fun.(assigns) |> normalize_prompt_result() end,
          opts |> Call.adapter_opts() |> Keyword.put(:purpose, :classifier_prompt)
        )

      nil ->
        {:ok, default_prompt(assigns)}
    end
  end

  @spec classifier_prompt(keyword()) :: function() | nil
  defp classifier_prompt(opts) do
    opts
    |> classifier_config()
    |> Keyword.get(:prompt)
  end

  @spec normalize_prompt_result(term()) :: {:ok, String.t()} | {:error, term()}
  defp normalize_prompt_result({:ok, prompt}) when is_binary(prompt), do: {:ok, prompt}
  defp normalize_prompt_result(prompt) when is_binary(prompt), do: {:ok, prompt}

  defp normalize_prompt_result({:error, reason}), do: {:error, reason}

  defp normalize_prompt_result(other),
    do: {:error, Failure.invalid_reply(:prompt, other)}

  @spec normalize_assigns(map() | keyword() | term()) :: map()
  defp normalize_assigns(assigns) when is_map(assigns), do: assigns
  defp normalize_assigns(assigns) when is_list(assigns), do: Map.new(assigns)
  defp normalize_assigns(_assigns), do: %{}

  @spec default_prompt(map()) :: String.t()
  defp default_prompt(
         %{
           text: text,
           labels: labels,
           recent_chat: recent_chat,
           evidence: evidence
         } = assigns
       ) do
    """
    #{intro_section(assigns)}
    Reply with the label only, no explanation.

    #{labels_section(assigns, labels)}
    #{context_sections(assigns)}
    Recent chat:
    #{recent_chat}

    Routing evidence:
    #{format_evidence(evidence)}

    Latest message:
    #{text}
    """
  end

  @spec label_example_limit(keyword()) :: non_neg_integer()
  defp label_example_limit(opts) do
    case opts |> classifier_config() |> Keyword.get(:label_examples, 2) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _invalid -> 2
    end
  end

  @spec put_active_flow(map(), [Spectre.Rule.t() | map()]) :: map()
  defp put_active_flow(assigns, rules) do
    active =
      case Map.get(assigns, :state) do
        %{current_flow: flow} when is_atom(flow) and not is_nil(flow) ->
          format_active_flow(flow, rules)

        _no_state ->
          nil
      end

    assigns
    |> Map.put_new(:active_flow, active)
    |> Map.put_new(:chat_summary, state_chat_summary(assigns))
  end

  @spec state_chat_summary(map()) :: String.t() | nil
  defp state_chat_summary(assigns) do
    case Map.get(assigns, :state) do
      %{data: data} when is_map(data) ->
        case Map.get(data, :chat_summary, Map.get(data, "chat_summary")) do
          summary when is_binary(summary) and summary != "" -> summary
          _missing -> nil
        end

      _no_state ->
        nil
    end
  end

  @spec format_active_flow(atom(), [Spectre.Rule.t() | map()]) :: String.t()
  defp format_active_flow(flow, rules) do
    rules
    |> Enum.map(&rule_flow_path/1)
    |> Enum.find([flow], &(flow in &1))
    |> Enum.take_while(&(&1 != flow))
    |> Kernel.++([flow])
    |> Enum.map_join("/", &to_string/1)
  end

  @spec intro_section(map()) :: String.t()
  defp intro_section(assigns) do
    case Map.get(assigns, :agent) do
      agent when is_atom(agent) and not is_nil(agent) ->
        "You are the intent router for the agent #{inspect(agent)}.\n" <>
          "Classify the user's latest message into exactly ONE label."

      _no_agent ->
        "Classify the latest message into exactly ONE label."
    end
  end

  @spec labels_section(map(), [atom()]) :: String.t()
  defp labels_section(assigns, labels) do
    flat = Enum.map_join(labels, "\n", &to_string/1)
    tree = Map.get(assigns, :label_tree, flat)
    grouped? = Map.get(assigns, :label_groups?, tree != flat)
    examples? = String.contains?(tree, " — e.g. ")

    header =
      ["Available labels"]
      |> append_if(grouped?, [
        ", grouped by conversation flow.",
        " Indentation shows the hierarchy; lines ending with \"/\"",
        " are flow groups, not valid answers"
      ])
      |> append_if(examples?, [
        ". The quoted phrases after a label are examples of user messages",
        " that belong to it"
      ])
      |> IO.iodata_to_binary()

    "#{header}:\n#{tree}"
  end

  @spec append_if(iodata(), boolean(), iodata()) :: iodata()
  defp append_if(iodata, true, extra), do: [iodata, extra]
  defp append_if(iodata, false, _extra), do: iodata

  @spec context_sections(map()) :: String.t()
  defp context_sections(assigns) do
    [
      context_section(assigns, :agent_context, &"\nAgent context:\n#{&1}\n"),
      context_section(
        assigns,
        :active_flow,
        &("\nActive conversation flow: #{&1}\n" <>
            "Prefer labels inside this flow when the message plausibly continues it.\n")
      ),
      context_section(
        assigns,
        :chat_summary,
        &"\nConversation summary (older turns):\n#{&1}\n"
      )
    ]
    |> Enum.join()
  end

  @spec context_section(map(), atom(), (String.t() -> String.t())) :: String.t()
  defp context_section(assigns, key, render) do
    case Map.get(assigns, key) do
      value when is_binary(value) and value != "" -> render.(value)
      _missing -> ""
    end
  end

  @spec format_evidence([map()] | term()) :: String.t()
  defp format_evidence([]), do: "none"

  defp format_evidence(evidence) when is_list(evidence) do
    Enum.map_join(evidence, "\n", fn item ->
      provider = Map.get(item, :provider, :unknown)
      label = Map.get(item, :label, :unknown)
      score = Map.get(item, :score)
      margin = Map.get(item, :margin)
      accepted? = Map.get(item, :accepted?, false)

      "#{provider}: label=#{label}, score=#{inspect(score)}, " <>
        "margin=#{inspect(margin)}, accepted=#{accepted?}"
    end)
  end

  defp format_evidence(_evidence), do: "none"

  @spec llm_opts(keyword()) :: keyword()
  defp llm_opts(opts) do
    opts
    |> classifier_config()
    |> Keyword.get(:llm_opts, [])
    |> Keyword.put_new(:purpose, :classifier)
    |> Keyword.put_new(:temperature, 0.0)
    |> Keyword.put_new(:max_tokens, 8)
  end

  @spec classifier_config(keyword()) :: keyword()
  defp classifier_config(opts) do
    case Keyword.get(opts, :classifier, []) do
      config when is_list(config) -> config
      _other -> []
    end
  end

  @spec normalize_label(term(), [atom()]) :: {:ok, atom()} | {:error, term()}
  defp normalize_label(text, labels) do
    normalized = text |> clean_model_label() |> canonical_label()

    matches = Enum.filter(labels, &(canonical_label(&1) == normalized))

    case matches do
      [label] -> {:ok, label}
      [] -> {:error, {:unknown_llm_classifier_label, text}}
      labels -> {:error, {:ambiguous_llm_classifier_labels, labels}}
    end
  end

  @spec clean_model_label(term()) :: String.t()
  defp clean_model_label(text) do
    text
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\A```(?:text)?\s*/iu, "")
    |> String.replace(~r/\s*```\z/u, "")
    |> String.replace(~r/\Alabel\s*:\s*/iu, "")
    |> String.trim(" \t\r\n\"'`.")
  end

  @spec canonical_label(atom() | String.t()) :: String.t()
  defp canonical_label(label) do
    label
    |> to_string()
    |> String.upcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
    |> String.trim("_")
  end
end
