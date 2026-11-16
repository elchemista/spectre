defmodule Spectre.Server.GAM.EffectAdapter do
  @moduledoc """
  Explicit execution contract for an already admitted, frozen effect.

  The runtime selects an adapter from immutable Stack registrations. Payloads
  cannot choose a module or function. An Act reference is correlation, not a
  promise that an external service implements idempotency. Adapters must report
  ambiguous outcomes honestly and must not retry an uncertain effect.
  """

  @type status :: :failed | :definitive_no_effect | :ambiguous
  @type result :: {:ok, term()} | {:error, status(), term()}

  @callback execute_effect(atom() | binary(), map(), map()) :: result()
  @callback effect_schema(atom() | binary(), map()) :: {:ok, binary()} | {:error, term()}
  @optional_callbacks effect_schema: 2
end
