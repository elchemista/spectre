defmodule Spectre.Mix.Scaffold do
  @moduledoc false

  @doc false
  def module_name!([name], _usage) do
    if Regex.match?(~r/^[A-Z][A-Za-z0-9]*(?:\.[A-Z][A-Za-z0-9]*)*$/, name) and
         not String.starts_with?(name, "Elixir."),
       do: name,
       else: Mix.raise("expected a module name such as MyApp.Hello")
  end

  def module_name!(_names, usage), do: Mix.raise(usage)

  @doc false
  def write(files, dry_run?) do
    # Check every target before any write, including dangling symlinks.
    for {path, _content} <- files do
      case File.lstat(path) do
        {:error, :enoent} -> :ok
        {:ok, _} -> Mix.raise("refusing to overwrite #{path}")
        {:error, reason} -> Mix.raise("cannot inspect #{path}: #{:file.format_error(reason)}")
      end
    end

    for {path, content} <- files do
      if dry_run? do
        Mix.shell().info("would create #{path}")
      else
        write_file(path, format(path, content))
      end
    end
  end

  defp format(path, source) do
    if Path.extname(path) in [".ex", ".exs"],
      do: IO.iodata_to_binary(Code.format_string!(source)) <> "\n",
      else: source
  end

  defp write_file(path, content) do
    File.mkdir_p!(Path.dirname(path))

    # The exclusive open also protects files created after preflight.
    case File.open(path, [:write, :exclusive], &IO.binwrite(&1, content)) do
      {:ok, :ok} -> Mix.shell().info("created #{path}")
      {:error, reason} -> Mix.raise("cannot create #{path}: #{:file.format_error(reason)}")
      {:ok, {:error, reason}} -> Mix.raise("cannot write #{path}: #{inspect(reason)}")
    end
  end
end
