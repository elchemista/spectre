defmodule Spectre.Router.SemanticCache.Example do
  @moduledoc """
  One reviewable routing example, not Evidence and not an authorization.

  Embeddings are supplied by the host or an offline dataset. Changing text or
  label withdraws approval; changing text also discards its old embedding.
  Review uses the exact revision shown to the reviewer, preventing a concurrent
  edit from being approved accidentally.
  """

  alias Spectre.{Id, Portable}

  @fields [:id, :text, :label, :embedding]
  @enforce_keys @fields ++ [:source, :verified, :revision]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: String.t(),
          text: String.t(),
          label: String.t(),
          embedding: [float()] | nil,
          source: String.t(),
          verified: boolean(),
          revision: pos_integer()
        }

  @doc false
  def new(attrs, config, revision, source \\ "online_learned") do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :cache_example),
         id = Map.get_lazy(attrs, :id, &Id.generate/0),
         true <- string?(id, 128),
         {:ok, text} <- text(Map.get(attrs, :text), config.max_text_bytes),
         label = Map.get(attrs, :label),
         true <- MapSet.member?(config.labels, label),
         {:ok, embedding} <- embedding(Map.get(attrs, :embedding), config.dimensions) do
      {:ok,
       %__MODULE__{
         id: id,
         text: text,
         label: label,
         embedding: embedding,
         source: source,
         verified: source != "online_learned",
         revision: revision
       }}
    else
      false -> {:error, :invalid_cache_example_identity_or_label}
      {:error, _} = error -> error
    end
  end

  @doc false
  def update(%__MODULE__{} = example, attrs, config, revision) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(attrs, [:text, :label, :embedding], :cache_example_update) do
      original = Map.take(example, @fields)

      original =
        if Map.has_key?(attrs, :text) and attrs.text !== example.text,
          do: Map.put(original, :embedding, nil),
          else: original

      new(Map.merge(original, attrs), config, revision)
    end
  end

  @doc false
  def text(value, max_bytes) do
    if string?(value, max_bytes) and String.trim(value) != "",
      do: {:ok, String.trim(value)},
      else: {:error, :invalid_cache_text}
  end

  @doc false
  def normalize(text), do: text |> String.trim() |> String.downcase()

  @doc false
  def embedding(nil, _dimensions), do: {:ok, nil}

  def embedding(values, dimensions) when is_list(values) do
    if length(values) == dimensions and Enum.all?(values, &finite?/1) and
         Enum.any?(values, &(&1 != 0)) do
      {:ok, Enum.map(values, &(&1 / 1))}
    else
      {:error, :invalid_cache_embedding}
    end
  end

  def embedding(_value, _dimensions), do: {:error, :invalid_cache_embedding}

  @doc "Returns a JSON-compatible snapshot including approval and stored vectors."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = example),
    do: Map.new(Map.from_struct(example), fn {key, value} -> {Atom.to_string(key), value} end)

  @doc false
  def restore(value, config) when is_map(value) do
    with true <-
           Enum.sort(Map.keys(value)) == Enum.sort(Enum.map(@enforce_keys, &Atom.to_string/1)),
         revision = value["revision"],
         true <- is_integer(revision) and revision > 0,
         source = value["source"],
         true <- source in ["online_learned", "offline_dataset", "static_route_example"],
         verified = value["verified"],
         true <- is_boolean(verified) and (source == "online_learned" or verified),
         {:ok, example} <-
           new(Map.take(value, Enum.map(@fields, &Atom.to_string/1)), config, revision, source) do
      {:ok, %{example | verified: verified}}
    else
      _invalid -> {:error, :invalid_cache_snapshot_example}
    end
  end

  def restore(_value, _config), do: {:error, :invalid_cache_snapshot_example}

  defp string?(value, limit),
    do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)

  # Vettore stores f32 vectors. Reject overflow and the zero vector before the
  # native boundary, including arbitrarily large Elixir integers.
  defp finite?(value), do: is_number(value) and abs(value) <= 3.402_823_466_385_288_6e38
end
