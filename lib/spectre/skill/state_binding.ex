defmodule Spectre.Skill.StateBinding do
  @moduledoc """
  Portable, generation-fenced state owned by one stable Skill and Definition.

  A binding identifies one branch. Its schema, generation, parent branch and
  owning Definition are immutable; state updates use revision CAS. Activation
  may move a retained branch between `:active` and `:dormant`, while retention
  transitions are monotonic and a purged binding keeps only its tombstone.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref, as: DefinitionRef

  @schema_version 1
  @statuses [:active, :dormant]
  @retention_states [:retained, :gc_eligible, :abandoned, :purged]
  @fields [
    :schema_version,
    :skill_id,
    :state_schema_ref,
    :state_generation,
    :branch_id,
    :parent_branch_id,
    :owning_definition_ref,
    :revision,
    :fencing_token,
    :status,
    :retention,
    :state,
    :created_at,
    :updated_at,
    :provenance,
    :binding_receipt
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            skill_id: nil,
            state_schema_ref: nil,
            state_generation: nil,
            branch_id: nil,
            parent_branch_id: nil,
            owning_definition_ref: nil,
            revision: 0,
            fencing_token: nil,
            status: :active,
            retention: :retained,
            state: nil,
            created_at: nil,
            updated_at: nil,
            provenance: %{},
            binding_receipt: nil

  @type status :: :active | :dormant
  @type retention :: :retained | :gc_eligible | :abandoned | :purged
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          skill_id: String.t(),
          state_schema_ref: String.t(),
          state_generation: pos_integer(),
          branch_id: String.t(),
          parent_branch_id: String.t() | nil,
          owning_definition_ref: DefinitionRef.t(),
          revision: non_neg_integer(),
          fencing_token: pos_integer(),
          status: status(),
          retention: retention(),
          state: term(),
          created_at: non_neg_integer(),
          updated_at: non_neg_integer(),
          provenance: map(),
          binding_receipt: String.t()
        }

  @doc "Returns the Skill-state binding schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and verifies one Skill-state branch binding."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = binding), do: binding |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    now = Map.get(attrs, :created_at, System.system_time(:millisecond))

    attrs =
      attrs
      |> Map.put_new(:schema_version, @schema_version)
      |> Map.put_new(:branch_id, Spectre.Identity.uuid7())
      |> Map.put_new(:parent_branch_id, nil)
      |> Map.put_new(:revision, 0)
      |> Map.put_new(:status, :active)
      |> Map.put_new(:retention, :retained)
      |> Map.put_new(:state, nil)
      |> Map.put_new(:created_at, now)
      |> Map.put_new(:updated_at, now)
      |> Map.put_new(:provenance, %{})

    with :ok <- validate_keys(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version)),
         :ok <- nonempty(Map.get(attrs, :skill_id), :skill_id),
         :ok <- nonempty(Map.get(attrs, :state_schema_ref), :state_schema_ref),
         :ok <- positive(Map.get(attrs, :state_generation), :state_generation),
         :ok <- nonempty(Map.get(attrs, :branch_id), :branch_id),
         :ok <- optional_binary(Map.get(attrs, :parent_branch_id), :parent_branch_id),
         :ok <- distinct_parent(Map.get(attrs, :branch_id), Map.get(attrs, :parent_branch_id)),
         {:ok, definition_ref} <- normalize_definition_ref(Map.get(attrs, :owning_definition_ref)),
         :ok <- non_negative(Map.get(attrs, :revision), :revision),
         :ok <- positive(Map.get(attrs, :fencing_token), :fencing_token),
         :ok <- member(Map.get(attrs, :status), @statuses, :status),
         :ok <- member(Map.get(attrs, :retention), @retention_states, :retention),
         :ok <- portable(Map.get(attrs, :state), :state),
         :ok <- non_negative(Map.get(attrs, :created_at), :created_at),
         :ok <- non_negative(Map.get(attrs, :updated_at), :updated_at),
         :ok <- ordered_timestamps(Map.get(attrs, :created_at), Map.get(attrs, :updated_at)),
         :ok <- portable_map(Map.get(attrs, :provenance), :provenance),
         :ok <- valid_lifecycle(attrs) do
      base = %__MODULE__{
        schema_version: @schema_version,
        skill_id: Map.fetch!(attrs, :skill_id),
        state_schema_ref: Map.fetch!(attrs, :state_schema_ref),
        state_generation: Map.fetch!(attrs, :state_generation),
        branch_id: Map.fetch!(attrs, :branch_id),
        parent_branch_id: Map.fetch!(attrs, :parent_branch_id),
        owning_definition_ref: definition_ref,
        revision: Map.fetch!(attrs, :revision),
        fencing_token: Map.fetch!(attrs, :fencing_token),
        status: Map.fetch!(attrs, :status),
        retention: Map.fetch!(attrs, :retention),
        state: Map.fetch!(attrs, :state),
        created_at: Map.fetch!(attrs, :created_at),
        updated_at: Map.fetch!(attrs, :updated_at),
        provenance: Map.fetch!(attrs, :provenance),
        binding_receipt: nil
      }

      receipt = receipt(base)

      case Map.get(attrs, :binding_receipt, receipt) do
        ^receipt -> {:ok, %{base | binding_receipt: receipt}}
        supplied -> {:error, {:skill_state_binding_receipt_mismatch, supplied, receipt}}
      end
    end
  end

  def new(value), do: {:error, {:invalid_skill_state_binding, shape(value)}}

  @doc "Builds a binding or raises with its stable validation reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, binding} -> binding
      {:error, reason} -> raise ArgumentError, "invalid Skill state binding: #{inspect(reason)}"
    end
  end

  @doc "Updates the active branch state through generation and revision CAS."
  @spec update(t(), term(), keyword()) :: {:ok, t()} | {:error, term()}
  def update(%__MODULE__{} = binding, state, opts) when is_list(opts) do
    with :ok <- mutable(binding),
         :ok <- expected_generation(binding, Keyword.get(opts, :expected_generation)),
         :ok <- expected_revision(binding, Keyword.get(opts, :expected_revision)),
         :ok <- expected_schema(binding, Keyword.get(opts, :state_schema_ref)),
         :ok <- expected_owner(binding, Keyword.get(opts, :owning_definition_ref)),
         {:ok, fencing_token} <- next_fencing_token(binding, opts) do
      rebuild(binding,
        state: state,
        revision: binding.revision + 1,
        fencing_token: fencing_token,
        updated_at: Keyword.get(opts, :updated_at, System.system_time(:millisecond)),
        provenance: Keyword.get(opts, :provenance, binding.provenance)
      )
    end
  end

  def update(%__MODULE__{}, _state, opts),
    do: {:error, {:invalid_skill_state_options, shape(opts)}}

  @doc "Moves a retained branch between active and dormant with revision CAS."
  @spec transition_status(t(), status(), keyword()) :: {:ok, t()} | {:error, term()}
  def transition_status(%__MODULE__{} = binding, status, opts)
      when status in @statuses and is_list(opts) do
    with :ok <- expected_revision(binding, Keyword.get(opts, :expected_revision)),
         :ok <- retained(binding),
         {:ok, fencing_token} <- next_fencing_token(binding, opts) do
      if binding.status == status do
        {:ok, binding}
      else
        rebuild(binding,
          status: status,
          revision: binding.revision + 1,
          fencing_token: fencing_token,
          updated_at: Keyword.get(opts, :updated_at, System.system_time(:millisecond)),
          provenance: Keyword.get(opts, :provenance, binding.provenance)
        )
      end
    end
  end

  def transition_status(%__MODULE__{}, status, _opts),
    do: {:error, {:invalid_skill_state_status, status}}

  @doc "Applies a monotonic retention transition and preserves a purged tombstone."
  @spec transition_retention(t(), retention(), keyword()) :: {:ok, t()} | {:error, term()}
  def transition_retention(%__MODULE__{} = binding, retention, opts)
      when retention in @retention_states and is_list(opts) do
    with :ok <- expected_revision(binding, Keyword.get(opts, :expected_revision)),
         :ok <- legal_retention(binding, retention),
         {:ok, fencing_token} <- next_fencing_token(binding, opts) do
      if binding.retention == retention do
        {:ok, binding}
      else
        rebuild(binding,
          status: :dormant,
          retention: retention,
          state: if(retention == :purged, do: nil, else: binding.state),
          revision: binding.revision + 1,
          fencing_token: fencing_token,
          updated_at: Keyword.get(opts, :updated_at, System.system_time(:millisecond)),
          provenance: Keyword.get(opts, :provenance, binding.provenance)
        )
      end
    end
  end

  def transition_retention(%__MODULE__{}, retention, _opts),
    do: {:error, {:invalid_skill_state_retention, retention}}

  @doc "Returns the immutable pointer stored in an Activation snapshot."
  @spec activation_pointer(t()) :: map()
  def activation_pointer(%__MODULE__{} = binding) do
    %{
      "kind" => "skill_state",
      "skill_id" => binding.skill_id,
      "state_schema_ref" => binding.state_schema_ref,
      "state_generation" => binding.state_generation,
      "branch_id" => binding.branch_id,
      "owning_definition_ref" => DefinitionRef.to_string(binding.owning_definition_ref)
    }
  end

  @doc "Returns true for an Activation Skill-state pointer."
  @spec activation_pointer?(term()) :: boolean()
  def activation_pointer?(%{"kind" => "skill_state"}), do: true
  def activation_pointer?(_value), do: false

  @doc "Returns portable canonical data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = binding), do: data(binding, binding.binding_receipt)

  defp data(binding, binding_receipt) do
    %{
      "schema_version" => binding.schema_version,
      "skill_id" => binding.skill_id,
      "state_schema_ref" => binding.state_schema_ref,
      "state_generation" => binding.state_generation,
      "branch_id" => binding.branch_id,
      "parent_branch_id" => binding.parent_branch_id,
      "owning_definition_ref" => DefinitionRef.to_string(binding.owning_definition_ref),
      "definition_canonicalization_version" =>
        binding.owning_definition_ref.canonicalization_version,
      "definition_contract_version" => binding.owning_definition_ref.contract_version,
      "revision" => binding.revision,
      "fencing_token" => binding.fencing_token,
      "status" => Atom.to_string(binding.status),
      "retention" => Atom.to_string(binding.retention),
      "state" => binding.state,
      "created_at" => binding.created_at,
      "updated_at" => binding.updated_at,
      "provenance" => binding.provenance,
      "binding_receipt" => binding_receipt
    }
  end

  @doc "Restores portable binding data without creating atoms."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{
        "schema_version" => schema_version,
        "skill_id" => skill_id,
        "state_schema_ref" => state_schema_ref,
        "state_generation" => state_generation,
        "branch_id" => branch_id,
        "parent_branch_id" => parent_branch_id,
        "owning_definition_ref" => definition_ref,
        "definition_canonicalization_version" => canonicalization_version,
        "definition_contract_version" => contract_version,
        "revision" => revision,
        "fencing_token" => fencing_token,
        "status" => status,
        "retention" => retention,
        "state" => state,
        "created_at" => created_at,
        "updated_at" => updated_at,
        "provenance" => provenance,
        "binding_receipt" => binding_receipt
      }) do
    with {:ok, definition_ref} <-
           DefinitionRef.parse(definition_ref,
             canonicalization_version: canonicalization_version,
             contract_version: contract_version
           ),
         {:ok, status} <- status_from_data(status),
         {:ok, retention} <- retention_from_data(retention) do
      new(%{
        schema_version: schema_version,
        skill_id: skill_id,
        state_schema_ref: state_schema_ref,
        state_generation: state_generation,
        branch_id: branch_id,
        parent_branch_id: parent_branch_id,
        owning_definition_ref: definition_ref,
        revision: revision,
        fencing_token: fencing_token,
        status: status,
        retention: retention,
        state: state,
        created_at: created_at,
        updated_at: updated_at,
        provenance: provenance,
        binding_receipt: binding_receipt
      })
    end
  end

  def from_data(value), do: {:error, {:invalid_skill_state_binding_data, shape(value)}}

  @doc "Encodes a binding into portable canonical bytes."
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = binding), do: binding |> to_data() |> Value.encode()

  @doc "Decodes and verifies portable binding bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_skill_state_binding_binary, shape(value)}}

  defp rebuild(binding, changes) do
    binding
    |> Map.from_struct()
    |> Map.merge(Map.new(changes))
    |> Map.delete(:binding_receipt)
    |> new()
  end

  defp receipt(binding) do
    binding
    |> data(nil)
    |> Value.digest!()
    |> then(&("skill-state:sha256:" <> &1))
  end

  defp validate_keys(attrs) do
    case Map.keys(attrs) -- @fields do
      [] -> :ok
      unknown -> {:error, {:unknown_skill_state_binding_fields, Enum.sort(unknown)}}
    end
  end

  defp valid_lifecycle(%{status: :active, retention: :retained}), do: :ok
  defp valid_lifecycle(%{status: :dormant, retention: :retained}), do: :ok

  defp valid_lifecycle(%{status: :dormant, retention: retention, state: nil})
       when retention == :purged,
       do: :ok

  defp valid_lifecycle(%{status: :dormant, retention: retention})
       when retention in [:gc_eligible, :abandoned],
       do: :ok

  defp valid_lifecycle(attrs),
    do: {:error, {:invalid_skill_state_lifecycle, attrs.status, attrs.retention}}

  defp mutable(%__MODULE__{status: :active, retention: :retained}), do: :ok

  defp mutable(binding),
    do: {:error, {:skill_state_not_mutable, binding.status, binding.retention}}

  defp retained(%__MODULE__{retention: :retained}), do: :ok
  defp retained(binding), do: {:error, {:skill_state_not_retained, binding.retention}}

  defp expected_generation(%__MODULE__{state_generation: generation}, generation), do: :ok

  defp expected_generation(binding, expected),
    do: {:error, {:stale_skill_state_generation, expected, binding.state_generation}}

  defp expected_revision(%__MODULE__{revision: revision}, revision), do: :ok

  defp expected_revision(binding, expected),
    do: {:error, {:stale_skill_state_revision, expected, binding.revision}}

  defp expected_schema(_binding, nil), do: {:error, :skill_state_schema_ref_required}
  defp expected_schema(binding, schema) when schema == binding.state_schema_ref, do: :ok

  defp expected_schema(binding, schema),
    do: {:error, {:skill_state_schema_violation, schema, binding.state_schema_ref}}

  defp expected_owner(_binding, nil), do: {:error, :skill_state_owner_required}

  defp expected_owner(binding, %DefinitionRef{} = definition_ref) do
    if DefinitionRef.to_string(definition_ref) ==
         DefinitionRef.to_string(binding.owning_definition_ref),
       do: :ok,
       else: {:error, {:skill_state_owner_violation, DefinitionRef.to_string(definition_ref)}}
  end

  defp expected_owner(_binding, value), do: {:error, {:invalid_skill_state_owner, value}}

  defp next_fencing_token(binding, opts) do
    case Keyword.get(opts, :fencing_token) do
      value when is_integer(value) and value >= binding.fencing_token -> {:ok, value}
      value -> {:error, {:stale_skill_state_fence, value, binding.fencing_token}}
    end
  end

  defp legal_retention(binding, retention) when binding.retention == retention, do: :ok

  defp legal_retention(%__MODULE__{status: :active}, _retention),
    do: {:error, :active_skill_state}

  defp legal_retention(%__MODULE__{retention: :retained}, :gc_eligible), do: :ok
  defp legal_retention(%__MODULE__{retention: :retained}, :abandoned), do: :ok
  defp legal_retention(%__MODULE__{retention: :abandoned}, :gc_eligible), do: :ok
  defp legal_retention(%__MODULE__{retention: :gc_eligible}, :purged), do: :ok

  defp legal_retention(binding, retention),
    do: {:error, {:invalid_skill_state_retention_transition, binding.retention, retention}}

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(value), do: {:error, {:unsupported_skill_state_binding_schema, value}}

  defp normalize_definition_ref(%DefinitionRef{} = ref) do
    if DefinitionRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_skill_state_definition_ref, ref}}
  end

  defp normalize_definition_ref(value),
    do: {:error, {:invalid_skill_state_definition_ref, value}}

  defp distinct_parent(branch_id, branch_id), do: {:error, :skill_state_self_parent}
  defp distinct_parent(_branch_id, _parent_branch_id), do: :ok

  defp ordered_timestamps(created_at, updated_at) when updated_at >= created_at, do: :ok

  defp ordered_timestamps(created_at, updated_at),
    do: {:error, {:invalid_skill_state_timestamps, created_at, updated_at}}

  defp nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  defp nonempty(value, field), do: {:error, {:invalid_skill_state_field, field, value}}

  defp optional_binary(nil, _field), do: :ok
  defp optional_binary(value, field), do: nonempty(value, field)

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(value, field), do: {:error, {:invalid_skill_state_field, field, value}}

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok
  defp non_negative(value, field), do: {:error, {:invalid_skill_state_field, field, value}}

  defp member(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, {:invalid_skill_state_field, field, value}}
  end

  defp portable(value, field) do
    case Value.validate(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_skill_state_field, field, reason}}
    end
  end

  defp portable_map(value, field) when is_map(value) and not is_struct(value),
    do: portable(value, field)

  defp portable_map(value, field),
    do: {:error, {:invalid_skill_state_field, field, shape(value)}}

  defp status_from_data("active"), do: {:ok, :active}
  defp status_from_data("dormant"), do: {:ok, :dormant}
  defp status_from_data(value), do: {:error, {:invalid_skill_state_status, value}}

  defp retention_from_data("retained"), do: {:ok, :retained}
  defp retention_from_data("gc_eligible"), do: {:ok, :gc_eligible}
  defp retention_from_data("abandoned"), do: {:ok, :abandoned}
  defp retention_from_data("purged"), do: {:ok, :purged}
  defp retention_from_data(value), do: {:error, {:invalid_skill_state_retention, value}}

  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
