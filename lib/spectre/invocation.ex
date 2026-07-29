defmodule Spectre.Invocation do
  @moduledoc """
  A concrete, revision-fenced request to execute one staged effect.

  Invocations describe work without embedding executable clients or callbacks.
  In 0.1.3 the host returns the descriptor to `Spectre.Runtime.resume/3`; the
  runtime then re-resolves the owning extension/provider and executes through
  the canonical durable effect boundary.
  """

  alias Spectre.Effect
  alias Spectre.Run
  alias Spectre.Run.Ref
  alias Spectre.Run.Value

  @enforce_keys [
    :id,
    :run_id,
    :run_revision,
    :ref,
    :kind,
    :operation,
    :subject_id,
    :idempotency_key
  ]
  defstruct [
    :id,
    :run_id,
    :run_revision,
    :ref,
    :kind,
    :operation,
    :subject_id,
    :idempotency_key,
    :owner,
    :scope,
    status: :pending,
    attempt: 1,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          run_id: String.t(),
          run_revision: non_neg_integer(),
          ref: Ref.t(),
          kind: :effect,
          operation: {atom(), atom() | String.t() | nil},
          subject_id: String.t(),
          idempotency_key: String.t(),
          owner: module() | nil,
          scope: Spectre.Definition.scope() | nil,
          status: :pending,
          attempt: pos_integer(),
          metadata: map()
        }

  @doc false
  @spec from_effect(Run.t(), Effect.t(), String.t()) :: t()
  def from_effect(%Run{} = run, %Effect{} = effect, id) when is_binary(id) do
    ref = Run.ref(run, :invocation, id, effect.id)
    from_effect(ref, effect)
  end

  @doc false
  @spec from_effect(Ref.t(), Effect.t()) :: t()
  def from_effect(%Ref{kind: :invocation} = ref, %Effect{} = effect) do
    invocation =
      %__MODULE__{
        id: ref.boundary_id,
        run_id: ref.run_id,
        run_revision: ref.revision,
        ref: ref,
        kind: :effect,
        operation: {effect.kind, effect.name},
        subject_id: ref.subject_id,
        idempotency_key: Effect.idempotency_key(effect),
        owner: effect.owner,
        scope: effect.scope,
        metadata: %{mode: effect.mode, status: effect.status}
      }

    case Value.validate(invocation, [:invocation]) do
      :ok -> invocation
      {:error, reason} -> raise ArgumentError, "non-portable Invocation: #{inspect(reason)}"
    end
  end
end
