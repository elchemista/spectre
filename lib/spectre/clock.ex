defmodule Spectre.Clock do
  @moduledoc """
  Trusted time source used at the governed boundary.

  Time is sampled by the Domain sequencer and then persisted as decision input;
  pure kernel functions never read the system clock themselves.
  """

  @callback now() :: integer()
end
