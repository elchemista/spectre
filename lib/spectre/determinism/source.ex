defmodule Spectre.Determinism.Source do
  @moduledoc """
  Host port for decision-relevant clock and randomness samples.

  The default implementation delegates to the Erlang runtime. Replay and
  audit integrations may provide a source through `:determinism_source`; the
  source is resolved at the boundary and is never persisted inside a Run.
  """

  @type time_unit :: System.time_unit()
  @type monotonic_time_unit :: time_unit() | :native

  @doc "Samples wall-clock time in the requested unit using the configured source options."
  @callback system_time(time_unit(), keyword()) :: integer()

  @doc "Samples monotonic time for elapsed-time comparisons in the requested unit."
  @callback monotonic_time(monotonic_time_unit(), keyword()) :: integer()

  @doc "Returns exactly the requested number of bytes from the configured randomness source."
  @callback random_bytes(non_neg_integer(), keyword()) :: binary()
end
