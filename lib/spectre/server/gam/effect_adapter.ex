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

  @doc """
  Runs one admitted operation with its frozen arguments and runtime context.

  The context includes the installation, effect configuration and schema hash.
  It can also carry the Agent, identity, command ID, Skill, Activity, input
  and current flow. Return a portable success receipt or a classified error.
  Use `:definitive_no_effect` when you know no effect occurred and
  `:ambiguous` when the outcome requires reconciliation.
  """
  @callback execute_effect(atom() | binary(), map(), map()) :: result()

  @doc """
  Optionally computes the registered operation's schema hash at startup.

  The second argument contains the effect's `:config` and `:installation`.
  Return a nonempty binary hash or a registration error.
  """
  @callback effect_schema(atom() | binary(), map()) :: {:ok, binary()} | {:error, term()}
  @optional_callbacks effect_schema: 2
end
