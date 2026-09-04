defmodule Spectre.GovernedAct.Emergency do
  @moduledoc """
  Pure invariants for the exceptional root Mandate named by Genesis.

  Emergency authority is still a Mandate and crosses normal Admission. This
  module only fixes the additional constraints that keep the exceptional path
  narrow: it cannot delegate, rewrite its own governing foundations, or live
  longer than the Constitution permits. Bootstrap recovery and offline audit
  share this validator so those rules cannot drift.
  """

  alias Spectre.{Constitution, Genesis, Mandate}

  @forbidden_classes MapSet.new(~w(
                         mandate.delegate
                         mandate.restrict
                         surface.revise
                         host_profile.revise
                         definition.revise
                       ))

  @doc "Validates the optional emergency Mandate selected by Genesis."
  @spec validate(Genesis.t(), %{optional(String.t()) => Mandate.t()}, map()) ::
          :ok | {:error, term()}
  def validate(
        %Genesis{emergency_mandate_ref: nil},
        mandates,
        rules
      )
      when is_map(mandates) and is_map(rules),
      do: :ok

  def validate(
        %Genesis{emergency_mandate_ref: ref},
        mandates,
        rules
      )
      when is_binary(ref) and ref != "" and is_map(mandates) and is_map(rules) do
    case Map.fetch(mandates, ref) do
      {:ok, %Mandate{ref: ^ref} = mandate} -> validate_mandate(mandate, rules)
      {:ok, _invalid} -> {:error, :invalid_genesis_emergency_mandate}
      :error -> {:error, :genesis_emergency_mandate_missing}
    end
  end

  def validate(_genesis, _mandates, _rules),
    do: {:error, :invalid_genesis_emergency_mandate}

  defp validate_mandate(mandate, rules) do
    with :ok <- cannot_delegate(mandate),
         :ok <- cannot_rewrite_itself(mandate),
         {:ok, maximum} <- Constitution.emergency_max_duration(rules) do
      if mandate.expires_at - mandate.not_before <= maximum,
        do: :ok,
        else: {:error, :emergency_mandate_duration_exceeded}
    end
  end

  defp cannot_delegate(%Mandate{delegation: %{"allowed" => false, "max_depth" => 0}}),
    do: :ok

  defp cannot_delegate(%Mandate{}), do: {:error, :emergency_mandate_may_not_delegate}

  defp cannot_rewrite_itself(%Mandate{classes: classes}) do
    if Enum.any?(classes, &MapSet.member?(@forbidden_classes, &1)),
      do: {:error, :emergency_mandate_may_not_rewrite_exception},
      else: :ok
  end
end
