defmodule Spectre.Domain.Query do
  @moduledoc """
  Narrow reads performed where the verified projection lives.

  Only results cross the Domain mailbox, never its full history. Scoped reads
  validate the same authentication/generation fence as commands; callers cannot
  supply executable selectors or callbacks to the trusted process.
  """

  alias Spectre.Authority.View, as: AuthorityView
  alias Spectre.Domain.{Context, Transaction}
  alias Spectre.Scope.View, as: ScopeView

  @doc false
  def head(state), do: Map.take(state.projection, [:domain_ref, :revision, :head_digest])

  @doc false
  def scoped(state, scope, query) do
    with {:ok, context, _opening} <- Context.validate_scope(state, scope.context) do
      read(state, %{scope | context: context}, query)
    end
  end

  defp read(state, scope, :view),
    do: ScopeView.from_projection(state.projection, Spectre.Scope.ref(scope))

  defp read(state, scope, :authority) do
    with {:ok, now} <- Transaction.trusted_recorded_at(state),
         do: AuthorityView.from_projection(state.projection, scope, now)
  end

  defp read(state, scope, {:records, key})
       when key in [:acts, :duties, :erasures, :declassifications] do
    ScopeView.records(state.projection, Spectre.Scope.ref(scope), key)
  end

  defp read(state, _scope, {:surface, revision}) do
    case Enum.filter(state.projection.catalog.surfaces, fn {_ref, surface} ->
           surface.revision == revision
         end) do
      [{_ref, surface}] -> {:ok, surface}
      [] -> {:error, {:historical_surface_not_found, revision}}
      _many -> {:error, {:ambiguous_surface_revision, revision}}
    end
  end

  defp read(_state, _scope, _query), do: {:error, :invalid_domain_query}
end
