defmodule Spectre.Presentation.Approval.Assumptions do
  @moduledoc false

  alias Spectre.{Evidence, Presentation}

  @type index :: %{optional({term(), Evidence.stance()}) => [Evidence.t()]}

  @doc false
  @spec index([term()]) :: index()
  def index(evidence) when is_list(evidence) do
    evidence
    |> Enum.reduce(%{}, fn
      %Evidence{} = item, acc ->
        Map.update(acc, {item.proposition, item.stance}, [item], &[item | &1])

      _other, acc ->
        acc
    end)
    |> Map.new(fn {key, items} -> {key, Enum.sort_by(items, & &1.ref)} end)
  end

  @doc false
  @spec recognize(Evidence.t(), Presentation.t(), index(), integer()) ::
          {:ok, [String.t()]} | {:error, term()}
  def recognize(%Evidence{assumptions: []}, %Presentation{}, _index, _time), do: {:ok, []}

  def recognize(%Evidence{} = approval, %Presentation{} = presentation, index, time)
      when is_map(index) and is_integer(time) do
    context = context(approval, presentation, index, time)

    approval.assumptions
    |> Enum.reduce_while({:ok, []}, fn assumption, {:ok, refs} ->
      case assumption_basis(
             assumption,
             context,
             MapSet.new([approval.ref]),
             approval.observed_at
           ) do
        {:ok, assumption_refs} ->
          {:cont, {:ok, [assumption_refs | refs]}}

        {:error, _reason} ->
          {:halt, {:error, {:unrecognized_presentation_approval_assumption, assumption}}}
      end
    end)
    |> normalize_result()
  end

  @doc false
  @spec contradiction_basis(
          Evidence.t(),
          Evidence.t(),
          Presentation.t(),
          index(),
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def contradiction_basis(
        %Evidence{} = item,
        %Evidence{} = approval,
        %Presentation{} = presentation,
        index,
        time
      )
      when is_map(index) and is_integer(time) do
    context = context(approval, presentation, index, time)

    with true <- item.stance == :contradicts,
         true <- valid_identity?(item, context),
         true <- current?(item, time, time),
         {:ok, basis_refs} <-
           qualified_basis(item, context, MapSet.new([approval.ref, item.ref]), time) do
      {:ok, basis_refs}
    else
      false -> {:error, :presentation_assumption_evidence_not_current}
      {:error, _reason} = error -> error
    end
  end

  defp context(approval, presentation, index, time) do
    %{
      approval: approval,
      presentation: presentation,
      index: index,
      time: time
    }
  end

  defp assumption_basis(assumption, context, visited, observed_by) do
    supporting =
      evidence_bases(assumption, :supports, context, visited, observed_by)

    contradicting =
      evidence_bases(assumption, :contradicts, context, visited, context.time)

    if supporting == [] or contradicting != [],
      do: {:error, :assumption_not_supported},
      else: {:ok, normalize_refs(supporting)}
  end

  defp evidence_bases(assumption, stance, context, visited, observed_by) do
    context.index
    |> Map.get({assumption, stance}, [])
    |> Enum.reduce([], fn item, bases ->
      if eligible?(item, context, visited, observed_by) do
        case qualified_basis(
               item,
               context,
               MapSet.put(visited, item.ref),
               observed_by
             ) do
          {:ok, refs} -> [refs | bases]
          {:error, _reason} -> bases
        end
      else
        bases
      end
    end)
  end

  defp eligible?(item, context, visited, observed_by) do
    item.ref != context.approval.ref and
      not MapSet.member?(visited, item.ref) and
      valid_identity?(item, context) and
      current?(item, context.time, observed_by)
  end

  defp qualified_basis(item, context, visited, observed_by) do
    item.assumptions
    |> Enum.reduce_while({:ok, [[item.ref]]}, fn nested, {:ok, refs} ->
      case assumption_basis(nested, context, visited, observed_by) do
        {:ok, nested_refs} -> {:cont, {:ok, [nested_refs | refs]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> normalize_result()
  end

  defp valid_identity?(item, context) do
    approval = context.approval
    presentation = context.presentation

    item.provenance == :observed and not item.provisional and item.parent_refs == [] and
      item.source_ref in presentation.approval_source_refs and
      item.issuer_ref == approval.issuer_ref and
      Map.get(item.bindings, "authenticated_principal_ref") == approval.issuer_ref
  end

  defp current?(item, time, observed_by) do
    item.observed_at <= observed_by and Evidence.current_at?(item, time)
  end

  defp normalize_result({:ok, refs}), do: {:ok, normalize_refs(refs)}
  defp normalize_result({:error, _reason} = error), do: error

  defp normalize_refs(refs), do: refs |> List.flatten() |> Enum.uniq() |> Enum.sort()
end
