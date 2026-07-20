defmodule Spectre.Classifier.Embeddings.ExFastembed do
  @moduledoc """
  Default classifier embedding adapter backed by `ExFastembed`.
  """

  @behaviour Spectre.Classifier.Embedding

  @ex_fastembed Module.concat(["ExFastembed"])

  @impl Spectre.Classifier.Embedding
  @spec download(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def download(model, opts \\ []) when is_binary(model), do: load(model, opts)

  @impl Spectre.Classifier.Embedding
  @spec load(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def load(model, opts \\ []) when is_binary(model) do
    backend = backend(opts)

    with :ok <- ensure_ex_fastembed(backend) do
      case call_ex_fastembed(backend, :load, [model]) do
        {:ok, dimensions} -> {:ok, dimensions}
        {:error, reason} -> maybe_loaded_dimensions(reason, opts)
      end
    end
  end

  @impl Spectre.Classifier.Embedding
  @spec embed(String.t(), keyword()) ::
          {:ok, Spectre.Classifier.Embedding.vector()} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    backend = backend(opts)

    with :ok <- ensure_ex_fastembed(backend) do
      case call_ex_fastembed(backend, :embed_text, [[text]]) do
        {:ok, [vector | _]} -> {:ok, Enum.map(vector, &(&1 / 1))}
        {:ok, []} -> {:error, :empty_embedding}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec maybe_loaded_dimensions(term(), keyword()) ::
          {:ok, pos_integer()} | {:error, term()}
  defp maybe_loaded_dimensions(reason, opts) when is_binary(reason) do
    if reason |> String.downcase() |> String.contains?("already loaded") do
      with {:ok, vector} <- embed("dimension probe", opts), do: {:ok, length(vector)}
    else
      {:error, reason}
    end
  end

  defp maybe_loaded_dimensions(reason, _opts), do: {:error, reason}

  @spec backend(keyword()) :: module()
  defp backend(opts), do: Keyword.get(opts, :ex_fastembed_module, @ex_fastembed)

  @spec ensure_ex_fastembed(module()) :: :ok | {:error, term()}
  defp ensure_ex_fastembed(backend) do
    if Code.ensure_loaded?(backend) do
      :ok
    else
      {:error, {:missing_dependency, :ex_fastembed}}
    end
  end

  @spec call_ex_fastembed(module(), atom(), [term()]) :: term()
  defp call_ex_fastembed(backend, function, args) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(backend, function, args)
  end
end
