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
  alias Spectre.GovernedAct.State
  alias Spectre.Kernel.Authority.Status
  alias Spectre.Mandate
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
          required(:blockers) => [blocker()],
          required(:meters) => map()
        }

  @type revocation_control :: %{
          required(:mandate_ref) => String.t(),
          required(:accountable_ref) => String.t(),
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
  def from_projection(%State{} = projection, %Scope{} = scope, observed_at)
      when is_integer(observed_at) do
    principal_ref = scope.context.authenticated_principal_ref

    scope_ref = Scope.ref(scope)

    with true <- projection.domain_ref == Scope.domain_ref(scope),
         %{ref: surface_ref, revision: surface_revision} <- State.surface(projection),
         %{ref: profile_ref, mode: profile_mode} <- State.host_profile(projection),
         authority_view = Projection.authority_view(projection),
         {:ok, held_mandates} <-
           held_mandates(projection, authority_view, scope_ref, principal_ref, observed_at),
         {:ok, controls} <-
           retained_controls(projection, authority_view, principal_ref, observed_at) do
      {:ok,
       %__MODULE__{
         domain_ref: projection.domain_ref,
         scope_ref: scope_ref,
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

  defp held_mandates(projection, authority_view, scope_ref, principal_ref, observed_at) do
    projection.mandates
    |> Map.values()
    |> Enum.filter(&(&1.holder_ref == principal_ref and scope_ref in &1.scope_refs))
    |> Enum.sort_by(& &1.ref)
    |> Enum.reduce_while({:ok, []}, fn mandate, {:ok, entries} ->
      case held_mandate(projection, authority_view, mandate, observed_at) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp held_mandate(projection, authority_view, %Mandate{} = mandate, observed_at) do
    with {:ok, blockers} <- authority_blockers(mandate, authority_view, observed_at),
         {:ok, meters} <- Projection.meter_accounts(projection, mandate.ref) do
      {:ok,
       %{
         mandate: mandate,
         blockers: blockers,
         meters: meters
       }}
    end
  end

  defp authority_blockers(mandate, authority_view, observed_at) do
    case Status.blockers(mandate, authority_view, observed_at) do
      {:ok, blockers} -> {:ok, blockers}
      {:error, reason} -> {:error, {:invalid_authority_status, mandate.ref, reason}}
    end
  end

  defp retained_controls(projection, authority_view, principal_ref, observed_at) do
    projection.mandates
    |> Map.values()
    |> Enum.filter(fn mandate ->
      mandate.revocation["mode"] == :retained_controller and
        principal_ref in mandate.revocation["controller_refs"]
    end)
    |> Enum.sort_by(& &1.ref)
    |> Enum.reduce_while({:ok, []}, fn mandate, {:ok, controls} ->
      case Status.direct_blockers(mandate, authority_view, observed_at) do
        {:ok, blockers} ->
          control = %{
            mandate_ref: mandate.ref,
            accountable_ref: mandate.accountable_ref,
            blockers: blockers
          }

          {:cont, {:ok, [control | controls]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_retained_revocation_state, mandate.ref, reason}}}
      end
    end)
    |> reverse_ok()
  end

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok({:error, _reason} = error), do: error
end
