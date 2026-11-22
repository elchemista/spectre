defmodule Spectre.Classifier.Embedding do
  @moduledoc """
  Behaviour for classifier embedding adapters.

  Implement this behaviour when the default `ExFastembed` adapter is not the
  right boundary for the application.

      defmodule MyApp.Embedding do
        @behaviour Spectre.Classifier.Embedding

        @impl Spectre.Classifier.Embedding
        def load(_model, _opts), do: {:ok, 384}

        @impl Spectre.Classifier.Embedding
        def embed(text, _opts), do: MyApp.EmbeddingClient.embed(text)
      end
  """

  @type vector :: [float()]

  @doc "Loads the requested model or initializes access to it and reports its vector size."
  @callback load(model :: String.t(), opts :: keyword()) ::
              {:ok, pos_integer()} | {:error, term()}

  @doc "Embeds the supplied text as a vector of the dimension reported by `c:load/2`."
  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, vector()} | {:error, term()}

  @doc "Optionally prepares a model artifact for later use and reports its vector size."
  @callback download(model :: String.t(), opts :: keyword()) ::
              {:ok, pos_integer()} | {:error, term()}

  @optional_callbacks download: 2
end
