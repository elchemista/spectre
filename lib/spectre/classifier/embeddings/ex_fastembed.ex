defmodule Spectre.Classifier.Embeddings.ExFastembed do
  @moduledoc """
  Default classifier embedding adapter backed by `ExFastembed`.
  """

  @behaviour Spectre.Classifier.Embedding

  @ex_fastembed Module.concat(["ExFastembed"])

  @impl true
  @spec download(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def download(model, opts \\ []) when is_binary(model), do: load(model, opts)

  @impl true
  @spec load(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def load(model, _opts \\ []) when is_binary(model) do
    with :ok <- ensure_ex_fastembed() do
      case call_ex_fastembed(:load, [model]) do
        {:ok, dimensions} -> {:ok, dimensions}
        {:error, reason} -> maybe_loaded_dimensions(reason)
      end
    end
  end

  @impl true
  @spec embed(String.t(), keyword()) ::
          {:ok, Spectre.Classifier.Embedding.vector()} | {:error, term()}
  def embed(text, _opts \\ []) when is_binary(text) do
    with :ok <- ensure_ex_fastembed() do
      case call_ex_fastembed(:embed_text, [[text]]) do
        {:ok, [vector | _]} -> {:ok, Enum.map(vector, &(&1 / 1))}
        {:ok, []} -> {:error, :empty_embedding}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec maybe_loaded_dimensions(term()) :: {:ok, pos_integer()} | {:error, term()}
  defp maybe_loaded_dimensions(reason) when is_binary(reason) do
    if reason |> String.downcase() |> String.contains?("already loaded") do
      with {:ok, vector} <- embed("dimension probe"), do: {:ok, length(vector)}
    else
      {:error, reason}
    end
  end

  defp maybe_loaded_dimensions(reason), do: {:error, reason}

  @spec ensure_ex_fastembed() :: :ok | {:error, term()}
  defp ensure_ex_fastembed do
    if Code.ensure_loaded?(@ex_fastembed) do
      :ok
    else
      {:error, {:missing_dependency, :ex_fastembed}}
    end
  end

  @spec call_ex_fastembed(atom(), [term()]) :: term()
  defp call_ex_fastembed(function, args) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(@ex_fastembed, function, args)
  end
end
