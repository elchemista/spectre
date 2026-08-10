defmodule Spectre.Execution.Runtime do
  @moduledoc """
  Admission boundary for a verified data-driven execution materialization.

  This module does not implement a second executor. It verifies the sealed
  materialization and starts its program through `Spectre.Operation.Runtime`,
  preserving the existing fencing, checkpoint, retry, control and recovery
  semantics.
  """

  alias Spectre.Execution.Handoff
  alias Spectre.Execution.Materialization
  alias Spectre.Operation.Runtime, as: OperationRuntime

  @doc "Starts a materialized Work in the pure operational transition engine."
  @spec start(Materialization.t(), keyword(), map()) ::
          {:ok, Spectre.Operation.Loop.t(), Spectre.Operation.Control.t(), [map()]}
          | {:error, term()}
  def start(materialization, opts \\ [], env \\ %{})

  def start(%Materialization{} = materialization, opts, env)
      when is_list(opts) and is_map(env) do
    with true <- Keyword.keyword?(opts),
         :ok <- Materialization.verify(materialization),
         {:ok, handoff} <- handoff(Keyword.get(opts, :handoff), materialization),
         {:ok, metadata} <- metadata(Keyword.get(opts, :metadata, %{}), materialization) do
      metadata =
        if handoff,
          do: Map.put(metadata, :execution_handoff_digest, handoff.digest),
          else: metadata

      opts =
        opts
        |> Keyword.delete(:handoff)
        |> Keyword.put(:plans, materialization.plans)
        |> Keyword.put(:materialization_digest, materialization.digest)
        |> Keyword.put(:definition_ref, materialization.definition_ref)
        |> Keyword.put(:metadata, metadata)

      OperationRuntime.start_program(materialization.program, materialization.input, opts, env)
    else
      false -> {:error, :invalid_execution_runtime_options}
      {:error, _reason} = error -> error
    end
  end

  def start(%Materialization{}, _opts, _env),
    do: {:error, :invalid_execution_runtime_options}

  def start(materialization, opts, env),
    do:
      {:error,
       {:invalid_execution_runtime_start, shape(materialization), shape(opts), shape(env)}}

  @spec metadata(term(), Materialization.t()) :: {:ok, map()} | {:error, term()}
  defp metadata(metadata, materialization) when is_map(metadata) and not is_struct(metadata) do
    lineage = %{
      execution_materialization_digest: materialization.digest,
      execution_projection_digest: materialization.projection.digest,
      execution_definition_ref: materialization.definition_ref,
      execution_program_digest: materialization.program.digest,
      execution_prompt_receipt_digests: Enum.map(materialization.prompt_receipts, & &1.digest),
      skill_mount_id: materialization.mount_id,
      skill_route_label: materialization.route_label,
      skill_continuation_id: materialization.continuation_id
    }

    {:ok, Map.merge(metadata, lineage)}
  end

  defp metadata(value, _materialization),
    do: {:error, {:invalid_execution_runtime_metadata, shape(value)}}

  @spec handoff(term(), Materialization.t()) :: {:ok, Handoff.t() | nil} | {:error, term()}
  defp handoff(nil, _materialization), do: {:ok, nil}

  defp handoff(%Handoff{} = handoff, materialization) do
    with {:ok, handoff} <- Handoff.new(handoff),
         :ok <- Handoff.validate_target(handoff, materialization) do
      {:ok, handoff}
    end
  end

  defp handoff(value, _materialization),
    do: {:error, {:invalid_execution_runtime_handoff, shape(value)}}

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
