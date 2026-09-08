# Check the generated site as well as the Markdown sources: ExDoc can leave
# a relative source-file link untouched even though that file is not deployed.
root = System.argv() |> List.first("doc") |> Path.expand()
pages = Map.new(Path.wildcard(Path.join(root, "*.html")), &{&1, File.read!(&1)})
if map_size(pages) == 0, do: raise("No generated HTML documentation in #{root}")

ids =
  Map.new(pages, fn {path, html} ->
    {path, MapSet.new(Regex.scan(~r/\bid="([^"]+)"/, html), fn [_, id] -> id end)}
  end)

errors =
  for {source, html} <- pages,
      [_, href] <- Regex.scan(~r/\bhref="([^"]+)"/, html),
      uri = URI.parse(href),
      is_nil(uri.scheme) and is_nil(uri.host),
      path =
        if(uri.path in [nil, ""],
          do: source,
          else: Path.expand(URI.decode(uri.path), Path.dirname(source))
        ),
      not File.regular?(path) or
        (is_binary(uri.fragment) and uri.fragment != "" and String.ends_with?(path, ".html") and
           not MapSet.member?(Map.get(ids, path, MapSet.new()), URI.decode(uri.fragment))) do
    "#{Path.relative_to(source, root)} -> #{href}"
  end

if errors != [] do
  raise "Broken local documentation links:\n" <> Enum.join(Enum.sort(errors), "\n")
end

IO.puts("Verified local links and fragments in #{map_size(pages)} HTML pages")
