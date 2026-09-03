defmodule Spectre.Mandate.Revocation do
  @moduledoc """
  Projection value for a recorded Mandate revocation.

  The ledger event remains a canonical string-keyed map. The governed fold
  converts it to this atom-keyed value exactly once, so authority semantics do
  not have to guess which representation they received.
  """

  @enforce_keys [:identity, :mandate_ref, :effective_at, :mode, :revision]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          identity: String.t(),
          mandate_ref: String.t(),
          effective_at: integer(),
          mode: Spectre.Mandate.revocation_mode(),
          revision: non_neg_integer() | nil
        }

  @doc false
  @spec from_event(String.t(), map(), Spectre.Mandate.revocation_mode(), non_neg_integer() | nil) ::
          {:ok, t()} | {:error, :invalid_mandate_revocation_event}
  def from_event(identity, data, mode, revision)
      when is_binary(identity) and identity != "" and is_map(data) and
             mode in [:cascade, :retained_controller] and
             (is_nil(revision) or (is_integer(revision) and revision >= 0)) do
    case data do
      %{"mandate_ref" => mandate_ref, "effective_at" => effective_at}
      when map_size(data) == 2 and is_binary(mandate_ref) and mandate_ref != "" and
             is_integer(effective_at) ->
        {:ok,
         %__MODULE__{
           identity: identity,
           mandate_ref: mandate_ref,
           effective_at: effective_at,
           mode: mode,
           revision: revision
         }}

      _invalid ->
        {:error, :invalid_mandate_revocation_event}
    end
  end

  def from_event(_identity, _data, _mode, _revision),
    do: {:error, :invalid_mandate_revocation_event}
end
