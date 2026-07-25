ExUnit.start()

unless System.get_env("SPECTRE_REAL_EMBEDDING_TESTS") in ["1", "true"] do
  ExUnit.configure(exclude: [real_ex_fastembed: true])
end
