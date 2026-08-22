defmodule Spectre.Instance.Erasure.Proof do
  @moduledoc """
  Privacy-safe proof of canonical Instance checkpoint erasure.

  This proof is intentionally scoped. It says nothing about State or Memory
  stores, receipt payloads, Journal sinks, telemetry, provider logs, replicas,
  or backups owned by the host.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Instance.Ref

  @schema_version 1
  @scope :canonical_instance_checkpoint
  @outcomes [:erased, :already_erased]

  @enforce_keys [
    :schema_version,
    :instance_key,
    :scope,
    :outcome,
    :owner_fencing_token,
    :completed_at,
    :keys
  ]
  defstruct schema_version: @schema_version,
            instance_key: nil,
            scope: @scope,
            outcome: nil,
            owner_fencing_token: nil,
            completed_at: nil,
            keys: []

  @type key_proof :: %{
          required(:kind) => :stable | :legacy,
          required(:prior_state) => :present | :absent | :erased,
          required(:outcome) => :erased | :already_erased,
          required(:marker_digest) => String.t()
        }

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          instance_key: String.t(),
          scope: :canonical_instance_checkpoint,
          outcome: :erased | :already_erased,
          owner_fencing_token: pos_integer(),
          completed_at: non_neg_integer(),
          keys: [key_proof()]
        }

  @doc false
  @spec new(Ref.t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%Ref{} = ref, attrs) when is_list(attrs), do: new(ref, Map.new(attrs))

  def new(%Ref{} = ref, attrs) when is_map(attrs) and not is_struct(attrs) do
    proof = %__MODULE__{
      schema_version: Map.get(attrs, :schema_version, @schema_version),
      instance_key: ref.key,
      scope: Map.get(attrs, :scope, @scope),
      outcome: Map.get(attrs, :outcome),
      owner_fencing_token: Map.get(attrs, :owner_fencing_token),
      completed_at: Map.get(attrs, :completed_at),
      keys: Map.get(attrs, :keys, [])
    }

    case validate(proof) do
      :ok -> {:ok, proof}
      {:error, _reason} = error -> error
    end
  end

  def new(%Ref{}, value), do: {:error, {:invalid_instance_erasure_proof, shape(value)}}

  @doc false
  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = proof) do
    with true <- proof.schema_version == @schema_version,
         true <- is_binary(proof.instance_key) and proof.instance_key != "",
         true <- proof.scope == @scope,
         true <- proof.outcome in @outcomes,
         true <- is_integer(proof.owner_fencing_token) and proof.owner_fencing_token > 0,
         true <- is_integer(proof.completed_at) and proof.completed_at >= 0,
         :ok <- keys(proof.keys),
         :ok <- Value.validate(Map.from_struct(proof)) do
      :ok
    else
      false -> {:error, :invalid_instance_erasure_proof}
      {:error, _reason} = error -> error
    end
  end

  def validate(value), do: {:error, {:invalid_instance_erasure_proof, shape(value)}}

  defp keys(entries) when is_list(entries) and entries != [] do
    valid? =
      Enum.all?(entries, fn
        %{
          kind: kind,
          prior_state: prior_state,
          outcome: outcome,
          marker_digest: <<digest::binary-size(64)>>
        }
        when kind in [:stable, :legacy] and prior_state in [:present, :absent, :erased] and
               outcome in @outcomes ->
          String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

        _invalid ->
          false
      end)

    if valid?, do: :ok, else: {:error, :invalid_instance_erasure_proof_keys}
  end

  defp keys(_entries), do: {:error, :invalid_instance_erasure_proof_keys}

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
