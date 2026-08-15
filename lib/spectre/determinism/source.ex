defmodule Spectre.Determinism.Source do
  @moduledoc """
  Host port for decision-relevant clock and randomness samples.

  The default implementation delegates to the Erlang runtime. Replay and
  audit integrations may provide a source through `:determinism_source`; the
  source is resolved at the boundary and is never persisted inside a Run.
  """

  @type time_unit :: System.time_unit()
  @type monotonic_time_unit :: time_unit() | :native

  @callback system_time(time_unit(), keyword()) :: integer()
  @callback monotonic_time(monotonic_time_unit(), keyword()) :: integer()
  @callback random_bytes(non_neg_integer(), keyword()) :: binary()
end
