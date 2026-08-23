ExUnit.start()

exclude = []

exclude =
  if System.get_env("SPECTRE_REAL_EMBEDDING_TESTS") in ["1", "true"],
    do: exclude,
    else: [{:real_ex_fastembed, true} | exclude]

exclude =
  if System.get_env("SPECTRE_PERF_TESTS") in ["1", "true"],
    do: exclude,
    else: [{:perf, true} | exclude]

ExUnit.configure(exclude: exclude)
