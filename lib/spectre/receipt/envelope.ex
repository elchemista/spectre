defmodule Spectre.Receipt.Envelope do
  @moduledoc """
  Portable evidence for one nondeterministic or canonical boundary.

  The envelope wraps existing typed receipt payloads; it does not replace
  their domain-specific validation. Identity is deterministic, so a sink can
  make append retries idempotent after an acknowledgement is lost.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Determinism
  alias Spectre.Execution.PortableDigest
  alias Spectre.Run.Value, as: RunValue
  alias Spectre.SensitiveData

  @schema_version 1
  @kinds [
    :run_input_admitted,
    :inference_selected,
    :inference_attempt_started,
    :inference_attempt_terminal,
    :inference_attempt_superseded,
    :inference_consumer_never_attached,
    :policy_decision,
    :authority_decision,
    :effect_terminal,
    :action_terminal,
    :nondeterminism_sample
  ]
  @privacy_classes [:public, :internal, :confidential, :restricted]

  @identity_fields [
    :schema_version,
    :kind,
    :instance_ref,
    :run_id,
    :run_revision,
    :inference_id,
    :invocation_id,
    :attempt_id,
    :control_revision,
    :stream_epoch,
    :canonical_revision,
    :correlation_id,
    :causation_id,
    :definition_ref,
    :manifest_digest,
    :closure_digest,
    :pre_state_digest,
    :post_state_digest,
    :payload_schema_ref,
    :payload_digest,
    :privacy,
    :metadata
  ]

  @enforce_keys [:schema_version, :id, :kind, :correlation_id, :privacy]
  # Boundary evidence keeps correlation, lineage, and digest fields explicit.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct schema_version: @schema_version,
            id: nil,
            kind: nil,
            instance_ref: nil,
            run_id: nil,
            run_revision: nil,
            inference_id: nil,
            invocation_id: nil,
            attempt_id: nil,
            control_revision: nil,
            stream_epoch: nil,
            canonical_revision: nil,
            correlation_id: nil,
            causation_id: nil,
            definition_ref: nil,
            manifest_digest: nil,
            closure_digest: nil,
            pre_state_digest: nil,
            post_state_digest: nil,
            payload_schema_ref: nil,
            payload: nil,
            payload_ref: nil,
            payload_digest: nil,
            privacy: :internal,
            recorded_at: nil,
            metadata: %{}

  @type kind :: atom()
  @type privacy :: :public | :internal | :confidential | :restricted
  @type t :: %__MODULE__{}

  @doc "Returns kinds defined by the core receipt schema."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Builds and validates a deterministic receipt envelope."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = envelope), do: envelope |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs =
      attrs
      |> Map.put_new(:schema_version, @schema_version)
      |> Map.put_new(:privacy, :internal)
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:payload, nil)
      |> Map.put_new(:payload_ref, nil)
      |> Map.put_new(:recorded_at, Determinism.system_time(:millisecond))
      # Identity must not depend on whether a caller omitted an optional field
      # or supplied its canonical `nil` value. Struct round-trips materialize
      # every optional key, so normalize the map before computing digests.
      |> then(&Map.merge(Map.from_struct(struct(__MODULE__)), &1))

    supplied_payload_digest = Map.get(attrs, :payload_digest)

    with :ok <- validate_keys(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version)),
         :ok <- validate_kind(Map.get(attrs, :kind)),
         :ok <- nonempty(Map.get(attrs, :correlation_id), :correlation_id),
         :ok <- optional_binary(Map.get(attrs, :causation_id), :causation_id),
         :ok <- validate_privacy(Map.get(attrs, :privacy)),
         :ok <- nonempty(Map.get(attrs, :payload_schema_ref), :payload_schema_ref),
         :ok <- validate_revisions(attrs),
         :ok <- validate_recorded_at(Map.get(attrs, :recorded_at)),
         :ok <- validate_identity_fields(attrs),
         :ok <- validate_boundary_identity(attrs),
         :ok <- validate_metadata(Map.get(attrs, :metadata)),
         :ok <- validate_payload_shape(attrs),
         {:ok, payload_digest} <- payload_digest(attrs),
         :ok <- verify_supplied_payload_digest(supplied_payload_digest, payload_digest),
         normalized_attrs = Map.put(attrs, :payload_digest, payload_digest),
         :ok <- validate_digest_fields(normalized_attrs),
         :ok <- validate_sensitive_payload(normalized_attrs),
         :ok <- validate_portable(normalized_attrs),
         {:ok, id} <- receipt_id(normalized_attrs),
         :ok <- verify_supplied_id(Map.get(attrs, :id), id) do
      {:ok,
       normalized_attrs
       |> Map.put(:id, id)
       |> Map.take(fields())
       |> then(&struct(__MODULE__, &1))}
    end
  end

  def new(value), do: {:error, {:invalid_receipt_envelope, shape(value)}}

  @doc "Builds an envelope or raises with the stable validation reason."
  @spec new!(map() | keyword() | t()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, envelope} -> envelope
      {:error, reason} -> raise ArgumentError, "invalid receipt envelope: #{inspect(reason)}"
    end
  end

  @doc "Returns the deterministic digest of the complete portable envelope."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = envelope) do
    with {:ok, validated} <- new(envelope),
         true <- validated == envelope,
         {:ok, digest} <- PortableDigest.digest(Map.from_struct(envelope)) do
      digest
    else
      false ->
        raise ArgumentError, "cannot digest a non-canonical receipt envelope"

      {:error, reason} ->
        raise ArgumentError, "cannot digest receipt envelope: #{inspect(reason)}"
    end
  end

  @doc "Returns portable canonical data suitable for an external sink."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = envelope) do
    envelope = new!(envelope)

    Map.new(Map.from_struct(envelope), fn {key, value} ->
      case RunValue.encode(value) do
        {:ok, encoded} -> {Atom.to_string(key), encoded}
        {:error, reason} -> raise ArgumentError, "cannot encode receipt field: #{inspect(reason)}"
      end
    end)
  end

  defp payload_digest(%{payload: nil, payload_ref: ref}) when is_binary(ref) and ref != "",
    do: PortableDigest.digest(%{payload_ref: ref})

  defp payload_digest(%{payload: payload, payload_ref: nil}),
    do: PortableDigest.digest(payload)

  defp payload_digest(_attrs), do: {:error, :receipt_payload_and_ref_conflict}

  defp receipt_id(attrs) do
    identity = Map.take(attrs, @identity_fields)

    with {:ok, digest} <- Value.digest(identity) do
      {:ok, "receipt:" <> digest}
    end
  end

  defp verify_supplied_id(nil, _expected), do: :ok
  defp verify_supplied_id(expected, expected), do: :ok
  defp verify_supplied_id(_supplied, _expected), do: {:error, :receipt_id_mismatch}

  defp verify_supplied_payload_digest(nil, _expected), do: :ok
  defp verify_supplied_payload_digest(expected, expected), do: :ok

  defp verify_supplied_payload_digest(_supplied, _expected),
    do: {:error, :receipt_payload_digest_mismatch}

  defp validate_payload_shape(%{payload_ref: ref})
       when not is_nil(ref) and (not is_binary(ref) or ref == ""),
       do: {:error, :invalid_receipt_payload_ref}

  defp validate_payload_shape(%{payload_schema_ref: ref})
       when not is_nil(ref) and (not is_binary(ref) or ref == ""),
       do: {:error, :invalid_receipt_payload_schema_ref}

  defp validate_payload_shape(_attrs), do: :ok

  defp validate_sensitive_payload(%{payload: payload, privacy: :public}) do
    case SensitiveData.sensitive_path(payload) do
      nil -> :ok
      path -> {:error, {:public_receipt_contains_sensitive_data, path}}
    end
  end

  defp validate_sensitive_payload(_attrs), do: :ok

  defp validate_keys(attrs) do
    unknown = Map.keys(attrs) -- fields()

    if unknown == [], do: :ok, else: {:error, {:unknown_receipt_envelope_fields, unknown}}
  end

  defp validate_revisions(attrs) do
    Enum.reduce_while(
      [:run_revision, :control_revision, :canonical_revision],
      :ok,
      fn field, :ok ->
        case Map.get(attrs, field) do
          nil -> {:cont, :ok}
          value when is_integer(value) and value >= 0 -> {:cont, :ok}
          _invalid -> {:halt, {:error, {:invalid_receipt_field, field}}}
        end
      end
    )
  end

  defp validate_recorded_at(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_recorded_at(_value), do: {:error, {:invalid_receipt_field, :recorded_at}}

  defp validate_digest_fields(attrs) do
    Enum.reduce_while(
      [
        :manifest_digest,
        :closure_digest,
        :pre_state_digest,
        :post_state_digest,
        :payload_digest
      ],
      :ok,
      fn field, :ok ->
        case validate_digest_value(Map.get(attrs, field), field) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    )
  end

  defp validate_digest_value(nil, _field), do: :ok

  defp validate_digest_value(digest, field) when is_binary(digest) do
    if valid_digest?(digest), do: :ok, else: {:error, {:invalid_receipt_digest, field}}
  end

  defp validate_digest_value(_invalid, field),
    do: {:error, {:invalid_receipt_digest, field}}

  defp validate_identity_fields(attrs) do
    Enum.reduce_while(
      [
        :instance_ref,
        :run_id,
        :inference_id,
        :invocation_id,
        :attempt_id,
        :stream_epoch,
        :definition_ref,
        :manifest_digest,
        :closure_digest,
        :pre_state_digest,
        :post_state_digest
      ],
      :ok,
      fn field, :ok ->
        case optional_binary(Map.get(attrs, field), field) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end
    )
  end

  defp validate_boundary_identity(%{kind: kind} = attrs)
       when kind in [
              :run_input_admitted,
              :inference_selected,
              :inference_attempt_started,
              :inference_attempt_terminal,
              :inference_attempt_superseded,
              :inference_consumer_never_attached
            ] do
    with :ok <- required_fields(attrs, [:instance_ref, :run_id, :run_revision]),
         :ok <- required_fields(attrs, [:canonical_revision, :definition_ref]),
         :ok <- required_fields(attrs, [:pre_state_digest, :post_state_digest]) do
      validate_inference_boundary_identity(kind, attrs)
    end
  end

  defp validate_boundary_identity(%{kind: :policy_decision} = attrs) do
    required_fields(attrs, [
      :instance_ref,
      :run_id,
      :run_revision,
      :canonical_revision,
      :definition_ref,
      :pre_state_digest,
      :post_state_digest
    ])
  end

  defp validate_boundary_identity(%{kind: kind} = attrs)
       when kind in [:effect_terminal, :action_terminal] do
    required_fields(attrs, [
      :instance_ref,
      :run_id,
      :run_revision,
      :invocation_id,
      :canonical_revision,
      :definition_ref,
      :pre_state_digest,
      :post_state_digest
    ])
  end

  defp validate_boundary_identity(%{kind: :authority_decision} = attrs) do
    required_fields(attrs, [
      :instance_ref,
      :canonical_revision,
      :definition_ref,
      :pre_state_digest,
      :post_state_digest
    ])
  end

  defp validate_boundary_identity(_attrs), do: :ok

  defp validate_inference_boundary_identity(:run_input_admitted, _attrs), do: :ok

  defp validate_inference_boundary_identity(_kind, attrs) do
    required_fields(attrs, [
      :inference_id,
      :invocation_id,
      :attempt_id,
      :control_revision,
      :stream_epoch
    ])
  end

  defp required_fields(attrs, fields) do
    case Enum.find(fields, &is_nil(Map.get(attrs, &1))) do
      nil -> :ok
      field -> {:error, {:missing_receipt_field, field}}
    end
  end

  defp validate_metadata(metadata) when is_map(metadata) and not is_struct(metadata), do: :ok
  defp validate_metadata(_metadata), do: {:error, :invalid_receipt_metadata}

  defp validate_portable(attrs) do
    # Receipt payloads deliberately preserve typed boundary evidence (for
    # example `Spectre.Input` or `Spectre.Effect`).  Run.Value is the portable
    # codec used for those typed values; Canonical.Value would reject every
    # struct even though `to_data/1` can encode it safely.
    case RunValue.validate(Map.drop(attrs, [:id])) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_receipt_envelope, reason}}
    end
  end

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(version), do: {:error, {:unsupported_receipt_schema, version}}

  defp validate_kind(kind) when kind in @kinds, do: :ok
  defp validate_kind(kind), do: {:error, {:invalid_receipt_kind, kind}}

  defp validate_privacy(privacy) when privacy in @privacy_classes, do: :ok
  defp validate_privacy(privacy), do: {:error, {:invalid_receipt_privacy, privacy}}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(_value, field), do: {:error, {:invalid_receipt_field, field}}

  defp optional_binary(nil, _field), do: :ok
  defp optional_binary(value, field), do: nonempty(value, field)

  defp valid_digest?(<<digest::binary-size(64)>>) do
    String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
  end

  defp valid_digest?(_digest), do: false

  defp fields do
    __MODULE__.__struct__() |> Map.keys() |> List.delete(:__struct__)
  end

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
