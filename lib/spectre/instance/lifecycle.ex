defmodule Spectre.Instance.Lifecycle do
  @moduledoc """
  Independent admission, authority, retention and activation axes for a Definition.

  A saved Run authority epoch is lineage only. Authorization always consults
  the current lifecycle record at admission, commit or dispatch time.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Instance.Activation

  @schema_version 1
  @admission_states [:accepting, :draining, :closed]
  @authority_states [:granted, :restricted, :revoked]
  @retention_states [:retained, :gc_eligible, :purged]
  @activation_states [:active, :inactive]
  @axes [:admission, :authority, :retention, :activation]

  @enforce_keys [
    :schema_version,
    :definition_ref,
    :admission,
    :authority,
    :retention,
    :activation,
    :authority_epoch,
    :revision,
    :changed_at,
    :provenance
  ]
  defstruct schema_version: @schema_version,
            definition_ref: nil,
            admission: :accepting,
            authority: :granted,
            retention: :retained,
            activation: :inactive,
            authority_epoch: 0,
            revision: 0,
            changed_at: nil,
            reason: nil,
            provenance: %{}

  @type axis :: :admission | :authority | :retention | :activation
  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          definition_ref: DefinitionRef.t(),
          admission: :accepting | :draining | :closed,
          authority: :granted | :restricted | :revoked,
          retention: :retained | :gc_eligible | :purged,
          activation: :active | :inactive,
          authority_epoch: non_neg_integer(),
          revision: non_neg_integer(),
          changed_at: non_neg_integer(),
          reason: term(),
          provenance: map()
        }

  @doc "Returns the lifecycle schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and validates a Definition lifecycle record."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = lifecycle), do: lifecycle |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    attrs =
      attrs
      |> Map.put_new(:schema_version, @schema_version)
      |> Map.put_new(:admission, :accepting)
      |> Map.put_new(:authority, :granted)
      |> Map.put_new(:retention, :retained)
      |> Map.put_new(:activation, :inactive)
      |> Map.put_new(:authority_epoch, 0)
      |> Map.put_new(:revision, 0)
      |> Map.put_new(:changed_at, System.system_time(:millisecond))
      |> Map.put_new(:reason, nil)
      |> Map.put_new(:provenance, %{})

    with :ok <- validate_keys(attrs),
         :ok <- validate_schema(Map.get(attrs, :schema_version)),
         {:ok, definition_ref} <- normalize_ref(Map.get(attrs, :definition_ref)),
         :ok <- member(Map.get(attrs, :admission), @admission_states, :admission),
         :ok <- member(Map.get(attrs, :authority), @authority_states, :authority),
         :ok <- member(Map.get(attrs, :retention), @retention_states, :retention),
         :ok <- member(Map.get(attrs, :activation), @activation_states, :activation),
         :ok <- non_negative(Map.get(attrs, :authority_epoch), :authority_epoch),
         :ok <- non_negative(Map.get(attrs, :revision), :revision),
         :ok <- non_negative(Map.get(attrs, :changed_at), :changed_at),
         :ok <- portable(Map.get(attrs, :reason), :reason),
         :ok <- portable_map(Map.get(attrs, :provenance), :provenance) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         definition_ref: definition_ref,
         admission: Map.fetch!(attrs, :admission),
         authority: Map.fetch!(attrs, :authority),
         retention: Map.fetch!(attrs, :retention),
         activation: Map.fetch!(attrs, :activation),
         authority_epoch: Map.fetch!(attrs, :authority_epoch),
         revision: Map.fetch!(attrs, :revision),
         changed_at: Map.fetch!(attrs, :changed_at),
         reason: Map.fetch!(attrs, :reason),
         provenance: Map.fetch!(attrs, :provenance)
       }}
    end
  end

  def new(value), do: {:error, {:invalid_definition_lifecycle, shape(value)}}

  @doc "Builds a lifecycle record or raises with its stable reason."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, lifecycle} -> lifecycle
      {:error, reason} -> raise ArgumentError, "invalid Definition lifecycle: #{inspect(reason)}"
    end
  end

  @doc "Builds the initial active lifecycle represented by an Activation."
  @spec from_activation(Activation.t()) :: t()
  def from_activation(%Activation{} = activation) do
    new!(
      definition_ref: activation.definition_ref,
      activation: :active,
      authority_epoch: activation.authority_epoch,
      changed_at: activation.activated_at,
      provenance: %{source: :activation, activation_receipt: activation.activation_receipt}
    )
  end

  @doc "Returns the stable map key for a Definition lifecycle."
  @spec key(DefinitionRef.t() | t()) :: String.t()
  def key(%__MODULE__{definition_ref: ref}), do: key(ref)
  def key(%DefinitionRef{} = ref), do: DefinitionRef.to_string(ref)

  @doc "Fetches a lifecycle or returns a safe default for a known Definition."
  @spec fetch(map(), DefinitionRef.t(), keyword()) :: t()
  def fetch(lifecycles, %DefinitionRef{} = ref, opts \\ []) when is_map(lifecycles) do
    case Map.get(lifecycles, key(ref)) do
      %__MODULE__{} = lifecycle -> lifecycle
      nil -> new!(definition_ref: ref, activation: Keyword.get(opts, :activation, :inactive))
    end
  end

  @doc "Transitions one axis through revision CAS and monotonic safety rules."
  @spec transition(t(), axis(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def transition(lifecycle, axis, value, opts \\ [])

  def transition(%__MODULE__{} = lifecycle, axis, value, opts)
      when axis in @axes and is_list(opts) do
    expected = Keyword.get(opts, :expected_revision, lifecycle.revision)

    with :ok <- expected_revision(lifecycle, expected) do
      transition_value(lifecycle, axis, value, opts)
    end
  end

  def transition(%__MODULE__{}, axis, value, _opts),
    do: {:error, {:invalid_definition_lifecycle_transition, axis, value}}

  @doc "Checks current-time lifecycle authority for a runtime operation."
  @spec authorize(t(), :new_admission | :continuation | :dispatch | :commit) ::
          :ok | {:error, term()}
  def authorize(%__MODULE__{} = lifecycle, operation) do
    with :ok <- authorize_retention(lifecycle),
         :ok <- authorize_authority(lifecycle, operation) do
      authorize_admission(lifecycle, operation)
    end
  end

  @doc "Moves the active lifecycle fence atomically for a Definition Activation."
  @spec activate(map(), Activation.t() | nil, Activation.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def activate(lifecycles, current, %Activation{} = next, opts \\ [])
      when is_map(lifecycles) and is_list(opts) do
    changed_at = Keyword.get(opts, :changed_at, next.activated_at)
    provenance = %{source: :activation, activation_receipt: next.activation_receipt}

    with {:ok, lifecycles} <- deactivate_current(lifecycles, current, next, changed_at),
         {:ok, target} <- activation_target(lifecycles, next),
         {:ok, target} <-
           transition(target, :admission, :accepting,
             authorize_reopen?: true,
             changed_at: changed_at,
             provenance: provenance
           ),
         {:ok, target} <-
           transition(target, :activation, :active,
             changed_at: changed_at,
             provenance: provenance
           ) do
      {:ok, Map.put(lifecycles, key(target), target)}
    end
  end

  @doc "Returns portable lifecycle data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = lifecycle) do
    %{
      "schema_version" => lifecycle.schema_version,
      "definition_ref" => DefinitionRef.to_string(lifecycle.definition_ref),
      "definition_canonicalization_version" => lifecycle.definition_ref.canonicalization_version,
      "definition_contract_version" => lifecycle.definition_ref.contract_version,
      "admission" => Atom.to_string(lifecycle.admission),
      "authority" => Atom.to_string(lifecycle.authority),
      "retention" => Atom.to_string(lifecycle.retention),
      "activation" => Atom.to_string(lifecycle.activation),
      "authority_epoch" => lifecycle.authority_epoch,
      "revision" => lifecycle.revision,
      "changed_at" => lifecycle.changed_at,
      "reason" => lifecycle.reason,
      "provenance" => lifecycle.provenance
    }
  end

  @doc "Restores lifecycle data without creating atoms."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{
        "schema_version" => schema_version,
        "definition_ref" => definition_ref,
        "definition_canonicalization_version" => canonicalization_version,
        "definition_contract_version" => contract_version,
        "admission" => admission,
        "authority" => authority,
        "retention" => retention,
        "activation" => activation,
        "authority_epoch" => authority_epoch,
        "revision" => revision,
        "changed_at" => changed_at,
        "reason" => reason,
        "provenance" => provenance
      }) do
    with {:ok, definition_ref} <-
           DefinitionRef.parse(definition_ref,
             canonicalization_version: canonicalization_version,
             contract_version: contract_version
           ),
         {:ok, admission} <- admission_from_data(admission),
         {:ok, authority} <- authority_from_data(authority),
         {:ok, retention} <- retention_from_data(retention),
         {:ok, activation} <- activation_from_data(activation) do
      new(%{
        schema_version: schema_version,
        definition_ref: definition_ref,
        admission: admission,
        authority: authority,
        retention: retention,
        activation: activation,
        authority_epoch: authority_epoch,
        revision: revision,
        changed_at: changed_at,
        reason: reason,
        provenance: provenance
      })
    end
  end

  def from_data(value), do: {:error, {:invalid_definition_lifecycle_data, shape(value)}}

  defp expected_revision(%__MODULE__{revision: revision}, revision), do: :ok

  defp expected_revision(%__MODULE__{revision: actual}, expected),
    do: {:error, {:stale_definition_lifecycle, expected, actual}}

  defp transition_value(lifecycle, axis, value, opts) do
    if Map.fetch!(lifecycle, axis) == value,
      do: {:ok, lifecycle},
      else: apply_transition(lifecycle, axis, value, opts)
  end

  defp apply_transition(lifecycle, axis, value, opts) do
    with :ok <- legal_transition(lifecycle, axis, value, opts),
         {:ok, authority_epoch} <- next_authority_epoch(lifecycle, axis, value, opts) do
      attrs =
        lifecycle
        |> Map.from_struct()
        |> Map.put(axis, value)
        |> Map.put(:authority_epoch, authority_epoch)
        |> Map.put(:revision, lifecycle.revision + 1)
        |> Map.put(
          :changed_at,
          Keyword.get(opts, :changed_at, System.system_time(:millisecond))
        )
        |> Map.put(:reason, Keyword.get(opts, :reason))
        |> Map.put(:provenance, Keyword.get(opts, :provenance, %{}))

      new(attrs)
    end
  end

  defp authorize_retention(%__MODULE__{retention: :purged} = lifecycle),
    do: {:error, {:definition_retention_purged, key(lifecycle)}}

  defp authorize_retention(%__MODULE__{}), do: :ok

  defp authorize_authority(%__MODULE__{authority: :revoked} = lifecycle, operation) do
    {:error,
     {:definition_authority_revoked, key(lifecycle), lifecycle.authority_epoch, operation}}
  end

  defp authorize_authority(%__MODULE__{authority: :restricted} = lifecycle, operation)
       when operation in [:new_admission, :dispatch] do
    {:error,
     {:definition_authority_restricted, key(lifecycle), lifecycle.authority_epoch, operation}}
  end

  defp authorize_authority(%__MODULE__{}, _operation), do: :ok

  defp authorize_admission(%__MODULE__{activation: activation} = lifecycle, :new_admission)
       when activation != :active,
       do: {:error, {:definition_not_active, key(lifecycle)}}

  defp authorize_admission(%__MODULE__{admission: admission} = lifecycle, :new_admission)
       when admission != :accepting,
       do: {:error, {:definition_admission_blocked, key(lifecycle), admission}}

  defp authorize_admission(%__MODULE__{admission: :closed} = lifecycle, :continuation),
    do: {:error, {:definition_continuation_closed, key(lifecycle)}}

  defp authorize_admission(%__MODULE__{}, _operation), do: :ok

  defp legal_transition(lifecycle, axis, value, opts) do
    current = Map.fetch!(lifecycle, axis)

    cond do
      current == value -> :ok
      axis == :admission -> legal_admission(current, value, opts)
      axis == :authority -> legal_authority(current, value, opts)
      axis == :retention -> legal_retention(current, value)
      axis == :activation -> member(value, @activation_states, :activation)
    end
  end

  defp legal_admission(:accepting, value, _opts) when value in [:draining, :closed], do: :ok
  defp legal_admission(:draining, :closed, _opts), do: :ok
  defp legal_admission(:draining, :accepting, opts), do: authorized?(opts, :authorize_reopen?)

  defp legal_admission(current, value, _opts),
    do: {:error, {:invalid_admission_transition, current, value}}

  defp legal_authority(:granted, value, _opts) when value in [:restricted, :revoked], do: :ok
  defp legal_authority(:restricted, :revoked, _opts), do: :ok
  defp legal_authority(:restricted, :granted, opts), do: authorized?(opts, :authorize_restore?)

  defp legal_authority(current, value, _opts),
    do: {:error, {:invalid_authority_transition, current, value}}

  defp legal_retention(:retained, :gc_eligible), do: :ok
  defp legal_retention(:gc_eligible, :purged), do: :ok

  defp legal_retention(current, value),
    do: {:error, {:invalid_retention_transition, current, value}}

  defp authorized?(opts, key) do
    if Keyword.get(opts, key, false),
      do: :ok,
      else: {:error, {:lifecycle_transition_not_authorized, key}}
  end

  defp next_authority_epoch(lifecycle, :authority, value, opts)
       when value != lifecycle.authority do
    supplied = Keyword.get(opts, :authority_epoch, lifecycle.authority_epoch + 1)

    if is_integer(supplied) and supplied > lifecycle.authority_epoch,
      do: {:ok, supplied},
      else: {:error, {:stale_lifecycle_authority_epoch, supplied, lifecycle.authority_epoch}}
  end

  defp next_authority_epoch(lifecycle, _axis, _value, _opts),
    do: {:ok, lifecycle.authority_epoch}

  defp deactivate_current(lifecycles, nil, _next, _changed_at), do: {:ok, lifecycles}

  defp deactivate_current(
         lifecycles,
         %Activation{definition_ref: definition_ref},
         %Activation{definition_ref: definition_ref},
         _changed_at
       ),
       do: {:ok, lifecycles}

  defp deactivate_current(lifecycles, %Activation{} = current, _next, changed_at) do
    lifecycle = fetch(lifecycles, current.definition_ref, activation: :active)
    provenance = %{source: :activation, transition: :definition_deactivated}

    with {:ok, lifecycle} <-
           transition(lifecycle, :activation, :inactive,
             changed_at: changed_at,
             provenance: provenance
           ),
         {:ok, lifecycle} <-
           transition(lifecycle, :admission, :draining,
             changed_at: changed_at,
             provenance: provenance
           ) do
      {:ok, Map.put(lifecycles, key(lifecycle), lifecycle)}
    end
  end

  defp activation_target(lifecycles, %Activation{} = activation) do
    case Map.get(lifecycles, key(activation.definition_ref)) do
      nil ->
        {:ok, from_activation(activation)}

      %__MODULE__{authority: :revoked} = lifecycle ->
        {:error,
         {:definition_authority_revoked, key(lifecycle), lifecycle.authority_epoch, :activation}}

      %__MODULE__{retention: :purged} = lifecycle ->
        {:error, {:definition_retention_purged, key(lifecycle)}}

      %__MODULE__{} = lifecycle ->
        if lifecycle.authority_epoch >= activation.authority_epoch do
          {:ok, lifecycle}
        else
          new(%{lifecycle | authority_epoch: activation.authority_epoch})
        end
    end
  end

  defp validate_keys(attrs) do
    allowed = [
      :schema_version,
      :definition_ref,
      :admission,
      :authority,
      :retention,
      :activation,
      :authority_epoch,
      :revision,
      :changed_at,
      :reason,
      :provenance
    ]

    case Map.keys(attrs) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_definition_lifecycle_fields, Enum.sort(unknown)}}
    end
  end

  defp normalize_ref(%DefinitionRef{} = ref) do
    if DefinitionRef.valid?(ref),
      do: {:ok, ref},
      else: {:error, {:invalid_lifecycle_definition_ref, ref}}
  end

  defp normalize_ref(value), do: {:error, {:invalid_lifecycle_definition_ref, value}}

  defp validate_schema(@schema_version), do: :ok
  defp validate_schema(value), do: {:error, {:unsupported_definition_lifecycle_schema, value}}

  defp member(value, allowed, field) do
    if value in allowed,
      do: :ok,
      else: {:error, {:invalid_definition_lifecycle_field, field, value}}
  end

  defp non_negative(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp non_negative(value, field),
    do: {:error, {:invalid_definition_lifecycle_field, field, value}}

  defp portable(value, field) do
    case Value.validate(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_definition_lifecycle_field, field, reason}}
    end
  end

  defp portable_map(value, field) when is_map(value) and not is_struct(value),
    do: portable(value, field)

  defp portable_map(value, field),
    do: {:error, {:invalid_definition_lifecycle_field, field, shape(value)}}

  defp admission_from_data("accepting"), do: {:ok, :accepting}
  defp admission_from_data("draining"), do: {:ok, :draining}
  defp admission_from_data("closed"), do: {:ok, :closed}

  defp admission_from_data(value),
    do: {:error, {:invalid_definition_lifecycle_field, :admission, value}}

  defp authority_from_data("granted"), do: {:ok, :granted}
  defp authority_from_data("restricted"), do: {:ok, :restricted}
  defp authority_from_data("revoked"), do: {:ok, :revoked}

  defp authority_from_data(value),
    do: {:error, {:invalid_definition_lifecycle_field, :authority, value}}

  defp retention_from_data("retained"), do: {:ok, :retained}
  defp retention_from_data("gc_eligible"), do: {:ok, :gc_eligible}
  defp retention_from_data("purged"), do: {:ok, :purged}

  defp retention_from_data(value),
    do: {:error, {:invalid_definition_lifecycle_field, :retention, value}}

  defp activation_from_data("active"), do: {:ok, :active}
  defp activation_from_data("inactive"), do: {:ok, :inactive}

  defp activation_from_data(value),
    do: {:error, {:invalid_definition_lifecycle_field, :activation, value}}

  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
