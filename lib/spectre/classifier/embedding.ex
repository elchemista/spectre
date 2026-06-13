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

  @callback load(model :: String.t(), opts :: keyword()) ::
              {:ok, pos_integer()} | {:error, term()}

  @callback embed(text :: String.t(), opts :: keyword()) ::
              {:ok, vector()} | {:error, term()}

  @callback download(model :: String.t(), opts :: keyword()) ::
              {:ok, pos_integer()} | {:error, term()}

  @optional_callbacks download: 2
end
