# Installation

```elixir
def deps do
  [
    {:spectre, github: "elchemista/spectre"},
    {:spectre_kinetic, github: "elchemista/spectre_kinetic"}
  ]
end
```

For local classifier embeddings, add the optional adapter in the host
application. Spectre detects it dynamically and does not pull the Git
dependency transitively:

```elixir
def deps do
  [
    {:ex_fastembed, github: "elchemista/ex_fastembed", branch: "master"}
  ]
end
```
