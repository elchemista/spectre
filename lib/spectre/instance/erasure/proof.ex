defmodule Spectre.Instance.Erasure.Proof do
  @moduledoc """
  Privacy-safe proof of configured Instance-data erasure.

  The component map covers the configured Journal store, receipt payloads
  still referenced by the canonical outbox, installed package data, and
  stable/legacy checkpoints.
  It says nothing about State or Memory stores, delivered receipt records,
  telemetry, provider logs, replicas, exports, or backups owned by the host.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Instance.Ref

  @schema_version 1
  @scope :configured_instance_data
  @outcomes [:erased, :already_erased]

  @enforce_keys [
    :schema_version,
    :instance_key,
    :scope,
    :outcome,
    :owner_fencing_token,
    :completed_at,
    :components,
    :keys
  ]
  defstruct schema_version: @schema_version,
            instance_key: nil,
            scope: @scope,
            outcome: nil,
            owner_fencing_token: nil,
            completed_at: nil,
            components: %{},
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
          scope: :configured_instance_data,
          outcome: :erased | :already_erased,
          owner_fencing_token: pos_integer(),
          completed_at: non_neg_integer(),
          components: map(),
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
      components: Map.get(attrs, :components, %{}),
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
         :ok <- components(proof.components),
         :ok <- keys(proof.keys),
         :ok <- Value.validate(Map.from_struct(proof)) do
      :ok
    else
      false -> {:error, :invalid_instance_erasure_proof}
      {:error, _reason} = error -> error
    end
  end

  def validate(value), do: {:error, {:invalid_instance_erasure_proof, shape(value)}}

  defp components(
         %{
           journal: journal,
           receipt_payloads: receipt_payloads,
           checkpoint: checkpoint
         } = components
       ) do
    # `package_data` was added without changing the public proof schema version.
    # Keep schema-v1 proofs produced before that addition valid while requiring
    # the full component contract whenever package evidence is present.
    package_data =
      Map.get(components, :package_data, %{
        outcome: :not_configured,
        package_count: 0,
        erased_count: 0,
        already_erased_count: 0,
        packages: []
      })

    with :ok <- journal_component(journal),
         :ok <- receipt_component(receipt_payloads),
         :ok <- package_data_component(package_data),
         :ok <- checkpoint_component(checkpoint) do
      :ok
    else
      {:error, :invalid_component} -> {:error, :invalid_instance_erasure_proof_components}
    end
  end

  defp components(_components), do: {:error, :invalid_instance_erasure_proof_components}

  defp journal_component(%{outcome: outcome, key_count: count})
       when outcome in [:erased, :already_erased, :not_configured] and is_integer(count) and
              count >= 0,
       do: :ok

  defp journal_component(_component), do: {:error, :invalid_component}

  defp receipt_component(%{
         outcome: outcome,
         payload_count: total,
         deleted_count: deleted,
         not_found_count: not_found
       })
       when outcome in [:erased, :already_erased, :not_applicable, :not_configured] and
              is_integer(total) and total >= 0 and is_integer(deleted) and deleted >= 0 and
              is_integer(not_found) and not_found >= 0 and deleted + not_found == total,
       do: :ok

  defp receipt_component(_component), do: {:error, :invalid_component}

  defp package_data_component(%{
         outcome: :not_configured,
         package_count: 0,
         erased_count: 0,
         already_erased_count: 0,
         packages: []
       }),
       do: :ok

  defp package_data_component(%{
         outcome: outcome,
         package_count: total,
         erased_count: erased,
         already_erased_count: already,
         packages: packages
       })
       when outcome in @outcomes do
    if valid_package_counts?(total, erased, already) and valid_packages?(packages, total),
      do: :ok,
      else: {:error, :invalid_component}
  end

  defp package_data_component(_component), do: {:error, :invalid_component}

  defp valid_package_counts?(total, erased, already) do
    is_integer(total) and total > 0 and is_integer(erased) and erased >= 0 and is_integer(already) and
      already >= 0 and erased + already == total
  end

  defp valid_packages?(packages, total), do: is_list(packages) and length(packages) == total

  defp checkpoint_component(%{outcome: outcome, key_count: count})
       when outcome in @outcomes and is_integer(count) and count > 0,
       do: :ok

  defp checkpoint_component(_component), do: {:error, :invalid_component}

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
