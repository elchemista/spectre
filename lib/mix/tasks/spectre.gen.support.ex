defmodule Mix.Tasks.Spectre.Gen.Support do
  @moduledoc false

  @switches [dry_run: :boolean, force: :boolean]

  @type template :: {String.t(), String.t()}

  @doc false
  @spec generate!([String.t()], String.t(), [template()]) :: :ok | no_return()
  def generate!(argv, usage, templates) do
    Mix.Task.run("app.config")

    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [], do: Mix.raise("invalid options\n\n#{usage}")

    module = module_name!(args, usage)
    assigns = assigns(module)
    entries = entries!(templates, assigns)
    force? = Keyword.get(opts, :force, false)
    dry_run? = Keyword.get(opts, :dry_run, false)

    preflight!(entries, force?, usage)

    Enum.each(entries, fn entry ->
      Mix.shell().info("#{action(entry.destination, force?, dry_run?)} #{entry.destination}")

      unless dry_run? do
        Mix.Generator.copy_template(
          entry.template,
          entry.destination,
          assigns,
          force: force?,
          quiet: true,
          format_elixir: true
        )
      end
    end)

    :ok
  end

  @spec module_name!([String.t()], String.t()) :: String.t() | no_return()
  defp module_name!([module], _usage) do
    if Regex.match?(~r/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z/u, module) and
         module != "Elixir" and not String.starts_with?(module, "Elixir.") do
      module
    else
      Mix.raise(
        "invalid module name #{inspect(module)}; expected an alias such as MyApp.SupportAgent"
      )
    end
  end

  defp module_name!(_args, usage), do: Mix.raise(usage)

  @spec assigns(String.t()) :: keyword()
  defp assigns(module) do
    module_path = module |> String.split(".") |> Enum.map_join("/", &Macro.underscore/1)

    [
      module: module,
      module_path: module_path,
      package_id: module,
      spectre_requirement: "~> #{Spectre.version()}"
    ]
  end

  @spec entries!([template()], keyword()) :: [map()] | no_return()
  defp entries!(templates, assigns) do
    entries =
      Enum.map(templates, fn {template, destination} ->
        template = Application.app_dir(:spectre, Path.join("priv/templates", template))
        destination = EEx.eval_string(destination, assigns: assigns)

        unless File.regular?(template),
          do: Mix.raise("Spectre generator template is missing: #{template}")

        %{template: template, destination: destination}
      end)

    destinations = Enum.map(entries, & &1.destination)

    if Enum.uniq(destinations) == destinations,
      do: entries,
      else: Mix.raise("generator resolved duplicate destination paths")
  end

  @spec preflight!([map()], boolean(), String.t()) :: :ok | no_return()
  defp preflight!(entries, force?, usage) do
    Enum.each(entries, &require_safe_parent!/1)
    conflicts = Enum.filter(entries, &target_exists!(&1.destination))

    cond do
      conflicts == [] ->
        :ok

      not force? ->
        paths = Enum.map_join(conflicts, "\n", &("  * " <> &1.destination))

        Mix.raise(
          "refusing to overwrite existing files:\n#{paths}\n\n" <>
            "Pass --force to replace regular files.\n\n#{usage}"
        )

      true ->
        Enum.each(conflicts, &require_regular_target!/1)
    end
  end

  @spec require_safe_parent!(map()) :: :ok | no_return()
  defp require_safe_parent!(entry) do
    root = File.cwd!() |> Path.expand()
    segments = entry.destination |> Path.dirname() |> Path.split()
    inspect_parents!(segments, root)
  end

  @spec inspect_parents!([String.t()], String.t()) :: :ok | no_return()
  defp inspect_parents!([], _parent), do: :ok

  defp inspect_parents!([segment | rest], parent) do
    path = Path.join(parent, segment)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> Mix.raise("generator parent is a symlink: #{path}")
      {:ok, _stat} -> Mix.raise("generator parent is not a directory: #{path}")
      {:error, :enoent} -> :ok
      {:error, reason} -> Mix.raise("cannot inspect generator parent: #{inspect(reason)}")
    end

    inspect_parents!(rest, path)
  end

  @spec require_regular_target!(map()) :: :ok | no_return()
  defp require_regular_target!(entry) do
    case File.lstat(entry.destination) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: type}} ->
        Mix.raise("--force only replaces regular files; #{entry.destination} is #{type}")

      {:error, reason} ->
        Mix.raise("cannot inspect #{entry.destination}: #{inspect(reason)}")
    end
  end

  @spec target_exists!(String.t()) :: boolean() | no_return()
  defp target_exists!(path) do
    case File.lstat(path) do
      {:ok, _stat} -> true
      {:error, :enoent} -> false
      {:error, reason} -> Mix.raise("cannot inspect #{path}: #{inspect(reason)}")
    end
  end

  @spec action(String.t(), boolean(), boolean()) :: String.t()
  defp action(destination, force?, dry_run?) do
    case {dry_run?, force?, target_exists!(destination)} do
      {true, true, true} -> "would overwrite"
      {true, _, _} -> "would create"
      {false, true, true} -> "overwrite"
      {false, _, _} -> "create"
    end
  end
end
