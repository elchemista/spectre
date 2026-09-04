defmodule Spectre.Domain.Sequencer.State do
  @moduledoc """
  Private process state for one Domain sequencer.

  Immutable host wiring and the latest disposable governed projection live in
  this container. Domain identity and Constitution are read from the verified
  projection instead of being copied here. Likewise only the Genesis verifier
  option survives bootstrap; the initial record bundle is not retained by the
  long-lived process. Queue and timer fields are operational only; none of them
  is ledger truth or authority.
  """

  alias Spectre.Domain.Configuration
  alias Spectre.GovernedAct.State, as: GovernedState

  @configuration_fields [
    :store,
    :clock,
    :id_source,
    :late_observer,
    :mind,
    :mind_ref,
    :ingress,
    :ingress_ref,
    :generation,
    :grant_secret,
    :checkout_receipt_secret,
    :grant_ttl_ms,
    :batch_size,
    :batch_wait_ms,
    :conflict_retries,
    :ambiguous_retries,
    :ledger_opts,
    :payload_store,
    :execution_boundary
  ]

  @enforce_keys [:projection, :genesis_verifier | @configuration_fields]

  defstruct @enforce_keys ++
              [
                pending: :queue.new(),
                pending_count: 0,
                flush: nil,
                reconciliation: nil,
                halted_reason: nil
              ]

  @type t :: %__MODULE__{}

  @doc false
  @spec new(Configuration.t(), GovernedState.t()) :: t()
  def new(%Configuration{} = config, %GovernedState{} = projection) do
    values =
      config
      |> Map.from_struct()
      |> Map.take(@configuration_fields)
      |> Map.put(:projection, projection)
      |> Map.put(:genesis_verifier, Configuration.genesis_verifier(config))

    struct!(__MODULE__, values)
  end

  @doc false
  @spec verification_opts(t()) :: keyword()
  def verification_opts(%__MODULE__{genesis_verifier: nil}), do: []

  def verification_opts(%__MODULE__{genesis_verifier: verifier}),
    do: [genesis_verifier: verifier]
end
