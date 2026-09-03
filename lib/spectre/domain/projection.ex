defmodule Spectre.Domain.Projection do
  @moduledoc """
  Domain-facing driver and query API for disposable governed state.

  A projection is rebuilt from the canonical ledger and can always be thrown
  away. Structural snapshot verification belongs here; transition semantics
  live in `Spectre.GovernedAct.Fold`, while derived reads live in
  `Spectre.GovernedAct.View`. None of these modules is an authority store.
  """

  alias Spectre.GovernedAct.{Fold, State, View}
  alias Spectre.Kernel.Authority.Facts
  alias Spectre.Ledger
  alias Spectre.Ledger.Entry
  alias Spectre.SubmissionContext

  @type t :: State.t()
  @type reservation_status :: State.reservation_status()
  @type dispatch_cancellation :: State.dispatch_cancellation()
  @type reservation_binding :: State.reservation_binding()
  @type meter_recontainment :: State.meter_recontainment()
  @type duty_meter_resolution :: State.duty_meter_resolution()

  @doc "Creates empty disposable state for a Domain."
  @spec new(String.t(), map()) :: t()
  def new(domain_ref, constitution \\ %{}), do: Fold.new(domain_ref, constitution)

  @doc "Verifies a ledger snapshot and folds its canonical governed history."
  @spec replay(Ledger.snapshot(), map()) :: {:ok, t()} | {:error, term()}
  def replay(snapshot, constitution \\ %{})

  def replay(snapshot, constitution)
      when is_map(snapshot) and not is_struct(snapshot) and is_map(constitution) and
             not is_struct(constitution) do
    with {:ok, verified} <- Ledger.verify_snapshot(snapshot) do
      Fold.replay_verified(verified.domain_ref, verified.entries, constitution)
    end
  end

  def replay(_snapshot, _constitution), do: {:error, :invalid_domain_snapshot}

  @doc "Applies one verified entry while incrementally rebuilding a Domain."
  @spec apply_entry(t(), Entry.t()) :: {:ok, t()} | {:error, term()}
  defdelegate apply_entry(projection, entry), to: Fold

  @doc "Applies one decoded payload to provisional state before group commit."
  @spec apply_payload(t(), map(), non_neg_integer() | nil) :: {:ok, t()} | {:error, term()}
  def apply_payload(projection, payload, revision \\ nil),
    do: Fold.apply_payload(projection, payload, revision)

  @doc "Returns the immutable authority facts consumed by the pure kernel."
  @spec authority_view(t()) :: Facts.t()
  defdelegate authority_view(projection), to: View, as: :authority

  @doc "Returns physical Meter accounts for a logical Mandate revision."
  @spec meter_accounts(t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate meter_accounts(projection, mandate_ref), to: View

  @doc "Returns the logical Meter view without copying physical accounts."
  @spec meter_view(t()) :: map()
  defdelegate meter_view(projection), to: View, as: :meters

  @doc "Resolves an exact Evidence set from disposable state."
  @spec evidence_set(t(), [String.t()]) :: {:ok, [term()]} | {:error, term()}
  defdelegate evidence_set(projection, refs), to: View

  @doc "Checks an authenticated context against its durable Scope opening."
  @spec scope_context(t(), SubmissionContext.t()) ::
          {:ok, Spectre.Scope.Opening.t()} | {:error, term()}
  defdelegate scope_context(projection, context), to: View

  @doc "Looks up a Duty by stable cause key or durable reference."
  @spec duty(t(), {:cause_key, term()} | {:ref, String.t()}) ::
          {:ok, Spectre.Duty.t()} | :not_found | {:error, :invalid_duty_lookup}
  defdelegate duty(projection, lookup), to: View
end
