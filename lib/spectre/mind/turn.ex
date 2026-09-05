defmodule Spectre.Mind.Turn do
  @moduledoc """
  Ephemeral, capability-free input to one deliberation.

  A Turn contains a sanitized authenticated context and immutable Evidence, but
  no authority view, Grant, executor or secret. The context seal is removed
  before the Turn crosses into application deliberation. Evidence references
  and the conservative label union are derived from the records instead of
  being stored a second time.
  """

  alias Spectre.{Evidence, Label, Seal, SubmissionContext}
  alias Spectre.Evidence.Derivation

  @enforce_keys [
    :ref,
    :mind_ref,
    :context,
    :evidence,
    :opened_at
  ]
  defstruct @enforce_keys ++ [seal: nil]

  @type t :: %__MODULE__{
          ref: String.t(),
          mind_ref: String.t(),
          context: SubmissionContext.t(),
          evidence: [Evidence.t()],
          opened_at: integer(),
          seal: String.t() | nil
        }

  @seal_domain "spectre:mind-turn:v1\0"

  @doc "Builds a Turn from an authenticated context and the exact visible Evidence."
  @spec new(SubmissionContext.t(), String.t(), String.t(), [Evidence.t()], integer()) ::
          {:ok, t()} | {:error, term()}
  def new(%SubmissionContext{} = context, ref, mind_ref, evidence, opened_at)
      when is_binary(ref) and ref != "" and is_binary(mind_ref) and mind_ref != "" and
             is_list(evidence) and is_integer(opened_at) do
    with {:ok, context} <- SubmissionContext.new(context),
         {:ok, evidence} <- normalize_evidence(evidence) do
      {:ok,
       %__MODULE__{
         ref: ref,
         mind_ref: mind_ref,
         context: %{context | seal: nil},
         evidence: evidence,
         opened_at: opened_at,
         seal: nil
       }}
    end
  end

  def new(_context, _ref, _mind_ref, _evidence, _opened_at), do: {:error, :invalid_mind_turn}

  @doc "Returns the canonical Evidence references visible to the Turn."
  @spec evidence_refs(t()) :: [String.t()]
  def evidence_refs(%__MODULE__{evidence: evidence}), do: Enum.map(evidence, & &1.ref)

  @doc "Returns the conservative union of labels inherited from visible Evidence."
  @spec labels(t()) :: {:ok, [Label.t()]} | {:error, term()}
  def labels(%__MODULE__{evidence: evidence}), do: Derivation.inherited_labels(evidence)

  @doc "Returns the trusted context fields suitable for Evidence bindings."
  @spec context_bindings(t()) :: map()
  def context_bindings(%__MODULE__{context: context}),
    do: SubmissionContext.evidence_bindings(context)

  @doc false
  @spec context(t()) :: {:ok, SubmissionContext.t()} | {:error, term()}
  def context(%__MODULE__{context: context}) do
    with {:ok, context} <- SubmissionContext.new(context),
         true <- is_nil(context.seal) do
      {:ok, context}
    else
      false -> {:error, :mind_turn_context_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec seal(t(), binary()) :: {:ok, t()} | {:error, term()}
  def seal(%__MODULE__{} = turn, secret) do
    if Seal.valid_secret?(secret) do
      with {:ok, seal} <- Seal.sign(seal_material(turn), secret, @seal_domain),
           do: {:ok, %{turn | seal: seal}}
    else
      {:error, :invalid_turn_seal_material}
    end
  end

  def seal(_turn, _secret), do: {:error, :invalid_turn_seal_material}

  @doc false
  @spec verify_seal(t(), binary()) :: :ok | {:error, term()}
  def verify_seal(%__MODULE__{seal: supplied} = turn, secret)
      when is_binary(supplied) and supplied != "" do
    case Seal.verify(seal_material(turn), supplied, secret, @seal_domain) do
      :ok -> :ok
      :error -> {:error, :turn_authentication_failed}
    end
  end

  def verify_seal(_turn, _secret), do: {:error, :turn_authentication_failed}

  defp seal_material(%__MODULE__{} = turn) do
    %{
      "ref" => turn.ref,
      "mind_ref" => turn.mind_ref,
      "context" => SubmissionContext.canonical(turn.context),
      "evidence" => Enum.map(turn.evidence, &%{"ref" => &1.ref, "digest" => Evidence.digest(&1)}),
      "opened_at" => turn.opened_at
    }
  end

  defp normalize_evidence(evidence) do
    case Evidence.normalize_unique(evidence) do
      {:ok, records} -> {:ok, Enum.sort_by(records, & &1.ref)}
      {:error, {:duplicate_evidence, _ref}} -> {:error, :duplicate_turn_evidence}
      {:error, _reason} = error -> error
    end
  end
end
