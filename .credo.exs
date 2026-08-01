%{
  configs: [
    %{
      name: "default",
      checks: %{
        extra: [
          # Canonical reducers and portable envelope validators enumerate a
          # closed state machine. Splitting their branches would hide the
          # invariants the functions validate, so retain every other Credo
          # check while scoping only these two structural metrics.
          {Credo.Check.Refactor.CyclomaticComplexity,
           files: %{
             excluded: [
               "lib/spectre/instance.ex",
               "lib/spectre/instance/canonical.ex",
               "lib/spectre/operation/**/*.ex",
               "test/effect_executor_contract_test.exs"
             ]
           }},
          {Credo.Check.Refactor.Nesting,
           files: %{
             excluded: [
               "lib/spectre/instance.ex",
               "lib/spectre/instance/canonical.ex",
               "lib/spectre/instance/canonical/**/*.ex",
               "lib/spectre/operation/**/*.ex"
             ]
           }}
        ]
      }
    }
  ]
}
