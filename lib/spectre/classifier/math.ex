defmodule Spectre.Classifier.Math do
  @moduledoc false

  alias Vettore.Distance

  @doc """
  Returns a normalized centroid for vectors.
  """
  @spec centroid([[number()]]) :: [float()]
  def centroid(vectors) when is_list(vectors) do
    vectors
    |> average()
    |> normalize()
  end

  @doc """
  Returns cosine similarity in `[-1.0, 1.0]`.
  """
  @spec cosine([number()], [number()]) :: float()
  def cosine(left, right) when is_list(left) and is_list(right) do
    left
    |> Distance.cosine(right)
    |> raw_cosine_score()
  end

  @doc """
  Returns Vettore's raw cosine score.
  """
  @spec raw_cosine_score(term()) :: float()
  def raw_cosine_score({:ok, score}) when is_number(score), do: raw_cosine_score(score)
  def raw_cosine_score({:error, _reason}), do: 0.0
  def raw_cosine_score(score) when is_number(score), do: score / 1
  def raw_cosine_score(_other), do: 0.0

  @doc """
  Normalizes a vector to unit length.
  """
  @spec normalize([number()]) :: [float()]
  def normalize(vector) when is_list(vector) do
    case Distance.normalize(vector, :l2) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> Enum.map(vector, fn _ -> 0.0 end)
    end
  end

  @spec average([[number()]]) :: [float()]
  defp average([]), do: []

  defp average(vectors) do
    count = length(vectors)

    vectors
    |> Enum.zip_with(fn values -> Enum.sum(values) / count end)
    |> Enum.map(&(&1 / 1))
  end
end
