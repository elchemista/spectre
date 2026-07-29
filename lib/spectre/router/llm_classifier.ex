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

  @spec prompt(String.t(), [atom()], keyword()) :: {:ok, String.t()} | {:error, term()}
  defp prompt(text, labels, opts) do
    base = %{
      text: text,
      labels: labels,
      recent_chat: Keyword.get(opts, :recent_chat, "none"),
      evidence: Keyword.get(opts, :classifier_evidence, [])
    }

    assigns =
      opts
      |> Keyword.get(:classifier_assigns, %{})
      |> normalize_assigns()
      |> Map.merge(base)

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
  defp default_prompt(%{
         text: text,
         labels: labels,
         recent_chat: recent_chat,
         evidence: evidence
       }) do
    """
    Classify the latest message into exactly ONE label.
    Reply with the label only, no explanation.

    Available labels:
    #{Enum.map_join(labels, "\n", &to_string/1)}

    Recent chat:
    #{recent_chat}

    Routing evidence:
    #{format_evidence(evidence)}

    Latest message:
    #{text}
    """
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

  @spec normalize_label(term(), [atom()]) :: {:ok, atom()}
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
