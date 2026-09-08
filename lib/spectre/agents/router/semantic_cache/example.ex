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
  def new(attrs, config, revision) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(attrs, @fields ++ [:profile_ref], :cache_example),
         id = Map.get_lazy(attrs, :id, &Id.generate/0),
         true <- string?(id, 128),
         {:ok, text} <- text(Map.get(attrs, :text), config.max_text_bytes),
         label = Map.get(attrs, :label),
         true <- MapSet.member?(config.labels, label),
         :ok <-
           profile(
             Map.get(attrs, :embedding),
             Map.get(attrs, :profile_ref),
             config.binding.profile_ref
           ),
         {:ok, embedding} <- embedding(Map.get(attrs, :embedding), config.dimensions) do
      {:ok,
       %__MODULE__{
         id: id,
         text: text,
         label: label,
         embedding: embedding,
         source: "online_learned",
         verified: false,
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
           Portable.normalize_attrs(
             attrs,
             [:text, :label, :embedding, :profile_ref],
             :cache_example_update
           ) do
      original = example |> Map.take(@fields) |> Map.put(:profile_ref, config.binding.profile_ref)

      original =
        if Map.has_key?(attrs, :embedding), do: Map.delete(original, :profile_ref), else: original

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
  def profile(nil, _supplied, _expected), do: :ok
  def profile(_vector, ref, ref) when is_binary(ref), do: :ok
  def profile(_vector, _supplied, _expected), do: {:error, :cache_encoder_profile_mismatch}

  @doc false
  def embedding(nil, _dimensions), do: {:ok, nil}

  def embedding(values, dimensions) when is_list(values) do
    if length(values) in 1..8192 and (is_nil(dimensions) or length(values) == dimensions) and
         Enum.all?(values, &is_number/1) do
      floats = Enum.map(values, &(&1 / 1))
      with :ok <- Portable.validate(floats), do: {:ok, floats}
    else
      {:error, :invalid_cache_embedding}
    end
  rescue
    ArithmeticError -> {:error, :invalid_cache_embedding}
  end

  def embedding(_value, _dimensions), do: {:error, :invalid_cache_embedding}

  @doc "Returns a JSON-compatible snapshot including approval and stored vectors."
  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = example),
    do: Map.new(Map.from_struct(example), fn {key, value} -> {Atom.to_string(key), value} end)

  @doc false
  def from_backend(%__MODULE__{} = example), do: from_backend(Map.from_struct(example))

  def from_backend(value) do
    with {:ok, attrs} <- Portable.normalize_attrs(value, @enforce_keys, :cache_example),
         true <- map_size(attrs) == length(@enforce_keys),
         true <-
           string?(attrs.id, 128) and string?(attrs.label, 256) and string?(attrs.source, 128),
         true <- is_boolean(attrs.verified) and is_integer(attrs.revision) and attrs.revision > 0,
         {:ok, text} <- text(attrs.text, 65_536),
         {:ok, embedding} <- embedding(attrs.embedding, nil) do
      {:ok, struct!(__MODULE__, %{attrs | text: text, embedding: embedding})}
    else
      _invalid -> {:error, :invalid_cache_example_reply}
    end
  end

  @doc false
  def restore(value, config) when is_map(value) do
    with true <-
           Enum.sort(Map.keys(value)) == Enum.sort(Enum.map(@enforce_keys, &Atom.to_string/1)),
         revision = value["revision"],
         true <- is_integer(revision) and revision > 0,
         verified = value["verified"],
         true <- value["source"] === "online_learned" and is_boolean(verified),
         {:ok, example} <-
           new(
             value
             |> Map.take(Enum.map(@fields, &Atom.to_string/1))
             |> Map.put("profile_ref", config.binding.profile_ref),
             config,
             revision
           ) do
      {:ok, %{example | verified: verified}}
    else
      _invalid -> {:error, :invalid_cache_snapshot_example}
    end
  end

  def restore(_value, _config), do: {:error, :invalid_cache_snapshot_example}

  defp string?(value, limit),
    do: is_binary(value) and byte_size(value) in 1..limit and String.valid?(value)

  @doc "Returns a small nomination bound to the exact approved revision, not its private payload."
  def nomination(%__MODULE__{verified: true} = example, score, binding) do
    %{
      label: example.label,
      score: score,
      example_ref: example.id,
      example_revision: example.revision,
      content_ref: Portable.content_ref!(:cache_example, dump(example)),
      binding: binding
    }
  end
end
