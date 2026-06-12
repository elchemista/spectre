defmodule Spectre.Classifier.Encoder do
  @moduledoc """
  Configurable embedding boundary for Spectre classifier artifacts.
  """

  @default_model "intfloat/multilingual-e5-small"
  @default_adapter Spectre.Classifier.Embeddings.ExFastembed

  @type embedding :: [float()]

  @doc """
  Returns the default embedding model used by the lightweight classifier.
  """
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @doc """
  Downloads/loads the embedding model and returns its vector dimensions.
  """
  @spec download(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def download(model \\ @default_model, opts \\ []) when is_binary(model) do
    case configured_download(opts) do
      {:ok, callback} -> call_download(callback, model, opts)
      :default -> call_adapter(:download, model, opts)
    end
  end

  @doc """
  Loads the embedding model and returns its vector dimensions.
  """
  @spec load(String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def load(model \\ @default_model, opts \\ []) when is_binary(model) do
    case configured_load(opts) do
      {:ok, callback} -> call_load(callback, model, opts)
      :default -> call_adapter(:load, model, opts)
    end
  end

  @doc """
  Embeds one text value with the loaded model.
  """
  @spec embed(String.t(), keyword()) :: {:ok, embedding()} | {:error, term()}
  def embed(text, opts \\ []) when is_binary(text) do
    case configured_embed(opts) do
      {:ok, callback} -> call_embed(callback, text, opts)
      :default -> call_adapter(:embed, text, opts)
    end
  end

  @spec configured_download(keyword()) :: {:ok, term()} | :default
  defp configured_download(opts), do: configured_callback(opts, :download)

  @spec configured_load(keyword()) :: {:ok, term()} | :default
  defp configured_load(opts), do: configured_callback(opts, :load_embedding)

  @spec configured_embed(keyword()) :: {:ok, term()} | :default
  defp configured_embed(opts), do: configured_callback(opts, :embed)

  @spec configured_callback(keyword(), atom()) :: {:ok, term()} | :default
  defp configured_callback(opts, key) do
    opts
    |> embedding_opts()
    |> Keyword.fetch(key)
    |> case do
      {:ok, callback} -> {:ok, callback}
      :error -> :default
    end
  end

  @spec call_adapter(atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp call_adapter(function, value, opts) do
    adapter = opts |> embedding_opts() |> Keyword.get(:embedding_adapter, @default_adapter)
    call_module(adapter, function, value, opts)
  end

  @spec call_download(term(), String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  defp call_download(callback, model, opts), do: call_callback(callback, :download, model, opts)

  @spec call_load(term(), String.t(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  defp call_load(callback, model, opts), do: call_callback(callback, :load, model, opts)

  @spec call_embed(term(), String.t(), keyword()) :: {:ok, embedding()} | {:error, term()}
  defp call_embed(callback, text, opts), do: call_callback(callback, :embed, text, opts)

  @spec call_callback(term(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp call_callback(callback, _function, value, opts) when is_function(callback, 2),
    do: callback.(value, opts)

  defp call_callback(callback, _function, value, _opts) when is_function(callback, 1),
    do: callback.(value)

  defp call_callback({module, function}, _default_function, value, opts)
       when is_atom(module) and is_atom(function),
       do: call_module(module, function, value, opts)

  defp call_callback(module, function, value, opts) when is_atom(module),
    do: call_module(module, function, value, opts)

  defp call_callback(callback, _function, _value, _opts),
    do: {:error, {:invalid_embedding_callback, callback}}

  @spec call_module(module(), atom(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  defp call_module(module, function, value, opts) do
    cond do
      function_exported?(module, function, 2) ->
        apply(module, function, [value, opts])

      function_exported?(module, function, 1) ->
        apply(module, function, [value])

      true ->
        {:error, {:missing_embedding_callback, module, function}}
    end
  end

  @spec embedding_opts(keyword()) :: keyword()
  defp embedding_opts(opts) do
    :spectre
    |> Application.get_env(:classifier, [])
    |> Keyword.merge(opts)
  end
end
