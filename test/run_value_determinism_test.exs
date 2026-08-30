defmodule SpectreRunValueDeterminismTest do
  use ExUnit.Case, async: false

  alias Spectre.Run.Value

  @instance_fixture Path.expand(
                      "fixtures/compatibility/0.3.0/instance-v2.json",
                      __DIR__
                    )
  @state_fixture Path.expand("fixtures/compatibility/0.1.6/state-v5.json", __DIR__)

  @instance_digest "530073ac9229e8a393a34a8d86010a3d2e928da5e37960e1538c70090b188a9f"
  @state_digest "de63f859b1814a815a7e7a83baa20a1990cb73cbaab784b85d2b8afb85602b6c"

  @child_script ~S"""
  defmodule SpectreRunValueDeterminismChild do
    def atom_names(%{"$spectre" => "atom", "value" => value}) when is_binary(value),
      do: [value]

    def atom_names(%{"$spectre" => "atom_binary", "value" => value})
        when is_binary(value),
        do: [Base.decode64!(value)]

    def atom_names(%{"$spectre" => "struct", "module" => module, "fields" => fields})
        when is_binary(module),
        do: [module | atom_names(fields)]

    def atom_names(value) when is_map(value) do
      Enum.flat_map(value, fn {key, item} -> atom_names(key) ++ atom_names(item) end)
    end

    def atom_names(value) when is_list(value), do: Enum.flat_map(value, &atom_names/1)
    def atom_names(_value), do: []

    def loaded?(module_name) do
      :code.is_loaded(String.to_existing_atom(module_name)) != false
    rescue
      ArgumentError -> false
    end
  end

  [order, instance_path, state_path] = System.argv()

  spectre_module_names = [
    "Elixir.Spectre.Foundation.Conformance",
    "Elixir.Spectre.Run.Value",
    "Elixir.Spectre.Stack.Value",
    "Elixir.Spectre.State.Codec"
  ]

  Enum.each(spectre_module_names, fn module_name ->
    if SpectreRunValueDeterminismChild.loaded?(module_name),
      do: raise("Spectre module loaded before child atom-order setup: #{module_name}")
  end)

  instance_checkpoint = File.read!(instance_path)
  state_checkpoint = File.read!(state_path)

  fixture_atom_names =
    [instance_checkpoint, state_checkpoint]
    |> Enum.flat_map(fn checkpoint ->
      checkpoint
      |> Spectre.JSON.decode!()
      |> SpectreRunValueDeterminismChild.atom_names()
    end)

  map_atom_names = Enum.map(1..64, &"spectre_cross_beam_map_key_#{&1}")

  atom_names =
    (fixture_atom_names ++ map_atom_names)
    |> Enum.uniq()
    |> Enum.sort()
    |> then(fn names -> if order == "reverse", do: Enum.reverse(names), else: names end)

  # This is a finite, test-owned vocabulary inside a disposable child VM.
  Enum.each(atom_names, &String.to_atom/1)

  large_atom_map =
    Map.new(map_atom_names, fn name ->
      {String.to_existing_atom(name), %{"name" => name}}
    end)

  [foundation, _run_value, stack_value, _state_codec] =
    Enum.map(spectre_module_names, &String.to_atom/1)

  {:ok, instance_report} =
    apply(foundation, String.to_atom("verify_instance_checkpoint"), [
      instance_checkpoint,
      "instance-v2:fixture"
    ])

  {:ok, state_report} =
    apply(foundation, String.to_atom("verify_state"), [state_checkpoint])

  stack_digest = apply(stack_value, String.to_atom("digest"), [large_atom_map])
  digest_key = String.to_existing_atom("digest")

  result = [Map.fetch!(instance_report, digest_key), Map.fetch!(state_report, digest_key), stack_digest]
  payload = result |> :erlang.term_to_binary([:deterministic]) |> Base.encode64()
  IO.puts("SPECTRE_RUN_VALUE_DETERMINISM=" <> payload)
  """

  test "map encoding orders entries by deterministic encoded-key bytes" do
    value = %{
      7 => {:tuple, true},
      "binary" => [1, 2, 3],
      :zeta => %{nested: 1, other: 2},
      :alpha => :value
    }

    assert {:ok, %{"$spectre" => "map", "entries" => entries} = encoded} =
             Value.encode(value)

    assert entries ==
             Enum.sort_by(entries, fn [key, _item] ->
               :erlang.term_to_binary(key, [:deterministic])
             end)

    assert {:ok, ^value} = Value.decode(encoded)
  end

  test "current writers have stable digests across fresh BEAM atom load orders" do
    forward = run_in_fresh_beam!("forward")
    reverse = run_in_fresh_beam!("reverse")

    assert forward == reverse
    assert [@instance_digest, @state_digest, stack_digest] = forward
    assert byte_size(stack_digest) == 64
  end

  defp run_in_fresh_beam!(order) do
    executable = System.find_executable("elixir") || flunk("elixir executable not found")

    args =
      Enum.flat_map(test_ebin_paths(), &["-pa", &1]) ++
        [
          "--no-color",
          "-e",
          @child_script,
          "--",
          order,
          @instance_fixture,
          @state_fixture
        ]

    {output, status} =
      System.cmd(executable, args,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, "child BEAM failed for #{order} atom order:\n#{output}"

    case Regex.run(
           ~r/^SPECTRE_RUN_VALUE_DETERMINISM=([A-Za-z0-9+\/=]+)$/m,
           output,
           capture: :all_but_first
         ) do
      [payload] ->
        payload
        |> Base.decode64!()
        |> :erlang.binary_to_term([:safe])

      _other ->
        flunk("child BEAM returned no determinism result for #{order}:\n#{output}")
    end
  end

  defp test_ebin_paths do
    build_lib =
      Mix.Project.build_path()
      |> Path.expand()
      |> Path.join("lib")

    :code.get_path()
    |> Enum.map(&List.to_string/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.filter(fn path ->
      String.starts_with?(path, build_lib <> "/") and String.ends_with?(path, "/ebin")
    end)
  end
end
