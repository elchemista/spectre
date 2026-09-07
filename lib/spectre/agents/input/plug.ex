defmodule Spectre.Input.Plug do
  @moduledoc """
  Application-owned, local transformations of portable input.

  `init/1` optionally prepares reusable state once per pipeline. `call/2`
  receives only the current value and that state, not an authenticated context,
  a ledger writer or an executor. Return `{:cont, value}` to continue,
  `{:halt, value}` to stop normalization, or `{:error, reason}` to reject it.
  A halt is not a governed Decision and never authorizes an effect.

  Implementations should be local and side-effect-free. Remote transcription,
  inference or another governed effect belongs in an executor behind an Act,
  not in an input callback. As elsewhere on a shared BEAM, this contract is
  not a sandbox against application code with ambient credentials.
  """

  @callback init(keyword()) :: {:ok, term()} | {:error, term()}
  @callback call(term(), term()) :: {:cont, term()} | {:halt, term()} | {:error, term()}
  @optional_callbacks init: 1
end
