defmodule Spectre.Input do
  @moduledoc """
  Normalized inbound user turn.

  Host applications can pass strings, atom-key maps, or string-key maps at the
  public boundary. Spectre immediately converts them into this struct so router
  checks, prompt rendering, and action execution do not depend on external
  payload shapes.

      input = Spectre.Input.new(%{"text" => "Hello", "meta" => %{"locale" => "en"}})
      input = Spectre.Input.put_meta(input, :channel, :web)
  """

  alias Spectre.Input.Source

  defstruct text: "", meta: %{}, raw: nil, source: nil

  @type t :: %__MODULE__{
          text: String.t(),
          meta: map(),
          raw: term(),
          source: Source.t() | nil
        }

  @doc """
  Normalizes raw inbound input into a Spectre input struct.

      Spectre.Input.new("hello")
      Spectre.Input.new(%{text: "hello", meta: %{tenant_id: 123}})
  """
  @spec new(t() | String.t() | map() | term()) :: t()
  def new(%__MODULE__{} = input), do: input

  def new(text) when is_binary(text), do: %__MODULE__{text: text, raw: text}

  def new(%{text: text} = input) when is_binary(text) do
    %__MODULE__{
      text: text,
      meta: Map.get(input, :meta, Map.get(input, "meta", %{})),
      raw: input,
      source: normalize_source(Map.get(input, :source, Map.get(input, "source")))
    }
  end

  def new(%{"text" => text} = input) when is_binary(text) do
    %__MODULE__{
      text: text,
      meta: Map.get(input, "meta", %{}),
      raw: input,
      source: normalize_source(Map.get(input, "source"))
    }
  end

  def new(input) when is_map(input), do: %__MODULE__{raw: input}

  def new(input), do: %__MODULE__{text: to_string(input), raw: input}

  @doc """
  Stores enriched metadata on the input.

      input = Spectre.Input.put_meta(input, :locale, "en")
  """
  @spec put_meta(t(), atom() | String.t(), term()) :: t()
  def put_meta(%__MODULE__{} = input, key, value) do
    %{input | meta: Map.put(input.meta || %{}, normalize_key(key), value)}
  end

  @doc """
  Merges enriched metadata onto the input.

      input = Spectre.Input.merge_meta(input, locale: "en", channel: :web)
  """
  @spec merge_meta(t(), map() | keyword()) :: t()
  def merge_meta(%__MODULE__{} = input, meta) when is_list(meta) or is_map(meta) do
    Enum.reduce(meta, input, fn {key, value}, input -> put_meta(input, key, value) end)
  end

  @doc """
  Fetches enriched metadata.

      {:ok, "en"} = Spectre.Input.fetch_meta(input, :locale)
  """
  @spec fetch_meta(t(), atom() | String.t()) :: {:ok, term()} | :error
  def fetch_meta(%__MODULE__{} = input, key) do
    key = normalize_key(key)

    cond do
      is_map(input.meta) and Map.has_key?(input.meta, key) ->
        {:ok, Map.fetch!(input.meta, key)}

      is_atom(key) and is_map(input.meta) and Map.has_key?(input.meta, Atom.to_string(key)) ->
        {:ok, Map.fetch!(input.meta, Atom.to_string(key))}

      true ->
        :error
    end
  end

  @spec normalize_key(atom() | String.t() | term()) :: atom() | String.t()
  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp normalize_key(key), do: key

  @spec normalize_source(Source.t() | map() | keyword() | nil) :: Source.t() | nil
  defp normalize_source(nil), do: nil
  defp normalize_source(source), do: Source.new(source)
end
