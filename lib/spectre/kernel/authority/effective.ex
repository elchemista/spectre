defmodule Spectre.Kernel.Authority.Effective do
  @moduledoc """
  Immutable authority resolved for one admission decision.

  This is a capability-free, non-durable view. It carries the exact fields the
  Decision algebra needs and retains the source Mandate identity/revision. The
  ordinary form copies a Mandate; the retained-controller form narrows it to
  the single revocation operation authorized by that Mandate.

  Keeping this distinct from `Spectre.Mandate` prevents an ephemeral narrowing
  from masquerading as a content-addressed durable Mandate with a stale ref.
  """

  alias Spectre.{Candidate, Mandate}

  @kernel_executor_ref "spectre:kernel:ledger"
  @kernel_contract_ref "spectre:kernel:ledger:v1"
  @retained_revocation_class "mandate.revoke"
  @retained_revocation_purpose_ref "spectre:purpose:retained-mandate-revocation:v1"

  @enforce_keys [
    :source,
    :ref,
    :revision,
    :grantor_ref,
    :holder_ref,
    :accountable_ref,
    :executor_refs,
    :executor_contract_refs,
    :scope_refs,
    :subject_refs,
    :target_refs,
    :classes,
    :ceiling,
    :purpose_ref,
    :purpose_params,
    :conditions,
    :not_before,
    :expires_at,
    :meters
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source: Mandate.t(),
          ref: String.t(),
          revision: pos_integer(),
          grantor_ref: String.t(),
          holder_ref: String.t(),
          accountable_ref: String.t(),
          executor_refs: [String.t()],
          executor_contract_refs: [String.t()],
          scope_refs: [String.t()],
          subject_refs: [String.t()],
          target_refs: [String.t()],
          classes: [String.t()],
          ceiling: Spectre.Row.t(),
          purpose_ref: String.t(),
          purpose_params: map(),
          conditions: [Spectre.Condition.t()],
          not_before: integer(),
          expires_at: integer(),
          meters: %{optional(String.t()) => non_neg_integer()}
        }

  @doc "Projects an ordinary durable Mandate into the Decision boundary."
  @spec from_mandate(Mandate.t()) :: t()
  def from_mandate(%Mandate{} = mandate) do
    values = mandate |> Map.take(@enforce_keys) |> Map.put(:source, mandate)
    struct!(__MODULE__, values)
  end

  @doc "Builds the one-operation authority retained by a revocation controller."
  @spec retained_revocation(Mandate.t(), Candidate.t(), String.t()) :: t()
  def retained_revocation(%Mandate{} = mandate, %Candidate{} = candidate, controller_ref) do
    %__MODULE__{
      source: mandate,
      ref: mandate.ref,
      revision: mandate.revision,
      grantor_ref: controller_ref,
      holder_ref: controller_ref,
      accountable_ref: mandate.accountable_ref,
      executor_refs: [@kernel_executor_ref],
      executor_contract_refs: [@kernel_contract_ref],
      scope_refs: [candidate.scope_ref],
      subject_refs: [],
      target_refs: [mandate.ref],
      classes: [@retained_revocation_class],
      ceiling: candidate.row,
      purpose_ref: @retained_revocation_purpose_ref,
      purpose_params: %{},
      conditions: [],
      not_before: mandate.not_before,
      expires_at: mandate.expires_at,
      meters: %{}
    }
  end
end
