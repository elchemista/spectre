defmodule Spectre.GovernedAct.Class do
  @moduledoc """
  Closed metadata for the runtime's intrinsic governed classes.

  This table does not declare a class for a Domain and grants no authority;
  that remains the active `Spectre.Surface` and its Mandates. It only keeps the
  fixed runtime semantics of reserved classes in one place so classification,
  execution routing and replay cannot disagree about them.
  """

  alias Spectre.Row

  # {Row dimensions, execution boundary, has Admission event suffix?, validator id}
  @classes %{
    "scope.open" =>
      {[:write, :govern], :ledger_internal, true,
       "spectre:consequence-validator:scope-opening:v1"},
    "principal.register" =>
      {[:govern], :ledger_internal, true,
       "spectre:consequence-validator:principal-registration:v1"},
    "mandate.delegate" =>
      {[:delegate, :govern], :ledger_internal, true,
       "spectre:consequence-validator:mandate-delegation:v1"},
    "mandate.devolve" =>
      {[:delegate, :govern], :ledger_internal, true,
       "spectre:consequence-validator:mandate-devolution:v1"},
    "mandate.restrict" =>
      {[:govern], :ledger_internal, true, "spectre:consequence-validator:mandate-restriction:v1"},
    "mandate.revoke" =>
      {[:govern], :ledger_internal, true, "spectre:consequence-validator:mandate-revocation:v1"},
    "duty.dispose" =>
      {[:govern], :ledger_internal, true, "spectre:consequence-validator:duty-disposition:v1"},
    "surface.revise" =>
      {[:govern], :ledger_internal, true, "spectre:consequence-validator:surface-revision:v1"},
    "host_profile.revise" =>
      {[:govern], :ledger_internal, true,
       "spectre:consequence-validator:host-profile-revision:v1"},
    "definition.revise" =>
      {[:govern], :ledger_internal, true, "spectre:consequence-validator:definition-revision:v1"},
    "data.declassify" =>
      {[:write, :govern], :ledger_internal, true,
       "spectre:consequence-validator:evidence-declassification:v1"},
    "data.erase" =>
      {[:attempt, :write, :govern], :executor_mediated, true,
       "spectre:consequence-validator:erasure-request:v1"},
    "presentation.show" =>
      {[:attempt, :disclose, :present], :executor_mediated, false,
       "spectre:consequence-validator:presentation-show:v1"}
  }

  @retained_revocation_purpose_ref "spectre:purpose:retained-mandate-revocation:v1"

  @validator_ids @classes
                 |> Map.values()
                 |> Map.new(fn {_dimensions, _execution, _batch_effect?, validator} ->
                   {validator, true}
                 end)

  @type execution :: :ledger_internal | :executor_mediated

  @doc "Returns whether the class has fixed runtime semantics."
  @spec intrinsic?(term()) :: boolean()
  def intrinsic?(class), do: Map.has_key?(@classes, class)

  @doc "Returns the fixed Row dimensions, or `:application` for an ordinary class."
  @spec dimensions(term()) :: {:ok, [Spectre.Row.dimension()]} | :application
  def dimensions(class) do
    case Map.fetch(@classes, class) do
      {:ok, {dimensions, _execution, _batch_effect?, _validator}} -> {:ok, dimensions}
      :error -> :application
    end
  end

  @doc "Returns whether a Row exactly matches an intrinsic class declaration."
  @spec exact_row?(term(), term()) :: boolean()
  def exact_row?(class, %Row{} = row) do
    case dimensions(class) do
      {:ok, expected} -> Row.dimensions(row) == expected
      :application -> false
    end
  end

  def exact_row?(_class, _row), do: false

  @doc "Returns whether an intrinsic class completes inside the ledger kernel."
  @spec ledger_internal?(term()) :: boolean()
  def ledger_internal?(class) do
    match?({:ok, {_dimensions, :ledger_internal, _batch_effect?, _validator}}, fetch(class))
  end

  @doc "Returns whether Admission must append an intrinsic event suffix for the class."
  @spec batch_effect?(term()) :: boolean()
  def batch_effect?(class) do
    match?({:ok, {_dimensions, _execution, true, _validator}}, fetch(class))
  end

  @doc "Returns the stable pure-validator identifier for an intrinsic class."
  @spec validator(term()) :: {:ok, String.t()} | :application
  def validator(class) do
    case Map.fetch(@classes, class) do
      {:ok, {_dimensions, _execution, _batch_effect?, validator}} -> {:ok, validator}
      :error -> :application
    end
  end

  @doc false
  @spec validator_id?(term()) :: boolean()
  def validator_id?(id), do: Map.has_key?(@validator_ids, id)

  @doc "Returns the fixed purpose of a retained-controller Mandate revocation."
  @spec retained_revocation_purpose_ref() :: String.t()
  def retained_revocation_purpose_ref, do: @retained_revocation_purpose_ref

  defp fetch(class), do: Map.fetch(@classes, class)
end
