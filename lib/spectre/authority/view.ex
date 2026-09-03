defmodule Spectre.Authority.View do
  @moduledoc """
  Capability-free authority inventory for one authenticated Scope.

  The view reports Mandates held by the authenticated Principal and the narrow
  revocation controls retained by that Principal.  It is derived from the
  current Domain projection and trusted Domain time; it cannot authorize a
  Candidate, mint a Grant or replace normal kernel admission.

  `blockers` describes only state shared by every possible Candidate under a
  Mandate (time, revocation, restriction and unresolved Meter debt). Candidate
  class, target, purpose, Evidence, consent and available quantity are still
  evaluated by the kernel for each proposal.
  """

  alias Spectre.Domain.Projection
  alias Spectre.Kernel.Authority
  alias Spectre.Mandate
  alias Spectre.Mandate.Ancestry
  alias Spectre.Scope

  @enforce_keys [
    :domain_ref,
    :scope_ref,
    :principal_ref,
    :revision,
    :observed_at,
    :surface_ref,
    :surface_revision,
    :host_profile_ref,
    :host_profile_mode,
    :held_mandates,
    :retained_revocation_controls
  ]
  defstruct @enforce_keys

  @type blocker ::
          :not_yet_valid
          | :expired
          | :revoked
          | :ancestor_revoked
          | :superseded
          | :ancestor_superseded
          | :meter_debt
          | :ancestor_meter_debt

  @type held_mandate :: %{
          required(:mandate) => Mandate.t(),
          required(:current?) => boolean(),
          required(:blockers) => [blocker()],
          required(:meters) => map()
        }

  @type revocation_control :: %{
          required(:mandate_ref) => String.t(),
          required(:accountable_ref) => String.t(),
          required(:current?) => boolean(),
          required(:blockers) => [:not_yet_valid | :expired | :already_revoked]
        }

  @type t :: %__MODULE__{
          domain_ref: String.t(),
          scope_ref: String.t(),
          principal_ref: String.t(),
          revision: non_neg_integer(),
          observed_at: integer(),
          surface_ref: String.t(),
          surface_revision: non_neg_integer(),
          host_profile_ref: String.t(),
          host_profile_mode: :mediated | :isolated | :development,
          held_mandates: [held_mandate()],
          retained_revocation_controls: [revocation_control()]
        }

  @doc "Builds an immutable authority inventory for a validated Scope handle."
  @spec from_projection(Projection.t(), Scope.t(), integer()) :: {:ok, t()} | {:error, term()}
  def from_projection(%Projection{} = projection, %Scope{} = scope, observed_at)
      when is_integer(observed_at) do
    principal_ref = scope.context.authenticated_principal_ref

    with true <- projection.domain_ref == scope.domain.ref,
         true <- scope.ref == scope.context.scope_ref,
         %{ref: surface_ref, revision: surface_revision} <- projection.surface,
         %{ref: profile_ref, mode: profile_mode} <- projection.host_profile,
         {:ok, held_mandates} <-
           held_mandates(projection, scope.ref, principal_ref, observed_at),
         {:ok, controls} <- retained_controls(projection, principal_ref, observed_at) do
      {:ok,
       %__MODULE__{
         domain_ref: projection.domain_ref,
         scope_ref: scope.ref,
         principal_ref: principal_ref,
         revision: projection.revision,
         observed_at: observed_at,
         surface_ref: surface_ref,
         surface_revision: surface_revision,
         host_profile_ref: profile_ref,
         host_profile_mode: profile_mode,
         held_mandates: held_mandates,
         retained_revocation_controls: controls
       }}
    else
      false -> {:error, :authority_view_scope_mismatch}
      nil -> {:error, :authority_view_foundation_missing}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_authority_view_foundation}
    end
  end

  def from_projection(_projection, _scope, _observed_at),
    do: {:error, :invalid_authority_view_input}

  defp held_mandates(projection, scope_ref, principal_ref, observed_at) do
    projection.mandates
    |> Map.values()
    |> Enum.filter(&(&1.holder_ref == principal_ref and scope_ref in &1.scope_refs))
    |> Enum.sort_by(& &1.ref)
    |> Enum.reduce_while({:ok, []}, fn mandate, {:ok, entries} ->
      case held_mandate(projection, mandate, observed_at) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp held_mandate(projection, %Mandate{} = mandate, observed_at) do
    authority_view = Projection.authority_view(projection)

    with {:ok, revocation_status} <-
           Ancestry.status(
             projection.mandates,
             projection.revocations,
             mandate,
             observed_at
           ),
         {:ok, restriction_blockers} <- restriction_blockers(mandate, authority_view),
         {:ok, debt_blockers} <- debt_blockers(mandate, authority_view),
         {:ok, meters} <- Projection.meter_accounts(projection, mandate.ref) do
      blockers =
        time_blockers(mandate, observed_at) ++
          revocation_blockers(revocation_status) ++ restriction_blockers ++ debt_blockers

      {:ok,
       %{
         mandate: mandate,
         current?: blockers == [],
         blockers: blockers,
         meters: meters
       }}
    end
  end

  defp time_blockers(%Mandate{} = mandate, observed_at) do
    []
    |> maybe_add(observed_at < mandate.not_before, :not_yet_valid)
    |> maybe_add(observed_at >= mandate.expires_at, :expired)
  end

  defp revocation_blockers(:current), do: []
  defp revocation_blockers({:revoked, :direct, _ref}), do: [:revoked]
  defp revocation_blockers({:revoked, :ancestor, _ref}), do: [:ancestor_revoked]

  defp restriction_blockers(mandate, authority_view) do
    case Authority.restriction_status(mandate, authority_view) do
      :ok -> {:ok, []}
      {:error, :mandate_superseded} -> {:ok, [:superseded]}
      {:error, :mandate_ancestor_superseded} -> {:ok, [:ancestor_superseded]}
      {:error, reason} -> {:error, {:invalid_authority_restriction_state, mandate.ref, reason}}
    end
  end

  defp debt_blockers(mandate, authority_view) do
    case Authority.meter_debt_status(mandate, authority_view) do
      :ok -> {:ok, []}
      {:error, :mandate_meter_debt} -> {:ok, [:meter_debt]}
      {:error, :mandate_ancestor_meter_debt} -> {:ok, [:ancestor_meter_debt]}
      {:error, reason} -> {:error, {:invalid_authority_meter_state, mandate.ref, reason}}
    end
  end

  defp retained_controls(projection, principal_ref, observed_at) do
    projection.mandates
    |> Map.values()
    |> Enum.filter(fn mandate ->
      mandate.revocation["mode"] == :retained_controller and
        principal_ref in mandate.revocation["controller_refs"]
    end)
    |> Enum.sort_by(& &1.ref)
    |> Enum.reduce_while({:ok, []}, fn mandate, {:ok, controls} ->
      case Ancestry.directly_revoked?(projection.revocations, mandate, observed_at) do
        {:ok, revoked?} ->
          blockers =
            []
            |> maybe_add(observed_at < mandate.not_before, :not_yet_valid)
            |> maybe_add(observed_at >= mandate.expires_at, :expired)
            |> maybe_add(revoked?, :already_revoked)

          control = %{
            mandate_ref: mandate.ref,
            accountable_ref: mandate.accountable_ref,
            current?: blockers == [],
            blockers: blockers
          }

          {:cont, {:ok, [control | controls]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_retained_revocation_state, mandate.ref, reason}}}
      end
    end)
    |> reverse_ok()
  end

  defp maybe_add(values, true, value), do: values ++ [value]
  defp maybe_add(values, false, _value), do: values

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, _reason} = error), do: error
end
