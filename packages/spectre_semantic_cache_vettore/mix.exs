defmodule SpectreSemanticCacheVettore.MixProject do
  use Mix.Project

  def project do
    [
      app: :spectre_semantic_cache_vettore,
      version: "0.4.0",
      elixir: "~> 1.19",
      description: "Optional Vettore search backend for Spectre's reviewable routing cache.",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"Source" => "https://github.com/elchemista/spectre"}
      ],
      deps: [spectre_dep(), {:vettore, "~> 0.3.5"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp spectre_dep do
    case System.get_env("SPECTRE_PATH") do
      nil -> {:spectre, "~> 0.4.0"}
      path -> {:spectre, path: Path.expand(path, __DIR__), override: true}
    end
  end
end
