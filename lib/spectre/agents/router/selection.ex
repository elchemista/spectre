defmodule Spectre.Router.Selection do
  @moduledoc """
  A strategy's selection, not a GAM Decision. It carries no Mandate or Grant.
  `evidence/4` can describe the selection as derived Evidence; the caller must
  record it through the ordinary derivation API before proposing with it.
  """
  alias Spectre.Mind
  alias Spectre.Mind.Turn

  @enforce_keys [:router_ref, :rule, :candidate, :via, :score]
  defstruct [:router_ref, :rule, :candidate, :via, :score, :matched]

  @type t :: %__MODULE__{
          router_ref: String.t(),
          rule: String.t(),
          candidate: String.t(),
          via: String.t(),
          score: number(),
          matched: term()
        }

  @doc """
  Builds optional provenance without changing recognition or admission.

  The proposition identifies this router's selection for the exact Turn;
  the payload records the selected rule, template, method and score. Raw input
  and matcher diagnostics are not copied into the ledger. Parent Evidence,
  conservative labels and trusted bindings come from the ordinary Mind builder.
  """
  @spec evidence(t(), Turn.t(), integer(), map() | keyword()) ::
          {:ok, Spectre.Evidence.t()} | {:error, term()}
  def evidence(%__MODULE__{} = selection, %Turn{} = turn, observed_at, attrs \\ []) do
    with {:ok, attrs} <-
           Spectre.Portable.normalize_attrs(
             attrs,
             [:labels, :assumptions, :valid_from, :valid_until, :freshness_ms],
             :route_evidence
           ) do
      Mind.evidence(
        turn,
        observed_at,
        attrs
        |> Map.put(:provenance, :derived)
        |> Map.put(:proposition, %{
          "kind" => "spectre.router.selection",
          "router_ref" => selection.router_ref,
          "turn_ref" => turn.ref
        })
        |> Map.put(:payload, %{
          "rule" => selection.rule,
          "candidate" => selection.candidate,
          "via" => selection.via,
          "score" => selection.score
        })
      )
    end
  end
end
