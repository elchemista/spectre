defmodule Spectre.Execution.Migration do
  @moduledoc """
  Prepare/commit protocol for registered, pure Work state migrations.

  Authored data selects only an operation ID already present in the Agent's
  reviewed registry. `prepare/4` resolves and snapshots its portable contract;
  the host executes the returned request through its normal operation boundary;
  `commit/3` re-resolves the contract and validates the migrated state before
  issuing an integrity receipt.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Execution.Migration.Receipt
  alias Spectre.Execution.Program
  alias Spectre.Operation.Execution
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Request
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Validator

  @schema_version 1

  @enforce_keys [
    :program,
    :source_version,
    :target_version,
    :source_state,
    :source_state_digest,
    :operation_ref,
    :operation_contract_digest,
    :request,
    :digest
  ]
  defstruct schema_version: @schema_version,
            program: nil,
            source_version: nil,
            target_version: nil,
            source_state: nil,
            source_state_digest: nil,
            operation_ref: nil,
            operation_contract_digest: nil,
            request: nil,
            digest: nil

  @type t :: %__MODULE__{}

  @doc "Prepares one declared migration without executing its operation."
  @spec prepare(Program.t(), term(), term(), module()) :: {:ok, t()} | {:error, term()}
  def prepare(%Program{} = program, source_version, source_state, agent)
      when is_atom(agent) and not is_nil(agent) do
    with {:ok, program} <- Program.new(program),
         {:ok, migration} <- declared_migration(program, source_version),
         :ok <- Value.validate(source_state),
         {:ok, registered_id} <- Registry.resolve_id(agent, migration.operation_ref),
         {:ok, spec} <-
           Registry.resolve(agent, Program.operation_definition(program), migration.operation_ref),
         :ok <- pure_migration(spec, migration),
         input <- %{
           schema_version: 1,
           program_digest: program.digest,
           from: migration.from,
           to: migration.to,
           state: source_state
         },
         :ok <- Validator.validate(spec.input, input, {:execution_migration_input, spec.id}),
         {:ok, source_digest} <- Value.digest(source_state) do
      contract_digest = spec_digest(spec)

      request =
        Request.new(registered_id, input,
          id:
            migration_request_id(
              program.digest,
              migration.from,
              source_digest,
              contract_digest
            ),
          phase: :state_migration,
          branch: program.id,
          metadata: %{
            execution_program_digest: program.digest,
            execution_migration_from: migration.from,
            execution_migration_to: migration.to,
            operation_contract_digest: contract_digest
          }
        )

      base = %{
        schema_version: @schema_version,
        program: program,
        source_version: migration.from,
        target_version: migration.to,
        source_state: source_state,
        source_state_digest: source_digest,
        operation_ref: registered_id,
        operation_contract_digest: contract_digest,
        request: request
      }

      digest = base |> identity_data() |> Value.digest!()
      {:ok, struct!(__MODULE__, Map.put(base, :digest, digest))}
    else
      {:error, {:unsupported_canonical_value, _path, _kind} = reason} ->
        {:error, {:nonportable_execution_migration_state, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  def prepare(%Program{}, _source_version, _source_state, agent),
    do: {:error, {:invalid_execution_migration_agent, agent}}

  @doc "Commits an already executed migration after revalidating its exact contract."
  @spec commit(t(), Execution.t(), module()) ::
          {:ok, term(), Receipt.t()} | {:error, term()}
  def commit(%__MODULE__{} = migration, %Execution{} = execution, agent)
      when is_atom(agent) and not is_nil(agent) do
    with :ok <- verify(migration),
         definition <- Program.operation_definition(migration.program),
         {:ok, spec} <- Registry.resolve(agent, definition, migration.operation_ref),
         :ok <- pure_migration(spec, %{operation_ref: migration.operation_ref}),
         true <- spec_digest(spec) == migration.operation_contract_digest,
         :ok <- Execution.validate(execution),
         :ok <-
           Validator.validate(
             spec.output,
             execution.value,
             {:execution_migration_output, spec.id}
           ),
         :ok <-
           Validator.domain(spec.domain, execution.value, {:execution_migration_domain, spec.id}),
         :ok <- Program.validate_state(migration.program, execution.value),
         {:ok, target_digest} <- Value.digest(execution.value),
         {:ok, receipt} <- migration_receipt(migration, execution, target_digest) do
      {:ok, execution.value, receipt}
    else
      false -> {:error, :execution_migration_operation_contract_drift}
      {:error, _reason} = error -> error
    end
  end

  def commit(%__MODULE__{}, _execution, agent),
    do: {:error, {:invalid_execution_migration_commit, agent}}

  @doc "Verifies the prepared migration and request binding."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = migration) do
    with true <- migration.schema_version == @schema_version,
         {:ok, program} <- Program.new(migration.program),
         true <- program.digest == migration.program.digest,
         true <- digest?(migration.source_state_digest),
         true <- digest?(migration.operation_contract_digest),
         true <- digest?(migration.digest),
         {:ok, declared} <- declared_migration(program, migration.source_version),
         true <- declared.to == migration.target_version,
         true <- same_name?(declared.operation_ref, migration.operation_ref),
         {:ok, source_digest} <- Value.digest(migration.source_state),
         true <- source_digest == migration.source_state_digest,
         :ok <- verify_request(migration),
         expected <- migration |> Map.from_struct() |> identity_data() |> Value.digest!(),
         true <- expected == migration.digest do
      :ok
    else
      false -> {:error, :execution_migration_integrity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns privacy-safe migration lineage."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = migration) do
    migration
    |> Map.from_struct()
    |> identity_data()
    |> Map.put(:digest, migration.digest)
  end

  @spec declared_migration(Program.t(), term()) :: {:ok, map()} | {:error, term()}
  defp declared_migration(program, source_version) do
    case Enum.find(program.migrations, &(&1.from == source_version)) do
      nil -> {:error, {:execution_migration_not_declared, source_version, program.version}}
      migration -> {:ok, migration}
    end
  end

  @spec pure_migration(Spec.t(), map()) :: :ok | {:error, term()}
  defp pure_migration(%Spec{side_effect: :none}, _migration), do: :ok

  defp pure_migration(spec, migration),
    do: {:error, {:execution_migration_must_be_pure, migration.operation_ref, spec.side_effect}}

  @spec verify_request(t()) :: :ok | {:error, term()}
  defp verify_request(migration) do
    request = migration.request

    expected_input = %{
      schema_version: 1,
      program_digest: migration.program.digest,
      from: migration.source_version,
      to: migration.target_version,
      state: migration.source_state
    }

    expected_id =
      migration_request_id(
        migration.program.digest,
        migration.source_version,
        migration.source_state_digest,
        migration.operation_contract_digest
      )

    expected_metadata = %{
      execution_program_digest: migration.program.digest,
      execution_migration_from: migration.source_version,
      execution_migration_to: migration.target_version,
      operation_contract_digest: migration.operation_contract_digest
    }

    with :ok <- validate_request(request),
         :ok <-
           exact_request_value(request.id, expected_id, :execution_migration_request_id_mismatch),
         :ok <-
           exact_request_value(
             request.operation,
             migration.operation_ref,
             :execution_migration_request_operation_mismatch
           ),
         :ok <-
           exact_request_value(
             request.input,
             expected_input,
             :execution_migration_request_input_mismatch
           ),
         :ok <-
           exact_request_value(
             request.phase,
             :state_migration,
             :execution_migration_request_routing_mismatch
           ),
         :ok <-
           exact_request_value(
             request.branch,
             migration.program.id,
             :execution_migration_request_routing_mismatch
           ) do
      exact_request_value(
        request.metadata,
        expected_metadata,
        :execution_migration_request_metadata_mismatch
      )
    end
  end

  @spec validate_request(term()) :: :ok | {:error, term()}
  defp validate_request(%Request{} = request) do
    if Request.validate(request) == :ok,
      do: :ok,
      else: {:error, :invalid_execution_migration_request}
  end

  defp validate_request(_request), do: {:error, :invalid_execution_migration_request}

  @spec exact_request_value(term(), term(), atom()) :: :ok | {:error, term()}
  defp exact_request_value(value, value, _error), do: :ok
  defp exact_request_value(_actual, _expected, error), do: {:error, error}

  @spec migration_receipt(t(), Execution.t(), String.t()) ::
          {:ok, Receipt.t()} | {:error, term()}
  defp migration_receipt(migration, execution, target_digest) do
    operation_receipt_digest =
      if is_nil(execution.receipt), do: nil, else: Value.digest!(execution.receipt)

    Receipt.new(%{
      migration_digest: migration.digest,
      program_digest: migration.program.digest,
      operation_ref: migration.operation_ref,
      operation_contract_digest: migration.operation_contract_digest,
      source_version: migration.source_version,
      target_version: migration.target_version,
      source_state_digest: migration.source_state_digest,
      target_state_digest: target_digest,
      operation_receipt_digest: operation_receipt_digest
    })
  end

  @spec identity_data(map()) :: map()
  defp identity_data(migration) do
    %{
      schema_version: Map.fetch!(migration, :schema_version),
      program_digest: Map.fetch!(migration, :program).digest,
      source_version: Map.fetch!(migration, :source_version),
      target_version: Map.fetch!(migration, :target_version),
      source_state_digest: Map.fetch!(migration, :source_state_digest),
      operation_ref: Map.fetch!(migration, :operation_ref),
      operation_contract_digest: Map.fetch!(migration, :operation_contract_digest),
      request_id: Map.fetch!(migration, :request).id,
      request_input_digest: Value.digest!(Map.fetch!(migration, :request).input)
    }
  end

  @spec spec_digest(Spec.t()) :: String.t()
  defp spec_digest(spec) do
    Value.digest!(%{
      id: spec.id,
      kind: spec.kind,
      input: spec.input,
      output: spec.output,
      domain: spec.domain,
      side_effect: spec.side_effect,
      risk: spec.risk,
      timeout: spec.timeout,
      retry: Map.from_struct(spec.retry),
      metadata: spec.metadata
    })
  end

  @spec migration_request_id(String.t(), term(), String.t(), String.t()) :: String.t()
  defp migration_request_id(program_digest, source_version, source_digest, contract_digest) do
    digest =
      Value.digest!({program_digest, source_version, source_digest, contract_digest})

    "execution-migration:" <> binary_part(digest, 0, 32)
  end

  @spec same_name?(term(), term()) :: boolean()
  defp same_name?(left, right) when is_atom(left), do: same_name?(Atom.to_string(left), right)
  defp same_name?(left, right) when is_atom(right), do: same_name?(left, Atom.to_string(right))
  defp same_name?(left, right), do: left == right

  @spec digest?(term()) :: boolean()
  defp digest?(value) when is_binary(value) and byte_size(value) == 64,
    do: match?({:ok, _bytes}, Base.decode16(value, case: :mixed))

  defp digest?(_value), do: false
end
