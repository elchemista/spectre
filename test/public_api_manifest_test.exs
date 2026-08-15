defmodule SpectrePublicApiManifestTest do
  use ExUnit.Case, async: true

  @manifest_path Path.expand("../docs/PUBLIC_API.md", __DIR__)
  @callable_line ~r/^  - (functions|macros|callbacks): (.+)$/u
  @callable ~r/`([^`\/]+)\/(\d+)`/u
  @module_line ~r/^- `([^`]+)`$/u

  test "the normative public API manifest matches the compiled BEAM surface" do
    manifest = File.read!(@manifest_path)

    assert manifest =~ "# Spectre public API — #{Spectre.version()}"
    assert Mix.Project.config()[:version] == Spectre.version()

    {module_names, callables} = parse_manifest(manifest)

    assert module_names != []
    assert callables != []
    assert Enum.uniq(module_names) == module_names
    assert Enum.uniq(callables) == callables

    modules = Map.new(module_names, &{&1, load_manifest_module!(&1)})

    Enum.each(callables, fn {module_name, kind, name, arity} ->
      module = Map.fetch!(modules, module_name)

      assert {existing_atom!(name), arity} in compiled_callables(module, kind),
             "#{module_name}.#{name}/#{arity} is declared as #{kind} but is absent from the compiled contract"
    end)
  end

  test "the documented inference modules agree with the normative manifest" do
    manifest_modules =
      @manifest_path |> File.read!() |> parse_manifest() |> elem(0) |> MapSet.new()

    documented_modules =
      Mix.Project.config()
      |> get_in([:docs, :groups_for_modules])
      |> Keyword.fetch!(:"Inference and boundary evidence")
      |> Enum.map(&inspect/1)
      |> MapSet.new()

    assert MapSet.subset?(documented_modules, manifest_modules)

    refute MapSet.member?(documented_modules, inspect(Spectre.Inference.IncrementalSanitizer))
    refute MapSet.member?(documented_modules, inspect(Spectre.Inference.Failure))
  end

  test "internal receipt transport modules stay out of the public surface" do
    assert {:docs_v1, _, _, _, :hidden, _, _} =
             Code.fetch_docs(Spectre.Invocation.WorkerReceipt)

    assert {:docs_v1, _, _, _, :hidden, _, _} =
             Code.fetch_docs(Spectre.Receipt.OutboxEntry)
  end

  defp parse_manifest(manifest) do
    manifest
    |> String.split("\n")
    |> Enum.reduce({[], [], nil}, &parse_line/2)
    |> then(fn {modules, callables, _current} ->
      {Enum.reverse(modules), Enum.reverse(callables)}
    end)
  end

  defp parse_line(line, {modules, callables, current}) do
    case Regex.run(@module_line, line) do
      [_, module_name] ->
        {[module_name | modules], callables, module_name}

      nil ->
        parse_callable_line(line, modules, callables, current)
    end
  end

  defp parse_callable_line(line, modules, callables, current) do
    case Regex.run(@callable_line, line) do
      [_, kind, entries] when is_binary(current) ->
        parsed = parse_callables!(current, callable_kind(kind), entries)
        {modules, Enum.reverse(parsed, callables), current}

      nil ->
        {modules, callables, current}

      _without_module ->
        raise "public API callable row appears before a module: #{inspect(line)}"
    end
  end

  defp parse_callables!(module_name, kind, entries) do
    parsed =
      Enum.map(Regex.scan(@callable, entries), fn [encoded, name, arity] ->
        {{module_name, kind, name, String.to_integer(arity)}, encoded}
      end)

    residue =
      Enum.reduce(parsed, entries, fn {_callable, encoded}, value ->
        String.replace(value, encoded, "", global: false)
      end)
      |> String.replace(",", "")
      |> String.trim()

    if parsed == [] or residue != "" do
      raise "invalid public API callable row for #{module_name}: #{inspect(entries)}"
    end

    Enum.map(parsed, &elem(&1, 0))
  end

  defp callable_kind("functions"), do: :function
  defp callable_kind("macros"), do: :macro
  defp callable_kind("callbacks"), do: :callback

  defp load_manifest_module!(module_name) do
    module = existing_atom!("Elixir." <> module_name)

    unless Code.ensure_loaded?(module) do
      raise "public API module is not loadable: #{module_name}"
    end

    module
  end

  defp existing_atom!(value) do
    case existing_atom(value) do
      {:ok, atom} -> atom
      :error -> raise "public API identifier does not exist in the compiled BEAM: #{value}"
    end
  end

  defp existing_atom(value) do
    {:ok, String.to_existing_atom(value)}
  rescue
    ArgumentError -> :error
  end

  defp compiled_callables(module, :function), do: module.__info__(:functions)
  defp compiled_callables(module, :macro), do: module.__info__(:macros)

  defp compiled_callables(module, :callback) do
    if function_exported?(module, :behaviour_info, 1) do
      module.behaviour_info(:callbacks)
    else
      []
    end
  end
end
