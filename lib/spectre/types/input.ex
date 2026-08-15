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
  Validates the normalized input shape without inspecting its raw transport.

  Raw payloads are deliberately allowed here because they remain local to the
  inbound boundary and are removed by the Run checkpoint projection.
  """
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = input) do
    with :ok <- validate_text(input.text),
         :ok <- validate_metadata(input.meta) do
      validate_source(input.source)
    end
  end

  def validate(_input), do: {:error, :invalid_input}

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

  @doc "Returns the source trust class, defaulting missing legacy sources to untrusted."
  @spec trust(t()) :: :untrusted | :trusted | :system
  def trust(%__MODULE__{source: %Source{trust: trust} = source}) do
    if match?(:ok, Source.validate(source)), do: trust, else: :untrusted
  end

  def trust(%__MODULE__{}), do: :untrusted

  @doc "Returns portable source evidence suitable for prompt/materialization metadata."
  @spec source_evidence(t()) :: map()
  def source_evidence(%__MODULE__{source: %Source{} = source}) do
    if match?(:ok, Source.validate(source)) do
      %{
        kind: source.kind,
        trust: source.trust,
        provenance: source.provenance,
        authenticity: source.authenticity
      }
    else
      legacy_source_evidence()
    end
  end

  def source_evidence(%__MODULE__{}), do: legacy_source_evidence()

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

  defp validate_text(text) when is_binary(text) do
    if String.valid?(text) and not String.contains?(text, <<0>>),
      do: :ok,
      else: {:error, :invalid_input_text}
  end

  defp validate_text(_text), do: {:error, :invalid_input_text}

  defp validate_metadata(metadata) when is_map(metadata) and not is_struct(metadata), do: :ok
  defp validate_metadata(_metadata), do: {:error, :invalid_input_metadata}

  defp validate_source(nil), do: :ok
  defp validate_source(%Source{} = source), do: Source.validate(source)
  defp validate_source(_source), do: {:error, :invalid_input_source}

  defp legacy_source_evidence,
    do: %{kind: :legacy, trust: :untrusted, provenance: %{}, authenticity: %{}}
end
