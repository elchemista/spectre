# From integration/stack_tools: ERL_FLAGS='+S 4:4' mix run bench/profile_stack.exs
# Profiles the real nine-package/Skill integration suite in an isolated BEAM VM.
for path <- Path.wildcard(Path.join(to_string(:code.lib_dir()), "tools-*/ebin")),
  do: :code.add_patha(String.to_charlist(path))
ExUnit.start(autorun: false)
Logger.configure(level: :warning)
output = System.get_env("PROFILE_OUTPUT") || "/tmp/spectre-stack-profile"
File.mkdir_p!(output)
Code.require_file("../test/outreach_test.exs", __DIR__)
{:ok, _} = :eprof.start()
:eprof.log(String.to_charlist(Path.join(output, "eprof.txt")))
:profiling = :eprof.start_profiling(Process.list())
caller = self()
observer = spawn_link(fn ->
  sample = fn ->
    Process.list() |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:memory, :reductions, :message_queue_len, :initial_call, :dictionary]) do
        nil -> []
        info ->
          initial = Keyword.get(info[:dictionary], :"$initial_call", info[:initial_call])
          [%{pid: inspect(pid), role: inspect(initial), memory: info[:memory],
             reductions: info[:reductions], mailbox: info[:message_queue_len]}]
      end
    end)
  end
  loop = fn again, samples ->
    receive do
      :finish -> send(caller, {:samples, Enum.reverse(samples)})
    after 50 -> again.(again, [sample.() | samples])
    end
  end
  loop.(loop, [])
end)
results = ExUnit.run()
Process.sleep(1_000)
send(observer, :finish)
samples = receive do {:samples, data} -> data after 5_000 -> raise "observer timeout" end
:eprof.stop_profiling()
:eprof.analyze(:total, sort: :time)
:eprof.analyze(:procs, sort: :time)
:eprof.stop()
File.write!(Path.join(output, "processes.json"), Spectre.JSON.encode!(%{results: results, samples: samples}))
IO.puts("Nine-package profile: #{output}; #{inspect(results)}")
if results.failures > 0, do: System.halt(1)
