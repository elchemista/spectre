defmodule Spectre.Governance.Authority do
  @moduledoc false

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value

  @grant_fields [
    :operations,
    :actions,
    :effects,
    :state_reads,
    :state_writes,
    :event_classes,
    :prompt_phases,
    :prompt_budget_classes,
    :model_purposes,
    :model_profiles,
    :external_data_refs,
    :secret_refs,
    :open_capabilities,
    :consents
  ]
  @risk_order %{low: 0, medium: 1, high: 2, critical: 3}

  @spec no_expansion(Envelope.t(), Envelope.t()) :: :ok | {:error, term()}
  def no_expansion(%Envelope{} = parent, %Envelope{} = candidate) do
    with :ok <- grant_subset(parent, candidate) do
      limit_subset(parent.limits, candidate.limits)
    end
  end

  defp grant_subset(parent, candidate) do
    Enum.reduce_while(@grant_fields, :ok, &grant_field(&1, &2, parent, candidate))
  end

  defp limit_subset(parent, candidate) do
    Enum.reduce_while(parent, :ok, &limit_field(&1, &2, candidate))
  end

  defp grant_field(field, :ok, parent, candidate) do
    parent_values = parent |> Map.fetch!(field) |> encoded_set()
    expansion = Enum.find(Map.fetch!(candidate, field), &outside_grant?(&1, parent_values))

    case expansion do
      nil -> {:cont, :ok}
      value -> {:halt, {:error, {:candidate_authority_expansion, field, value}}}
    end
  end

  defp outside_grant?(value, parent_values),
    do: not MapSet.member?(parent_values, Value.encode!(value))

  defp limit_field({field, parent_value}, :ok, candidate) do
    case Map.fetch(candidate, field) do
      :error ->
        {:halt, {:error, {:candidate_authority_limit_removed, field, parent_value}}}

      {:ok, candidate_value} ->
        compare_limit(field, candidate_value, parent_value)
    end
  end

  defp compare_limit(field, candidate_value, parent_value) do
    if limit_within?(field, candidate_value, parent_value),
      do: {:cont, :ok},
      else: {:halt, {:error, {:candidate_authority_limit_expansion, field, candidate_value}}}
  end

  defp limit_within?(_field, value, parent) when is_number(value) and is_number(parent),
    do: value <= parent

  defp limit_within?(:max_risk, value, parent) do
    case {Map.fetch(@risk_order, value), Map.fetch(@risk_order, parent)} do
      {{:ok, candidate_rank}, {:ok, parent_rank}} -> candidate_rank <= parent_rank
      _other -> value == parent
    end
  end

  defp limit_within?(_field, value, parent), do: value == parent

  defp encoded_set(values), do: values |> Enum.map(&Value.encode!/1) |> MapSet.new()
end
