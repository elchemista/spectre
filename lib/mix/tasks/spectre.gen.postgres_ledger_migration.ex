defmodule Mix.Tasks.Spectre.Gen.PostgresLedgerMigration do
  @shortdoc "Generates the host migration for the Spectre PostgreSQL ledger"

  @moduledoc """
  Generates an Ecto migration owned by the host application.

      mix spectre.gen.postgres_ledger_migration

  The default destination is `priv/repo/migrations`. It can be changed without
  coupling Spectre to Ecto configuration:

      mix spectre.gen.postgres_ledger_migration \
        --migrations-path priv/audit_repo/migrations \
        --schema public \
        --table-prefix spectre_ledger

  Spectre does not add Ecto or a PostgreSQL driver dependency and never runs the
  migration itself.
  """

  use Mix.Task

  alias Spectre.Ledger.Store.Postgres

  @switches [
    migrations_path: :string,
    schema: :string,
    table_prefix: :string
  ]
  @postgres_options [:schema, :table_prefix]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("loadpaths")

    with {opts, [], []} <- OptionParser.parse(argv, strict: @switches),
         {:ok, sql} <- Postgres.migration_sql(Keyword.take(opts, @postgres_options)),
         {:ok, path} <- migration_path(opts),
         :ok <- ensure_absent(path),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- write_new(path, migration_source(sql, migration_module())) do
      Mix.shell().info([:green, "* creating ", :reset, Path.relative_to_cwd(path)])
    else
      {_opts, positional, invalid} ->
        Mix.raise(
          "unexpected arguments: " <>
            Enum.map_join(positional ++ invalid, ", ", &inspect/1)
        )

      {:error, reason} ->
        Mix.raise("cannot generate Spectre ledger migration: #{inspect(reason)}")
    end
  end

  defp migration_path(opts) do
    directory = Keyword.get(opts, :migrations_path, "priv/repo/migrations")

    if is_binary(directory) and directory != "" do
      timestamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d%H%M%S")
      {:ok, Path.expand(Path.join(directory, "#{timestamp}_create_spectre_ledger.exs"))}
    else
      {:error, :invalid_migrations_path}
    end
  end

  defp migration_module do
    app = Mix.Project.config() |> Keyword.fetch!(:app) |> Atom.to_string()
    root = app |> String.split("_") |> Enum.map_join(&String.capitalize/1)
    Module.concat([root, "Repo", "Migrations", "CreateSpectreLedger"])
  end

  defp migration_source(sql, module) do
    up = Enum.map_join(sql.up, "\n", &execute_block/1)
    down = Enum.map_join(sql.down, "\n", &execute_block/1)

    """
    defmodule #{inspect(module)} do
      use Ecto.Migration

      def up do
    #{indent(up, 4)}
      end

      def down do
    #{indent(down, 4)}
      end
    end
    """
  end

  defp execute_block(statement) do
    [
      "execute(\"\"\"\n",
      indent(String.trim(statement), 2),
      "\n\"\"\")"
    ]
    |> IO.iodata_to_binary()
  end

  defp indent(value, spaces) do
    prefix = String.duplicate(" ", spaces)
    value |> String.split("\n") |> Enum.map_join("\n", &(prefix <> &1))
  end

  defp ensure_absent(path) do
    directory = Path.dirname(path)

    case File.ls(directory) do
      {:ok, entries} ->
        case entries
             |> Enum.filter(&String.ends_with?(&1, "_create_spectre_ledger.exs"))
             |> Enum.sort()
             |> List.first() do
          nil -> :ok
          existing -> {:error, {:migration_already_exists, Path.join(directory, existing)}}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:migration_directory_unreadable, directory, reason}}
    end
  end

  defp write_new(path, source) do
    case File.write(path, source, [:exclusive]) do
      :ok -> :ok
      {:error, :eexist} -> {:error, {:migration_already_exists, path}}
      {:error, reason} -> {:error, {:migration_write_failed, path, reason}}
    end
  end
end
