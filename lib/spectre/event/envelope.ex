defmodule Spectre.Event.Envelope do
  @moduledoc """
  Portable event envelope whose owner is fixed at Instance admission time.

  Origins are evidence; they never select the Definition that consumes an
  event. A continuation owns replies, policy answers and operational progress.
  Events without a continuation are owned by the active Definition after the
  admission and schema-compatibility checks have succeeded.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Run.Ref, as: RunRef

  @schema_version 1
  @classes [
    :input,
    :reply,
    :policy_answer,
    :flow_progress,
    :flow_completion,
    :work_progress,
    :work_completion,
    :vigil_progress,
    :vigil_completion,
    :global
  ]
  @statuses [:pending, :admitted, :quarantined]

  @fields [
    :schema_version,
    :id,
    :event_class,
    :class_ref,
    :causation_id,
    :correlation_id,
    :continuation_ref,
    :origin_definition_ref,
    :owner_definition_ref,
    :payload_schema_ref,
    :payload,
    :admitted_activation_generation,
    :authority_epoch,
    :owner_fencing_token,
    :admission_revision,
    :status,
    :quarantine_reason,
    :provenance,
    :authenticity,
    :emitted_at,
    :admitted_at,
    :admission_receipt
  ]
  @data_fields Enum.map(@fields, &Atom.to_string/1) ++
                 [
                   "origin_definition_canonicalization_version",
                   "origin_definition_contract_version",
                   "owner_definition_canonicalization_version",
                   "owner_definition_contract_version"
                 ]

  @enforce_keys [
    :schema_version,
    :id,
    :event_class,
    :class_ref,
    :correlation_id,
    :payload_schema_ref,
    :payload,
    :status,
    :provenance,
    :authenticity,
    :emitted_at
  ]
  # The envelope keeps every admission and ownership fence explicit.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct schema_version: @schema_version,
            id: nil,
            event_class: nil,
            class_ref: nil,
            causation_id: nil,
            correlation_id: nil,
            continuation_ref: nil,
            origin_definition_ref: nil,
            owner_definition_ref: nil,
            payload_schema_ref: nil,
            payload: nil,
            admitted_activation_generation: nil,
            authority_epoch: nil,
            owner_fencing_token: nil,
            admission_revision: nil,
            status: :pending,
            quarantine_reason: nil,
            provenance: %{},
            authenticity: %{},
            emitted_at: nil,
            admitted_at: nil,
            admission_receipt: nil

  @type event_class ::
          :input
          | :reply
          | :policy_answer
          | :flow_progress
          | :flow_completion
          | :work_progress
          | :work_completion
          | :vigil_progress
          | :vigil_completion
          | :global

  @type continuation_ref :: RunRef.t() | OperationRef.t() | nil
  @type status :: :pending | :admitted | :quarantined

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          id: String.t(),
          event_class: event_class(),
          class_ref: String.t(),
          causation_id: String.t() | nil,
          correlation_id: String.t(),
          continuation_ref: continuation_ref(),
          origin_definition_ref: DefinitionRef.t() | nil,
          owner_definition_ref: DefinitionRef.t() | nil,
          payload_schema_ref: String.t(),
          payload: term(),
          admitted_activation_generation: non_neg_integer() | nil,
          authority_epoch: non_neg_integer() | nil,
          owner_fencing_token: pos_integer() | nil,
          admission_revision: pos_integer() | nil,
          status: status(),
          quarantine_reason: term(),
          provenance: map(),
          authenticity: map(),
          emitted_at: non_neg_integer(),
          admitted_at: non_neg_integer() | nil,
          admission_receipt: String.t() | nil
        }

  @doc "Returns the Event Envelope schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Returns the event classes understood by this release."
  @spec classes() :: [event_class()]
  def classes, do: @classes

  @doc "Builds and validates a pending or admitted event envelope."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = envelope), do: envelope |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    event_class = Map.get(attrs, :event_class)

    attrs =
      attrs
      |> Map.put_new(:schema_version, @schema_version)
      |> Map.put_new(:id, Spectre.Identity.uuid7())
      |> Map.put_new(:class_ref, default_class_ref(event_class))
      |> Map.put_new(:correlation_id, Spectre.Identity.uuid7())
      |> Map.put_new(:payload, nil)
      |> Map.put_new(:status, :pending)
      |> Map.put_new(:provenance, %{})
      |> Map.put_new(:authenticity, %{})
      |> Map.put_new(:emitted_at, System.system_time(:millisecond))

    with :ok <- validate_keys(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version)),
         :ok <- validate_class(event_class),
         :ok <- nonempty(Map.get(attrs, :id), :id),
         :ok <- nonempty(Map.get(attrs, :class_ref), :class_ref),
         :ok <- optional_binary(Map.get(attrs, :causation_id), :causation_id),
         :ok <- nonempty(Map.get(attrs, :correlation_id), :correlation_id),
         {:ok, continuation_ref} <- normalize_continuation(Map.get(attrs, :continuation_ref)),
         {:ok, origin_ref} <- normalize_definition_ref(Map.get(attrs, :origin_definition_ref)),
         {:ok, owner_ref} <- normalize_definition_ref(Map.get(attrs, :owner_definition_ref)),
         :ok <- nonempty(Map.get(attrs, :payload_schema_ref), :payload_schema_ref),
         :ok <- portable(Map.get(attrs, :payload), :payload),
         :ok <- validate_status(Map.get(attrs, :status)),
         :ok <- portable_map(Map.get(attrs, :provenance), :provenance),
         :ok <- portable_map(Map.get(attrs, :authenticity), :authenticity),
         :ok <- non_negative(Map.get(attrs, :emitted_at), :emitted_at) do
      base = %__MODULE__{
        schema_version: @schema_version,
        id: Map.fetch!(attrs, :id),
        event_class: event_class,
        class_ref: Map.fetch!(attrs, :class_ref),
        causation_id: Map.get(attrs, :causation_id),
        correlation_id: Map.fetch!(attrs, :correlation_id),
        continuation_ref: continuation_ref,
        origin_definition_ref: origin_ref,
        owner_definition_ref: owner_ref,
        payload_schema_ref: Map.fetch!(attrs, :payload_schema_ref),
        payload: Map.fetch!(attrs, :payload),
        admitted_activation_generation: Map.get(attrs, :admitted_activation_generation),
        authority_epoch: Map.get(attrs, :authority_epoch),
        owner_fencing_token: Map.get(attrs, :owner_fencing_token),
        admission_revision: Map.get(attrs, :admission_revision),
        status: Map.fetch!(attrs, :status),
        quarantine_reason: Map.get(attrs, :quarantine_reason),
        provenance: Map.fetch!(attrs, :provenance),
        authenticity: Map.fetch!(attrs, :authenticity),
        emitted_at: Map.fetch!(attrs, :emitted_at),
        admitted_at: Map.get(attrs, :admitted_at),
        admission_receipt: nil
      }

      with :ok <- validate_admission(base) do
        put_receipt(base, Map.get(attrs, :admission_receipt))
      end
    end
  end

  def new(value), do: {:error, {:invalid_event_envelope, shape(value)}}

  @doc "Builds an envelope or raises with its stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, envelope} -> envelope
      {:error, reason} -> raise ArgumentError, "invalid Event Envelope: #{inspect(reason)}"
    end
  end

  @doc "Applies the sequencer-owned admission fields to a pending envelope."
  @spec admit(t(), map() | keyword()) :: {:ok, t()} | {:error, term()}
  def admit(%__MODULE__{status: :pending} = envelope, admission) do
    admission =
      if is_list(admission) and Keyword.keyword?(admission),
        do: Map.new(admission),
        else: admission

    if is_map(admission) and not is_struct(admission) do
      envelope
      |> Map.from_struct()
      |> Map.merge(admission)
      |> Map.put(:admission_receipt, nil)
      |> new()
    else
      {:error, {:invalid_event_admission, shape(admission)}}
    end
  end

  def admit(%__MODULE__{} = envelope, _admission),
    do: {:error, {:event_already_admitted, envelope.id, envelope.status}}

  @doc "Returns a digest of fields supplied before Instance admission."
  @spec intent_digest(t()) :: String.t()
  def intent_digest(%__MODULE__{} = envelope) do
    envelope
    |> to_data()
    |> Map.take([
      "schema_version",
      "id",
      "event_class",
      "class_ref",
      "causation_id",
      "correlation_id",
      "continuation_ref",
      "origin_definition_ref",
      "origin_definition_canonicalization_version",
      "origin_definition_contract_version",
      "payload_schema_ref",
      "payload",
      "provenance",
      "authenticity",
      "emitted_at"
    ])
    |> Value.digest!()
  end

  @doc "Returns true only after the Instance sequencer admitted or quarantined the event."
  @spec admitted?(t()) :: boolean()
  def admitted?(%__MODULE__{status: status}), do: status in [:admitted, :quarantined]

  @doc "Returns portable canonical data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = envelope) do
    %{
      "schema_version" => envelope.schema_version,
      "id" => envelope.id,
      "event_class" => Atom.to_string(envelope.event_class),
      "class_ref" => envelope.class_ref,
      "causation_id" => envelope.causation_id,
      "correlation_id" => envelope.correlation_id,
      "continuation_ref" => continuation_to_data(envelope.continuation_ref),
      "origin_definition_ref" => ref_string(envelope.origin_definition_ref),
      "origin_definition_canonicalization_version" =>
        ref_version(envelope.origin_definition_ref, :canonicalization_version),
      "origin_definition_contract_version" =>
        ref_version(envelope.origin_definition_ref, :contract_version),
      "owner_definition_ref" => ref_string(envelope.owner_definition_ref),
      "owner_definition_canonicalization_version" =>
        ref_version(envelope.owner_definition_ref, :canonicalization_version),
      "owner_definition_contract_version" =>
        ref_version(envelope.owner_definition_ref, :contract_version),
      "payload_schema_ref" => envelope.payload_schema_ref,
      "payload" => envelope.payload,
      "admitted_activation_generation" => envelope.admitted_activation_generation,
      "authority_epoch" => envelope.authority_epoch,
      "owner_fencing_token" => envelope.owner_fencing_token,
      "admission_revision" => envelope.admission_revision,
      "status" => Atom.to_string(envelope.status),
      "quarantine_reason" => envelope.quarantine_reason,
      "provenance" => envelope.provenance,
      "authenticity" => envelope.authenticity,
      "emitted_at" => envelope.emitted_at,
      "admitted_at" => envelope.admitted_at,
      "admission_receipt" => envelope.admission_receipt
    }
  end

  @doc "Restores and verifies an envelope from decoded canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(data) when is_map(data) and not is_struct(data) do
    with :ok <- exact_data_keys(data),
         {:ok, event_class} <- class_from_data(Map.fetch!(data, "event_class")),
         {:ok, status} <- status_from_data(Map.fetch!(data, "status")),
         {:ok, continuation_ref} <- continuation_from_data(Map.fetch!(data, "continuation_ref")),
         {:ok, origin_ref} <-
           ref_from_data(
             Map.fetch!(data, "origin_definition_ref"),
             Map.fetch!(data, "origin_definition_canonicalization_version"),
             Map.fetch!(data, "origin_definition_contract_version")
           ),
         {:ok, owner_ref} <-
           ref_from_data(
             Map.fetch!(data, "owner_definition_ref"),
             Map.fetch!(data, "owner_definition_canonicalization_version"),
             Map.fetch!(data, "owner_definition_contract_version")
           ) do
      new(%{
        schema_version: Map.fetch!(data, "schema_version"),
        id: Map.fetch!(data, "id"),
        event_class: event_class,
        class_ref: Map.fetch!(data, "class_ref"),
        causation_id: Map.fetch!(data, "causation_id"),
        correlation_id: Map.fetch!(data, "correlation_id"),
        continuation_ref: continuation_ref,
        origin_definition_ref: origin_ref,
        owner_definition_ref: owner_ref,
        payload_schema_ref: Map.fetch!(data, "payload_schema_ref"),
        payload: Map.fetch!(data, "payload"),
        admitted_activation_generation: Map.fetch!(data, "admitted_activation_generation"),
        authority_epoch: Map.fetch!(data, "authority_epoch"),
        owner_fencing_token: Map.fetch!(data, "owner_fencing_token"),
        admission_revision: Map.fetch!(data, "admission_revision"),
        status: status,
        quarantine_reason: Map.fetch!(data, "quarantine_reason"),
        provenance: Map.fetch!(data, "provenance"),
        authenticity: Map.fetch!(data, "authenticity"),
        emitted_at: Map.fetch!(data, "emitted_at"),
        admitted_at: Map.fetch!(data, "admitted_at"),
        admission_receipt: Map.fetch!(data, "admission_receipt")
      })
    end
  end

  def from_data(value), do: {:error, {:invalid_event_envelope_data, shape(value)}}

  @doc "Encodes an envelope into canonical portable bytes."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = envelope), do: envelope |> to_data() |> Value.encode()

  @doc "Decodes and validates canonical Event Envelope bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_event_envelope_binary, shape(value)}}

  defp put_receipt(%__MODULE__{status: :pending} = envelope, nil), do: {:ok, envelope}

  defp put_receipt(%__MODULE__{status: :pending}, supplied),
    do: {:error, {:pending_event_has_admission_receipt, supplied}}

  defp put_receipt(%__MODULE__{} = envelope, supplied) do
    receipt = admission_receipt(envelope)

    if supplied in [nil, receipt],
      do: {:ok, %{envelope | admission_receipt: receipt}},
      else: {:error, {:event_admission_receipt_mismatch, supplied, receipt}}
  end

  defp admission_receipt(envelope) do
    envelope
    |> Map.from_struct()
    |> Map.put(:admission_receipt, nil)
    |> then(&struct!(__MODULE__, &1))
    |> to_data()
    |> Value.digest!()
  end

  defp validate_admission(%__MODULE__{status: :pending} = envelope) do
    fields = [
      envelope.owner_definition_ref,
      envelope.admitted_activation_generation,
      envelope.authority_epoch,
      envelope.owner_fencing_token,
      envelope.admission_revision,
      envelope.admitted_at,
      envelope.quarantine_reason
    ]

    if Enum.all?(fields, &is_nil/1), do: :ok, else: {:error, :pending_event_has_admission_fields}
  end

  defp validate_admission(%__MODULE__{status: status} = envelope) do
    with :ok <- optional_owner(status, envelope.owner_definition_ref),
         :ok <-
           non_negative(envelope.admitted_activation_generation, :admitted_activation_generation),
         :ok <- non_negative(envelope.authority_epoch, :authority_epoch),
         :ok <- positive(envelope.owner_fencing_token, :owner_fencing_token),
         :ok <- positive(envelope.admission_revision, :admission_revision),
         :ok <- non_negative(envelope.admitted_at, :admitted_at) do
      quarantine_fields(status, envelope.quarantine_reason)
    end
  end

  defp optional_owner(:admitted, %DefinitionRef{}), do: :ok
  defp optional_owner(:quarantined, nil), do: :ok
  defp optional_owner(:quarantined, %DefinitionRef{}), do: :ok
  defp optional_owner(status, value), do: {:error, {:invalid_event_owner, status, value}}

  defp quarantine_fields(:admitted, nil), do: :ok

  defp quarantine_fields(:admitted, value),
    do: {:error, {:admitted_event_has_quarantine_reason, value}}

  defp quarantine_fields(:quarantined, nil), do: {:error, :quarantined_event_requires_reason}
  defp quarantine_fields(:quarantined, value), do: portable(value, :quarantine_reason)

  defp validate_keys(attrs) do
    case Map.keys(attrs) -- @fields do
      [] -> :ok
      unknown -> {:error, {:unknown_event_envelope_fields, Enum.sort(unknown)}}
    end
  end

  defp exact_data_keys(data) do
    expected = MapSet.new(@data_fields)
    actual = data |> Map.keys() |> MapSet.new()

    if actual == expected,
      do: :ok,
      else: {:error, {:invalid_event_envelope_data_fields, Enum.sort(Map.keys(data))}}
  end

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(value), do: {:error, {:unsupported_event_envelope_schema, value}}

  defp validate_class(value) when value in @classes, do: :ok
  defp validate_class(value), do: {:error, {:invalid_event_class, value}}

  defp validate_status(value) when value in @statuses, do: :ok
  defp validate_status(value), do: {:error, {:invalid_event_status, value}}

  defp normalize_definition_ref(nil), do: {:ok, nil}

  defp normalize_definition_ref(%DefinitionRef{} = ref) do
    if DefinitionRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_event_definition_ref, ref}}
  end

  defp normalize_definition_ref(value), do: {:error, {:invalid_event_definition_ref, value}}

  defp normalize_continuation(nil), do: {:ok, nil}

  defp normalize_continuation(%RunRef{} = ref) do
    if valid_run_ref?(ref), do: {:ok, ref}, else: {:error, {:invalid_event_continuation, ref}}
  end

  defp normalize_continuation(%OperationRef{} = ref) do
    case OperationRef.validate(ref) do
      :ok -> {:ok, ref}
      {:error, reason} -> {:error, {:invalid_event_continuation, reason}}
    end
  end

  defp normalize_continuation(value), do: {:error, {:invalid_event_continuation, value}}

  defp valid_run_ref?(%RunRef{} = ref) do
    Enum.all?([
      nonempty_binary?(ref.run_id),
      is_integer(ref.revision) and ref.revision >= 0,
      ref.kind in [:reply, :policy, :invocation, :complete, :error],
      nonempty_binary?(ref.boundary_id),
      is_nil(ref.subject_id) or nonempty_binary?(ref.subject_id)
    ])
  end

  defp nonempty_binary?(value), do: is_binary(value) and value != ""

  defp continuation_to_data(nil), do: nil

  defp continuation_to_data(%RunRef{} = ref) do
    %{
      "type" => "run",
      "run_id" => ref.run_id,
      "revision" => ref.revision,
      "kind" => Atom.to_string(ref.kind),
      "boundary_id" => ref.boundary_id,
      "subject_id" => ref.subject_id
    }
  end

  defp continuation_to_data(%OperationRef{} = ref) do
    %{
      "type" => "operation",
      "id" => ref.id,
      "kind" => Atom.to_string(ref.kind),
      "subject_id" => ref.subject_id,
      "correlation_id" => ref.correlation_id
    }
  end

  defp continuation_from_data(nil), do: {:ok, nil}

  defp continuation_from_data(%{
         "type" => "run",
         "run_id" => run_id,
         "revision" => revision,
         "kind" => kind,
         "boundary_id" => boundary_id,
         "subject_id" => subject_id
       }) do
    with {:ok, kind} <- run_kind_from_data(kind),
         ref = %RunRef{
           run_id: run_id,
           revision: revision,
           kind: kind,
           boundary_id: boundary_id,
           subject_id: subject_id
         },
         true <- valid_run_ref?(ref) do
      {:ok, ref}
    else
      false -> {:error, :invalid_event_run_continuation}
      {:error, _reason} = error -> error
    end
  end

  defp continuation_from_data(%{
         "type" => "operation",
         "id" => id,
         "kind" => kind,
         "subject_id" => subject_id,
         "correlation_id" => correlation_id
       }) do
    with {:ok, kind} <- operation_kind_from_data(kind),
         ref = %OperationRef{
           id: id,
           kind: kind,
           subject_id: subject_id,
           correlation_id: correlation_id
         },
         :ok <- OperationRef.validate(ref) do
      {:ok, ref}
    end
  end

  defp continuation_from_data(value),
    do: {:error, {:invalid_event_continuation_data, shape(value)}}

  defp ref_from_data(nil, nil, nil), do: {:ok, nil}

  defp ref_from_data(value, canonicalization_version, contract_version)
       when is_binary(value) do
    DefinitionRef.parse(value,
      canonicalization_version: canonicalization_version,
      contract_version: contract_version
    )
  end

  defp ref_from_data(value, _canonicalization_version, _contract_version),
    do: {:error, {:invalid_event_definition_ref_data, value}}

  defp ref_string(nil), do: nil
  defp ref_string(%DefinitionRef{} = ref), do: DefinitionRef.to_string(ref)
  defp ref_version(nil, _field), do: nil
  defp ref_version(%DefinitionRef{} = ref, field), do: Map.fetch!(ref, field)

  defp default_class_ref(event_class) when event_class in @classes,
    do: "spectre.event/" <> Atom.to_string(event_class) <> "/1"

  defp default_class_ref(_event_class), do: nil

  defp class_from_data("input"), do: {:ok, :input}
  defp class_from_data("reply"), do: {:ok, :reply}
  defp class_from_data("policy_answer"), do: {:ok, :policy_answer}
  defp class_from_data("flow_progress"), do: {:ok, :flow_progress}
  defp class_from_data("flow_completion"), do: {:ok, :flow_completion}
  defp class_from_data("work_progress"), do: {:ok, :work_progress}
  defp class_from_data("work_completion"), do: {:ok, :work_completion}
  defp class_from_data("vigil_progress"), do: {:ok, :vigil_progress}
  defp class_from_data("vigil_completion"), do: {:ok, :vigil_completion}
  defp class_from_data("global"), do: {:ok, :global}
  defp class_from_data(value), do: {:error, {:invalid_event_class, value}}

  defp status_from_data("pending"), do: {:ok, :pending}
  defp status_from_data("admitted"), do: {:ok, :admitted}
  defp status_from_data("quarantined"), do: {:ok, :quarantined}
  defp status_from_data(value), do: {:error, {:invalid_event_status, value}}

  defp run_kind_from_data("reply"), do: {:ok, :reply}
  defp run_kind_from_data("policy"), do: {:ok, :policy}
  defp run_kind_from_data("invocation"), do: {:ok, :invocation}
  defp run_kind_from_data("complete"), do: {:ok, :complete}
  defp run_kind_from_data("error"), do: {:ok, :error}
  defp run_kind_from_data(value), do: {:error, {:invalid_event_run_kind, value}}

  defp operation_kind_from_data("work"), do: {:ok, :work}
  defp operation_kind_from_data("vigil"), do: {:ok, :vigil}
  defp operation_kind_from_data("directive"), do: {:ok, :directive}
  defp operation_kind_from_data(value), do: {:error, {:invalid_event_operation_kind, value}}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(value, field), do: {:error, {:invalid_event_field, field, value}}

  defp optional_binary(nil, _field), do: :ok
  defp optional_binary(value, field), do: nonempty(value, field)

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp non_negative(value, field), do: {:error, {:invalid_event_field, field, value}}

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(value, field), do: {:error, {:invalid_event_field, field, value}}

  defp portable(value, field) do
    case Value.validate(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_event_field, field, reason}}
    end
  end

  defp portable_map(value, field) when is_map(value) and not is_struct(value),
    do: portable(value, field)

  defp portable_map(value, field), do: {:error, {:invalid_event_field, field, shape(value)}}

  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
