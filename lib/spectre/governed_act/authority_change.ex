defmodule Spectre.GovernedAct.AuthorityChange do
  @moduledoc """
  Pure interpretation of an authority-changing Act.

  Both commit construction and replay need to answer the same two questions:
  which Mandate changed, and whether a pending descendant is affected. Keeping
  those answers here prevents dispatch cancellation from acquiring a second,
  subtly different ancestry implementation.
  """

  alias Spectre.Act
  alias Spectre.Mandate
  alias Spectre.Mandate.{Ancestry, Revocation}

  @type resolution :: {String.t(), boolean()}

  @doc "Resolves the target and cascade semantics of an already-folded authority change."
  @spec resolve(map(), Act.t(), :mandate_revoked | :mandate_restricted) ::
          {:ok, String.t(), boolean()} | {:error, term()}
  def resolve(
        state,
        %Act{
          class: "mandate.revoke",
          consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref} = command}
        } = cause_act,
        :mandate_revoked
      )
      when map_size(cause_act.consequence) == 1 and map_size(command) == 1 do
    with {:ok, _mandate} <- fetch_mandate(state, mandate_ref),
         {:ok, %Revocation{} = revocation} <- Map.fetch(state.revocations, mandate_ref),
         true <- revocation.identity == cause_act.ref,
         true <- revocation.effective_at == cause_act.committed_at do
      {:ok, mandate_ref, revocation.mode == :cascade}
    else
      :error -> {:error, {:dispatch_cancellation_revocation_not_recorded, cause_act.ref}}
      false -> {:error, {:dispatch_cancellation_revocation_mismatch, cause_act.ref}}
      {:ok, _invalid} -> {:error, {:dispatch_cancellation_revocation_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  def resolve(
        state,
        %Act{
          class: "mandate.restrict",
          consequence: %{
            "mandate_restrict" => %{"predecessor_ref" => predecessor_ref} = command
          }
        } = cause_act,
        :mandate_restricted
      )
      when map_size(cause_act.consequence) == 1 and map_size(command) == 2 do
    with {:ok, successor_ref} <- Map.fetch(state.mandate_successors, predecessor_ref),
         {:ok, successor} <- fetch_mandate(state, successor_ref),
         true <- successor.source_ref == cause_act.ref do
      {:ok, predecessor_ref, true}
    else
      :error -> {:error, {:dispatch_cancellation_restriction_not_recorded, cause_act.ref}}
      false -> {:error, {:dispatch_cancellation_restriction_mismatch, cause_act.ref}}
      {:error, _reason} = error -> error
    end
  end

  def resolve(_state, %Act{} = cause_act, reason),
    do: {:error, {:invalid_dispatch_cancellation_cause, cause_act.ref, reason}}

  @doc "Checks whether a Mandate falls under the resolved authority change."
  @spec affects?(map(), String.t(), String.t(), boolean()) ::
          {:ok, boolean()} | {:error, term()}
  def affects?(state, mandate_ref, target_ref, cascade?) do
    Ancestry.affected_by?(state.mandates, mandate_ref, target_ref, cascade?)
  end

  @doc "Returns the cascade policy declared by a Mandate, defaulting safely to false."
  @spec cascades?(map(), String.t()) :: boolean()
  def cascades?(state, mandate_ref) do
    case Map.fetch(state.mandates, mandate_ref) do
      {:ok, %Mandate{revocation: %{"mode" => :cascade}}} -> true
      _missing_or_non_cascading -> false
    end
  end

  defp fetch_mandate(state, mandate_ref) do
    case Map.fetch(state.mandates, mandate_ref) do
      {:ok, %Mandate{} = mandate} -> {:ok, mandate}
      {:ok, _invalid} -> {:error, {:invalid_mandate, mandate_ref}}
      :error -> {:error, {:mandate_not_found, mandate_ref}}
    end
  end
end
