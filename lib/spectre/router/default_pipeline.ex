defmodule Spectre.Router.DefaultPipeline do
  @moduledoc """
  Default router pipeline for Spectre agents.

  The pipeline mirrors the original AgentCore shape while staying adapter-based:
  deterministic regex, exact semantic cache, local classifier, semantic search,
  LLM fallback, and terminalization.
  """

  use Spectre.Pipeline

  pipeline do
    plug(Spectre.Router.Plugs.Regex)
    plug(Spectre.Router.Plugs.SemanticCacheExact)
    plug(Spectre.Router.Plugs.BagDistance)
    plug(Spectre.Router.Plugs.JaroDistance)
    plug(Spectre.Router.Plugs.EmbeddingSimilarity)
    plug(Spectre.Router.Plugs.LocalClassifier)
    plug(Spectre.Router.Plugs.SemanticCacheSearch)
    plug(Spectre.Router.Plugs.Arbitrate)
    plug(Spectre.Router.Plugs.Terminalize)
  end
end
