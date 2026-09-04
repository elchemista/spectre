defmodule Spectre.Attempt.Binding do
  @moduledoc """
  Pure identity binding between an Act and its single durable Attempt.

  Temporal rules belong to the transition which starts or observes the
  Attempt. This module centralizes only the immutable identity fields shared
  by replay, execution adapters and recovery.
  """

  alias Spectre.{Act, Attempt}

  @field_matrix [
    {:act_ref, :ref, :act_ref},
    {:executor_ref, :executor_ref, :executor_ref},
    {:material_digest, :material_digest, :material_digest}
  ]

  @type mismatch :: {atom(), term(), term()}

  @doc "Returns the first identity mismatch, or `nil` when the Attempt belongs to the Act."
  @spec mismatch(Attempt.t(), Act.t()) :: mismatch() | nil
  def mismatch(%Attempt{} = attempt, %Act{} = act) do
    Enum.find_value(@field_matrix, fn {name, act_field, attempt_field} ->
      expected = Map.fetch!(act, act_field)
      actual = Map.fetch!(attempt, attempt_field)

      if expected == actual, do: nil, else: {name, expected, actual}
    end)
  end

  @doc "Returns the exact binding embedded in Evidence emitted for an Attempt."
  @spec evidence_bindings(Act.t(), Attempt.t()) :: map()
  def evidence_bindings(%Act{} = act, %Attempt{} = attempt),
    do: %{"act_ref" => act.ref, "attempt_ref" => attempt.ref}
end
