defmodule Spectre.Mind.Turn do
  @moduledoc """
  Ephemeral, capability-free input to one deliberation.

  A Turn contains authenticated routing identity and immutable Evidence, but no
  authority view, Grant, executor or secret.  `context_labels` is the
  conservative union of every Evidence label visible to the deliberation.
  """

  alias Spectre.Canonical.Value
  alias Spectre.{Evidence, Label}
  alias Spectre.Evidence.Derivation
  alias Spectre.Portable
  alias Spectre.Scope

  @enforce_keys [
    :ref,
    :domain_ref,
    :scope_ref,
    :mind_ref,
    :submission_context_ref,
    :authenticated_principal_ref,
    :evidence,
    :evidence_refs,
    :context_labels,
    :opened_at
  ]
  defstruct @enforce_keys ++ [seal: nil]

  @type t :: %__MODULE__{
          ref: String.t(),
          domain_ref: String.t(),
          scope_ref: String.t(),
          mind_ref: String.t(),
          submission_context_ref: String.t(),
          authenticated_principal_ref: String.t(),
          evidence: [Evidence.t()],
          evidence_refs: [String.t()],
          context_labels: [Label.t()],
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
    with {:ok, evidence} <- normalize_evidence(evidence),
         {:ok, labels} <- Derivation.inherited_labels(evidence),
         :ok <- Portable.validate(Enum.map(labels, &Label.canonical/1)) do
      {:ok,
       %__MODULE__{
         ref: ref,
         domain_ref: scope.domain.ref,
         scope_ref: scope.ref,
         mind_ref: mind_ref,
         submission_context_ref: scope.context.ref,
         authenticated_principal_ref: scope.context.authenticated_principal_ref,
         evidence: evidence,
         evidence_refs: evidence |> Enum.map(& &1.ref) |> Enum.sort(),
         context_labels: labels,
         opened_at: opened_at,
         seal: nil
       }}
    end
  end

  def new(_scope, _ref, _mind_ref, _evidence, _opened_at), do: {:error, :invalid_mind_turn}

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
      "domain_ref" => turn.domain_ref,
      "scope_ref" => turn.scope_ref,
      "mind_ref" => turn.mind_ref,
      "submission_context_ref" => turn.submission_context_ref,
      "authenticated_principal_ref" => turn.authenticated_principal_ref,
      "evidence" => Enum.map(turn.evidence, &%{"ref" => &1.ref, "digest" => Evidence.digest(&1)}),
      "evidence_refs" => turn.evidence_refs,
      "context_labels" => Enum.map(turn.context_labels, &Label.canonical/1),
      "opened_at" => turn.opened_at
    }
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
