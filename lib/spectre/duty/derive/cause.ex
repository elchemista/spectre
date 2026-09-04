defmodule Spectre.Duty.Derive.Cause do
  @moduledoc """
  Shared constructor for immutable Duty causes.

  Cause detection modules provide causal facts. This module applies the
  Constitution's containment, closing and disposition policy, then derives
  the conflict set that prevents interested actors from disposing their own
  debt. It creates no durable record; materialization remains a later ledger
  transition.
  """

  alias Spectre.{Act, Candidate, Constitution, Portable}

  @hard_containment_classes [:ambiguous_outcome, :contradicted_outcome, :disputed_evidence]

  @doc false
  @spec build(atom() | String.t(), term(), map(), map(), map()) :: map()
  def build(class, key, causal_refs, constitution, attrs)
      when is_map(causal_refs) and is_map(constitution) and is_map(attrs) do
    rule = Constitution.duty_rule(constitution, class)
    act = Map.get(attrs, :act)
    mandate_ref = inherited_attr(attrs, :mandate_ref, act)
    subject_refs = inherited_attr(attrs, :subject_refs, act, [])
    accountable_ref = inherited_attr(attrs, :accountable_ref, act)

    configured_containment =
      Map.get(attrs, :containment) || Constitution.rule_value(rule, :containment, %{})

    containment =
      if class in @hard_containment_classes do
        hard_containment(configured_containment, act)
      else
        canonical_string_keys(configured_containment)
      end

    configured_conflicts =
      [mandate_ref | listify(Constitution.rule_value(rule, :conflict_refs, []))]

    %{
      cause_key: key,
      cause_class: class,
      causal_refs: causal_refs,
      mandate_ref: mandate_ref,
      subject_refs: subject_refs,
      accountable_ref: accountable_ref,
      known_evidence_refs: Map.get(attrs, :known_evidence_refs, []),
      missing_evidence: Map.get(attrs, :missing_evidence, []),
      containment: containment,
      closing_conditions:
        Map.get(attrs, :closing_conditions) ||
          Constitution.rule_value(rule, :closing_conditions, []) || [],
      disposition_authority:
        Map.get(attrs, :disposition_authority) ||
          Constitution.rule_value(rule, :disposition_authority_refs),
      conflict_refs: conflict_refs(accountable_ref, configured_conflicts, act),
      required_at: Map.get(attrs, :required_at)
    }
  end

  @doc false
  @spec closing_conditions(map(), atom() | String.t(), list()) :: term()
  def closing_conditions(constitution, class, default) do
    constitution
    |> Constitution.duty_rule(class)
    |> Constitution.rule_value(:closing_conditions, default)
  end

  @doc false
  @spec conflict_refs(String.t() | nil, term(), Act.t() | nil) :: [String.t()]
  def conflict_refs(accountable_ref, configured_refs, act) do
    ([accountable_ref] ++ authority_refs(configured_refs) ++ causal_role_refs(act))
    |> normalize_refs()
  end

  @doc false
  @spec authority_refs(term()) :: [String.t()]
  def authority_refs(nil), do: []
  def authority_refs(value) when is_binary(value), do: [value]
  def authority_refs(value) when is_list(value), do: Enum.filter(value, &is_binary/1)
  def authority_refs(_value), do: []

  @doc false
  @spec normalize_refs([term()]) :: [String.t()]
  def normalize_refs(refs) do
    refs
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec stable_sort_key(term()) :: String.t()
  def stable_sort_key(value),
    do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp causal_role_refs(%Act{} = act) do
    [
      act.mandate_ref,
      act.proposer_ref,
      act.authenticated_principal_ref,
      act.executor_ref,
      act.authorizer_ref,
      act.accountable_ref
    ] ++ act.subject_refs ++ act.target_refs
  end

  defp causal_role_refs(nil), do: []

  defp inherited_attr(attrs, key, act, default \\ nil)

  defp inherited_attr(attrs, key, %Act{} = act, default) do
    if Map.has_key?(attrs, key), do: Map.fetch!(attrs, key), else: Map.get(act, key, default)
  end

  defp inherited_attr(attrs, key, nil, default), do: Map.get(attrs, key, default)

  defp hard_containment(configured, %Act{} = act) do
    consequence_digest =
      case Candidate.effect_digest(act) do
        {:ok, digest} -> digest
        {:error, _reason} -> nil
      end

    configured
    |> canonical_string_keys()
    |> ensure_plain_map()
    |> Map.merge(%{
      "consequence_digest" => consequence_digest,
      "meter_reservations" => act.reservations,
      "dispatch" => :blocked,
      "retry" => :forbidden
    })
  end

  defp hard_containment(configured, nil) do
    configured
    |> canonical_string_keys()
    |> ensure_plain_map()
    |> Map.merge(%{
      "consequence_digest" => nil,
      "meter_reservations" => %{},
      "dispatch" => :blocked,
      "retry" => :forbidden
    })
  end

  defp ensure_plain_map(value) when is_map(value) and not is_struct(value), do: value
  defp ensure_plain_map(_value), do: %{}

  # Constitution validation has already excluded equivalent atom/string keys,
  # so containment can be projected to its durable string-keyed form without
  # choosing silently between two meanings.
  defp canonical_string_keys(value) do
    {:ok, normalized} = Portable.stringify_atom_keys(value)
    normalized
  end

  defp listify(nil), do: []
  defp listify(value) when is_list(value), do: value
  defp listify(value), do: [value]
end
