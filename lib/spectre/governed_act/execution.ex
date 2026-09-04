defmodule Spectre.GovernedAct.Execution do
  @moduledoc """
  Classifies how an admitted governed Act reaches completion.

  Intrinsic ledger classes complete atomically with their Act and event suffix.
  Application classes may also complete in-ledger only through the exact
  reserved executor identity and a non-empty Row limited to write/spend. Every
  other valid Act is executor-mediated. This module classifies durable intent;
  host route lookup remains outside the kernel in `Spectre.Execution.Boundary`.
  """

  alias Spectre.{Act, Candidate, Row}
  alias Spectre.GovernedAct.Class

  @kernel_executor_ref "spectre:kernel:ledger"
  @kernel_contract_ref "spectre:kernel:ledger:v1"
  @application_ledger_dimensions [:write, :spend]

  @type mode :: :ledger_internal | :executor_mediated

  @doc "Stable executor identity reserved for consequences completed inside the ledger."
  @spec kernel_executor_ref() :: String.t()
  def kernel_executor_ref, do: @kernel_executor_ref

  @doc "Stable executor contract reserved for consequences completed inside the ledger."
  @spec kernel_contract_ref() :: String.t()
  def kernel_contract_ref, do: @kernel_contract_ref

  @doc "Returns whether the record is an exact ledger-internal execution declaration."
  @spec ledger_internal?(Candidate.t() | Act.t()) :: boolean()
  def ledger_internal?(%Candidate{} = record), do: ledger_internal_record?(record)
  def ledger_internal?(%Act{} = record), do: ledger_internal_record?(record)
  def ledger_internal?(_record), do: false

  @doc "Returns the execution mode while rejecting malformed use of the reserved route."
  @spec mode(Candidate.t() | Act.t()) :: {:ok, mode()} | {:error, term()}
  def mode(%Candidate{} = record), do: mode_for(record)
  def mode(%Act{} = record), do: mode_for(record)
  def mode(_record), do: {:error, :invalid_governance_execution_boundary}

  @doc "Returns whether the record must cross an application executor boundary."
  @spec executor_mediated?(Candidate.t() | Act.t()) :: boolean()
  def executor_mediated?(record), do: mode(record) == {:ok, :executor_mediated}

  @doc false
  @spec metered_ledger_internal?(term()) :: boolean()
  def metered_ledger_internal?(%Act{row: %{spend: true}} = act) do
    ledger_internal?(act) and Act.reservations?(act)
  end

  def metered_ledger_internal?(_record), do: false

  @doc "Validates only the execution classification, without resolving a host route."
  @spec validate(Candidate.t() | Act.t()) :: :ok | {:error, term()}
  def validate(%record_module{} = record) when record_module in [Candidate, Act] do
    case mode(record) do
      {:ok, _mode} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def validate(_record), do: {:error, :invalid_governance_execution_boundary}

  defp mode_for(record) do
    cond do
      Class.ledger_internal?(record.class) and ledger_internal_record?(record) ->
        {:ok, :ledger_internal}

      Class.ledger_internal?(record.class) ->
        {:error, {:governance_act_not_ledger_internal, record.class}}

      ledger_internal_record?(record) ->
        {:ok, :ledger_internal}

      reserved_kernel_route?(record) ->
        {:error, :invalid_ledger_internal_application_act}

      true ->
        {:ok, :executor_mediated}
    end
  end

  defp ledger_internal_record?(record) do
    exact_kernel_route?(record) and record.observation_window_ms == 0 and
      if Class.ledger_internal?(record.class) do
        no_reservations?(record)
      else
        application_ledger_row?(record)
      end
  end

  defp exact_kernel_route?(record) do
    record.executor_ref == @kernel_executor_ref and
      record.executor_contract_ref == @kernel_contract_ref
  end

  defp reserved_kernel_route?(record) do
    record.executor_ref == @kernel_executor_ref or
      record.executor_contract_ref == @kernel_contract_ref
  end

  defp application_ledger_row?(record) do
    dimensions = Row.dimensions(record.row)

    dimensions != [] and Enum.all?(dimensions, &(&1 in @application_ledger_dimensions))
  end

  defp no_reservations?(%Candidate{meter_requests: requests}), do: map_size(requests) == 0
  defp no_reservations?(%Act{reservations: reservations}), do: map_size(reservations) == 0
end
