defmodule Spectre.Classifier.Embedding do
  @moduledoc """
  Behaviour for classifier embedding adapters.
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
