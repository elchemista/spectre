defmodule Spectre.Duty.Authority do
  @moduledoc false

  alias Spectre.{Act, Duty, Mandate, Principal}
  alias Spectre.Duty.Derive
  alias Spectre.Mandate.Ancestry

  @doc "Validates the exact, independent authority route used by a discretionary disposition."
  @spec validate(
          Duty.t(),
          Act.t(),
          Act.t() | nil,
          %{optional(String.t()) => Principal.t()},
          %{optional(String.t()) => Mandate.t()}
        ) :: :ok | {:error, term()}
  def validate(
        %Duty{} = duty,
        %Act{} = disposition_act,
        cause_act,
        principals,
        mandates
      )
      when (is_nil(cause_act) or is_struct(cause_act, Act)) and is_map(principals) and
             is_map(mandates) do
    with :ok <- route_named(duty),
         :ok <- exact_route(duty, disposition_act, principals, mandates) do
      independent_route(duty, disposition_act, cause_act, mandates)
    end
  end

  def validate(_duty, _disposition_act, _cause_act, _principals, _mandates),
    do: {:error, :invalid_duty_disposition_authority_input}

  defp route_named(%Duty{disposition_authority_refs: []} = duty),
    do: {:error, {:duty_disposition_authority_not_named, duty.ref}}

  defp route_named(%Duty{}), do: :ok

  defp exact_route(duty, act, principals, mandates) do
    matched? =
      Enum.any?(duty.disposition_authority_refs, fn ref ->
        (match?(%Principal{ref: ^ref}, Map.get(principals, ref)) and act.proposer_ref == ref and
           act.authenticated_principal_ref == ref) or
          (match?(%Mandate{ref: ^ref}, Map.get(mandates, ref)) and act.mandate_ref == ref)
      end)

    if matched?,
      do: :ok,
      else: {:error, {:duty_disposition_authority_mismatch, duty.ref, act.ref}}
  end

  defp independent_route(duty, disposition_act, cause_act, mandates) do
    with {:ok, causal_mandate_refs} <- causal_mandates(duty, cause_act),
         :ok <- causal_conflicts_frozen(duty, cause_act),
         :ok <- independent_act_roles(duty, disposition_act, causal_mandate_refs),
         {:ok, route} <- mandate_route(duty, disposition_act.mandate_ref, mandates) do
      independent_mandate_route(duty, route, causal_mandate_refs)
    end
  end

  defp causal_mandates(%Duty{act_ref: nil, mandate_ref: nil}, nil), do: {:ok, MapSet.new()}

  defp causal_mandates(%Duty{act_ref: nil, mandate_ref: mandate_ref}, nil)
       when is_binary(mandate_ref),
       do: {:ok, MapSet.new([mandate_ref])}

  defp causal_mandates(%Duty{} = duty, nil),
    do: {:error, {:duty_cause_act_not_found, duty.ref}}

  defp causal_mandates(%Duty{} = duty, %Act{} = cause_act) do
    cond do
      is_binary(duty.act_ref) and duty.act_ref != cause_act.ref ->
        {:error, {:duty_cause_act_mismatch, duty.ref, cause_act.ref}}

      is_binary(duty.mandate_ref) and duty.mandate_ref != cause_act.mandate_ref ->
        {:error, {:duty_cause_mandate_mismatch, duty.ref, cause_act.mandate_ref}}

      true ->
        {:ok, MapSet.new([cause_act.mandate_ref])}
    end
  end

  defp causal_conflicts_frozen(%Duty{mandate_ref: nil}, nil), do: :ok

  defp causal_conflicts_frozen(%Duty{} = duty, nil) do
    if duty.mandate_ref in duty.conflict_refs,
      do: :ok,
      else: {:error, {:duty_causal_conflict_not_frozen, duty.ref, duty.mandate_ref}}
  end

  defp causal_conflicts_frozen(%Duty{} = duty, %Act{} = cause_act) do
    expected = Derive.conflict_refs(duty.accountable, [], cause_act)

    case Enum.find(expected, &(&1 not in duty.conflict_refs)) do
      nil -> :ok
      ref -> {:error, {:duty_causal_conflict_not_frozen, duty.ref, ref}}
    end
  end

  defp independent_act_roles(duty, disposition_act, causal_mandate_refs) do
    conflicts = principal_conflicts(duty, causal_mandate_refs)

    disposition_roles = [
      disposition_act.proposer_ref,
      disposition_act.authenticated_principal_ref,
      disposition_act.authorizer_ref,
      disposition_act.accountable_ref
    ]

    case Enum.find(disposition_roles, &MapSet.member?(conflicts, &1)) do
      nil -> :ok
      ref -> {:error, {:duty_disposition_not_independent, duty.ref, ref}}
    end
  end

  defp mandate_route(_duty, nil, _mandates), do: {:ok, []}

  defp mandate_route(duty, mandate_ref, mandates) do
    with {:ok, mandate} <- fetch_route_mandate(duty, mandates, mandate_ref),
         {:ok, route} <- Ancestry.lineage(mandates, mandate) do
      {:ok, route}
    else
      {:error, {:mandate_ancestry_cycle, ref}} ->
        {:error, {:duty_disposition_mandate_ancestry_cycle, duty.ref, ref}}

      {:error, {:mandate_ancestor_missing, ref}} ->
        {:error, {:duty_disposition_mandate_not_found, duty.ref, ref}}

      {:error, {:invalid_mandate_ancestor, ref}} ->
        {:error, {:invalid_duty_disposition_mandate, duty.ref, ref}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_route_mandate(duty, mandates, mandate_ref) do
    case Map.fetch(mandates, mandate_ref) do
      {:ok, %Mandate{ref: ^mandate_ref} = mandate} -> {:ok, mandate}
      :error -> {:error, {:duty_disposition_mandate_not_found, duty.ref, mandate_ref}}
      {:ok, _invalid} -> {:error, {:invalid_duty_disposition_mandate, duty.ref, mandate_ref}}
    end
  end

  defp independent_mandate_route(duty, route, causal_mandate_refs) do
    principal_conflicts = principal_conflicts(duty, causal_mandate_refs)

    Enum.reduce_while(route, :ok, fn mandate, :ok ->
      cond do
        MapSet.member?(causal_mandate_refs, mandate.ref) ->
          {:halt,
           {:error, {:duty_disposition_mandate_descends_from_cause, duty.ref, mandate.ref}}}

        ref = conflicting_mandate_role(mandate, principal_conflicts) ->
          {:halt,
           {:error, {:duty_disposition_mandate_route_not_independent, duty.ref, mandate.ref, ref}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp principal_conflicts(duty, causal_mandate_refs) do
    duty.conflict_refs
    |> MapSet.new()
    |> MapSet.difference(causal_mandate_refs)
  end

  defp conflicting_mandate_role(mandate, conflicts) do
    [mandate.grantor_ref, mandate.holder_ref, mandate.accountable_ref]
    |> Enum.find(&MapSet.member?(conflicts, &1))
  end
end
