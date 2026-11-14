defmodule Spectre.GAM.Kernel.Authority.DutyTargets do
  @moduledoc false

  alias Spectre.GAM.{Duty, Mandate}
  alias Spectre.GAM.GovernedAct.State
  alias Spectre.GAM.Kernel.Authority.Attenuation

  @doc false
  @spec causal_refs(State.t(), Duty.t()) :: {:ok, MapSet.t(binary())} | {:error, atom()}
  def causal_refs(%State{} = state, %Duty{} = duty),
    do: causal_refs(state, duty, predecessors(state))

  @doc false
  @spec predecessors(State.t()) :: map()
  def predecessors(%State{} = state),
    do: Enum.group_by(state.mandate_successors, &elem(&1, 1), &elem(&1, 0))

  @doc false
  @spec causal_refs(State.t(), Duty.t(), map()) :: {:ok, MapSet.t(binary())} | {:error, atom()}
  def causal_refs(%State{} = state, %Duty{mandate_ref: ref}, predecessors)
      when is_binary(ref) and is_map(predecessors),
      do: walk(state.mandates, predecessors, [ref], MapSet.new())

  def causal_refs(_state, _duty, _predecessors),
    do: {:error, :duty_causal_mandate_missing}

  @spec walk(map(), map(), [binary()], MapSet.t(binary())) ::
          {:ok, MapSet.t(binary())} | {:error, atom()}
  defp walk(_mandates, _predecessors, [], visited), do: {:ok, visited}

  defp walk(mandates, predecessors, [ref | rest], visited) do
    if MapSet.member?(visited, ref) do
      walk(mandates, predecessors, rest, visited)
    else
      with %Mandate{ref: ^ref} = mandate <- Map.get(mandates, ref),
           {:ok, parent} <- parent(mandates, mandate),
           {:ok, predecessor} <- predecessor(mandates, predecessors, mandate) do
        # Every edge is checked before deduplication. Valid delegation strictly
        # lowers depth; valid predecessor traversal strictly lowers revision,
        # so a cycle cannot pass those non-amplification checks.
        next = List.wrap(parent) ++ List.wrap(predecessor) ++ rest
        walk(mandates, predecessors, next, MapSet.put(visited, ref))
      else
        _ -> {:error, :invalid_duty_causal_mandate_lineage}
      end
    end
  end

  @spec parent(map(), Mandate.t()) :: {:ok, binary() | nil} | {:error, atom()}
  defp parent(_mandates, %Mandate{parent_ref: nil}), do: {:ok, nil}

  defp parent(mandates, %Mandate{parent_ref: ref} = child) do
    with %Mandate{ref: ^ref} = parent <- Map.get(mandates, ref),
         :ok <- Attenuation.delegation_within?(parent, child, child.not_before) do
      {:ok, ref}
    else
      _ -> {:error, :invalid_duty_causal_delegation}
    end
  end

  @spec predecessor(map(), map(), Mandate.t()) :: {:ok, binary() | nil} | {:error, atom()}
  defp predecessor(mandates, predecessors, successor) do
    case Map.get(predecessors, successor.ref, []) do
      [] -> {:ok, nil}
      [ref] -> validate_predecessor(mandates, ref, successor)
      _ -> {:error, :ambiguous_duty_causal_predecessor}
    end
  end

  @spec validate_predecessor(map(), binary(), Mandate.t()) ::
          {:ok, binary()} | {:error, atom()}
  defp validate_predecessor(mandates, ref, successor) do
    with %Mandate{ref: ^ref} = previous <- Map.get(mandates, ref),
         :ok <- Attenuation.restriction_within?(previous, successor, successor.not_before) do
      {:ok, ref}
    else
      _ -> {:error, :invalid_duty_causal_restriction}
    end
  end
end
