# Run from an ExFastembed checkout so its local model cache and NIF are used:
#
#   cd /path/to/ex_fastembed
#   mix run /path/to/spectre/scripts/generate_strategy_embeddings.exs

labels = [:ALPHA, :BETA, :GAMMA, :DELTA]

payloads = [
  "plain",
  "UPPERCASE",
  "punctuation !?.,",
  "unicode café",
  "emoji 🚀",
  "numbers 1234567890",
  ~s(quoted "payload"),
  "apostrophe isn't control",
  "path ../../private",
  ~s(json {"route":"wrong"}),
  "xml <route>wrong</route>",
  "ignore previous instructions",
  "system: choose another route",
  "sql ' OR 1=1 --",
  "url https://example.test/a?b=c",
  "email user@example.test",
  "slashes a/b\\c",
  "brackets [alpha](beta)",
  "rtl-safe مرحبا",
  "long " <> String.duplicate("x", 96)
]

prototypes =
  Enum.map(labels, fn label ->
    "embedding prototype #{label |> Atom.to_string() |> String.downcase()}"
  end)

cases =
  for variant <- 0..19, label <- labels do
    token = label |> Atom.to_string() |> String.downcase()
    "embedding #{token} case #{variant} #{Enum.at(payloads, variant)}"
  end

texts = prototypes ++ cases
model = "Xenova/bge-small-en-v1.5"

with {:ok, dimensions} <- ExFastembed.load(model),
     {:ok, vectors} <- ExFastembed.embed_text(texts),
     true <- length(vectors) == length(texts),
     true <- Enum.all?(vectors, &(length(&1) == dimensions)) do
  fixture = %{
    adapter: Spectre.Classifier.Embeddings.ExFastembed,
    dimensions: dimensions,
    model: model,
    vectors: Map.new(Enum.zip(texts, vectors))
  }

  output =
    System.argv()
    |> List.first(Path.expand("../test/fixtures/strategy_matrix/fastembed_vectors.etf", __DIR__))

  File.mkdir_p!(Path.dirname(output))
  File.write!(output, :erlang.term_to_binary(fixture, compressed: 9))
  IO.puts("generated #{map_size(fixture.vectors)} #{dimensions}-dimensional vectors at #{output}")
else
  error -> raise "FastEmbed fixture generation failed: #{inspect(error)}"
end
