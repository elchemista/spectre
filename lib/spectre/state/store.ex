defmodule Spectre.State.Store do
  @moduledoc """
  Durable state-adapter contract with optimistic concurrency.

  New adapters should implement `compare_and_swap/5`. Spectre passes the state
  containing `expected_revision + 1` together with the expected prior revision.
  Return `{:error, :stale_state}` (or `{:error, {:stale_state, actual}}`) when
  another turn committed first. If the store cannot determine whether a write
  committed, return `{:error, {:ambiguous, reason}}`; Spectre will not retry it
  blindly.
  """

  @callback load(Spectre.Input.t(), module(), keyword()) ::
              {:ok, Spectre.State.t() | map() | String.t()} | {:error, term()}

  @callback compare_and_swap(
              Spectre.State.t(),
              non_neg_integer(),
              Spectre.Input.t(),
              module(),
              keyword()
            ) :: :ok | {:ok, Spectre.State.t() | map() | String.t()} | {:error, term()}

  @optional_callbacks load: 3, compare_and_swap: 5
end
