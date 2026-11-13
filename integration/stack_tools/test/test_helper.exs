ExUnit.start()

unless Process.whereis(Spectre.GAM.Test.ClockOwner) do
  {:ok, _} =
    Agent.start(fn -> Spectre.GAM.V04Test.Runtime.reset(System.system_time(:millisecond)) end,
      name: Spectre.GAM.Test.ClockOwner
    )
end
