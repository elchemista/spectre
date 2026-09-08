# Compare bytes with the release manifest, not a second list of old templates.
[directory] = System.argv()

expected =
  Mix.Project.config()[:package][:files]
  |> Enum.flat_map(fn path ->
    if File.dir?(path), do: Path.wildcard(Path.join(path, "**/*")), else: [path]
  end)
  |> Enum.filter(&File.regular?/1)
  |> Enum.sort()

actual =
  directory
  |> Path.join("**/*")
  |> Path.wildcard(match_dot: true)
  |> Enum.filter(&File.regular?/1)
  |> Enum.map(&Path.relative_to(&1, directory))
  |> Enum.reject(&(&1 == "hex_metadata.config"))
  |> Enum.sort()

if actual != expected do
  raise "Package differs from manifest: missing #{inspect(expected -- actual)}, " <>
          "unexpected #{inspect(actual -- expected)}"
end

for path <- expected do
  unless File.read!(path) === File.read!(Path.join(directory, path)) do
    raise "Packaged file differs from checkout: #{path}"
  end
end

IO.puts("Verified #{length(expected)} packaged files against the release manifest")
