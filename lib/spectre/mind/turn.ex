defmodule Spectre.Mind.Turn do
  @moduledoc """
  Ephemeral, capability-free input to one deliberation.

  A Turn contains a sanitized authenticated context and immutable Evidence, but
  no authority view, Grant, executor or secret. The context seal is removed
  before the Turn crosses into application deliberation. Evidence references
  and the conservative label union are derived from the records instead of
  being stored a second time.
  """

  alias Spectre.Canonical.Value
  alias Spectre.{Evidence, Label, SubmissionContext}
  alias Spectre.Evidence.Derivation
  alias Spectre.Portable
  alias Spectre.Scope

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

  @minimum_secret_bytes 32
  @seal_domain "spectre:mind-turn:v1\0"

  @doc "Builds a Turn from a live Scope and the exact Evidence made visible to it."
  @spec new(Scope.t(), String.t(), String.t(), [Evidence.t()], integer()) ::
          {:ok, t()} | {:error, term()}
  def new(%Scope{} = scope, ref, mind_ref, evidence, opened_at)
      when is_binary(ref) and ref != "" and is_binary(mind_ref) and mind_ref != "" and
             is_list(evidence) and is_integer(opened_at) do
    with {:ok, context} <- turn_context(scope),
         {:ok, evidence} <- normalize_evidence(evidence),
         {:ok, labels} <- Derivation.inherited_labels(evidence),
         :ok <- Portable.validate(Enum.map(labels, &Label.canonical/1)) do
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

  def new(_scope, _ref, _mind_ref, _evidence, _opened_at), do: {:error, :invalid_mind_turn}

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
  @spec seal(t(), binary()) :: {:ok, t()} | {:error, term()}
  def seal(%__MODULE__{} = turn, secret)
      when is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes do
    with {:ok, encoded} <- Value.encode(seal_material(turn)) do
      seal =
        :crypto.mac(:hmac, :sha256, secret, @seal_domain <> encoded)
        |> Base.url_encode64(padding: false)

      {:ok, %{turn | seal: seal}}
    end
  end

  def seal(_turn, _secret), do: {:error, :invalid_turn_seal_material}

  @doc false
  @spec verify_seal(t(), binary()) :: :ok | {:error, term()}
  def verify_seal(%__MODULE__{seal: supplied} = turn, secret)
      when is_binary(supplied) and supplied != "" and is_binary(secret) and
             byte_size(secret) >= @minimum_secret_bytes do
    with {:ok, supplied} <- Base.url_decode64(supplied, padding: false),
         {:ok, encoded} <- Value.encode(seal_material(turn)) do
      expected = :crypto.mac(:hmac, :sha256, secret, @seal_domain <> encoded)

      if byte_size(supplied) == byte_size(expected) and :crypto.hash_equals(supplied, expected),
        do: :ok,
        else: {:error, :turn_authentication_failed}
    else
      :error -> {:error, :turn_authentication_failed}
      {:error, _reason} -> {:error, :turn_authentication_failed}
    end
  rescue
    _exception -> {:error, :turn_authentication_failed}
  catch
    _kind, _reason -> {:error, :turn_authentication_failed}
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

  defp turn_context(%Scope{} = scope) do
    with {:ok, context} <- SubmissionContext.new(scope.context),
         true <- context.domain_ref == Scope.domain_ref(scope),
         true <- context.scope_ref == Scope.ref(scope) do
      {:ok, context}
    else
      false -> {:error, :scope_context_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_evidence(evidence) do
    Enum.reduce_while(evidence, {:ok, [], MapSet.new()}, fn value, {:ok, records, refs} ->
      with {:ok, record} <- Evidence.new(value),
           false <- MapSet.member?(refs, record.ref) do
        {:cont, {:ok, [record | records], MapSet.put(refs, record.ref)}}
      else
        true -> {:halt, {:error, :duplicate_turn_evidence}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records, _refs} -> {:ok, Enum.sort_by(records, & &1.ref)}
      {:error, _reason} = error -> error
    end
  end
end
