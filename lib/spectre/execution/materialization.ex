defmodule Spectre.Execution.Materialization do
  @moduledoc """
  Exact, verified boundary between Skill routing and data-driven execution.

  The struct carries the closed program, resolved input and typed prompt plans
  needed by the shared operational executor. Its portable identity contains
  only digests and lineage, so logs and projections do not expose prompt or
  input content.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref
  alias Spectre.Execution.Program
  alias Spectre.Operation.Validator
  alias Spectre.Projection
  alias Spectre.Prompt.Plan
  alias Spectre.Prompt.Receipt
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime.Response

  @schema_version 1

  @enforce_keys [
    :definition_ref,
    :mount_id,
    :route_label,
    :continuation_id,
    :program,
    :input,
    :plans,
    :prompt_receipts,
    :projection,
    :digest
  ]
  defstruct schema_version: @schema_version,
            definition_ref: nil,
            mount_id: nil,
            route_label: nil,
            continuation_id: nil,
            program: nil,
            input: nil,
            plans: %{},
            prompt_receipts: [],
            projection: nil,
            digest: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          definition_ref: String.t(),
          mount_id: term(),
          route_label: term(),
          continuation_id: String.t(),
          program: Program.t(),
          input: term(),
          plans: %{optional(String.t()) => Plan.t()},
          prompt_receipts: [Receipt.t()],
          projection: Projection.t(),
          digest: String.t()
        }

  @doc false
  @spec new(
          SkillDefinition.t(),
          Response.t(),
          Program.t(),
          term(),
          map(),
          [Receipt.t()],
          Projection.t()
        ) :: {:ok, t()} | {:error, term()}
  def new(
        %SkillDefinition{} = definition,
        %Response{kind: :work} = response,
        %Program{} = program,
        input,
        plans,
        receipts,
        %Projection{} = projection
      ) do
    definition_ref = definition |> SkillDefinition.ref() |> Ref.to_string()

    with {:ok, declared} <- SkillDefinition.work(definition, response.work_ref),
         {:ok, program} <- Program.new(program),
         :ok <- exact_program(declared, program, response),
         :ok <-
           Validator.validate(
             program.input,
             input,
             {:execution_materialization_input, program.id}
           ),
         :ok <- portable(input, :input),
         {:ok, plans} <- normalize_plans(plans, program),
         {:ok, receipts} <- normalize_receipts(receipts, program, definition_ref, plans),
         :ok <-
           projection_binding(projection, definition, program, response, input, plans, receipts),
         {:ok, mount_id} <- portable_value(response.mount_id, :mount_id),
         {:ok, route_label} <- portable_value(response.route_label, :route_label),
         :ok <- continuation_id(response.continuation_id) do
      base = %{
        schema_version: @schema_version,
        definition_ref: definition_ref,
        mount_id: mount_id,
        route_label: route_label,
        continuation_id: response.continuation_id,
        program: program,
        input: input,
        plans: plans,
        prompt_receipts: receipts,
        projection: projection
      }

      digest = base |> identity_data() |> Value.digest!()
      {:ok, struct!(__MODULE__, Map.put(base, :digest, digest))}
    end
  end

  def new(
        %SkillDefinition{},
        %Response{} = response,
        %Program{},
        _input,
        _plans,
        _receipts,
        %Projection{}
      ),
      do: {:error, {:execution_materialization_requires_work_response, response.kind}}

  @doc "Verifies every internal digest and exact plan/receipt binding."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = materialization) do
    with true <- materialization.schema_version == @schema_version,
         {:ok, definition_ref} <- Ref.parse(materialization.definition_ref),
         {:ok, program} <- Program.new(materialization.program),
         :ok <- exact_digest(program.digest, materialization.program.digest, :program),
         :ok <-
           Validator.validate(
             program.input,
             materialization.input,
             {:execution_materialization_input, program.id}
           ),
         :ok <- portable(materialization.input, :input),
         {:ok, plans} <- normalize_plans(materialization.plans, program),
         {:ok, receipts} <-
           normalize_receipts(
             materialization.prompt_receipts,
             program,
             Ref.to_string(definition_ref),
             plans
           ),
         :ok <- Projection.verify_ref(materialization.projection, definition_ref),
         :ok <-
           projection_shape(materialization.projection, definition_ref, program, plans, receipts),
         :ok <- continuation_id(materialization.continuation_id),
         {:ok, _mount_id} <- portable_value(materialization.mount_id, :mount_id),
         {:ok, _route_label} <- portable_value(materialization.route_label, :route_label),
         expected <- materialization |> Map.from_struct() |> identity_data() |> Value.digest!(),
         :ok <- exact_digest(materialization.digest, expected, :materialization) do
      :ok
    else
      false ->
        {:error, {:unsupported_execution_materialization_schema, materialization.schema_version}}

      {:error, _reason} = error ->
        error
    end
  end

  def verify(value), do: {:error, {:invalid_execution_materialization, shape(value)}}

  @doc "Returns the privacy-safe portable identity of a materialization."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = materialization) do
    materialization
    |> Map.from_struct()
    |> identity_data()
    |> Map.put(:digest, materialization.digest)
  end

  @spec identity_data(map()) :: map()
  defp identity_data(materialization) do
    program = Map.fetch!(materialization, :program)
    plans = Map.fetch!(materialization, :plans)
    receipts = Map.fetch!(materialization, :prompt_receipts)
    projection = Map.fetch!(materialization, :projection)

    %{
      schema_version: Map.fetch!(materialization, :schema_version),
      definition_ref: Map.fetch!(materialization, :definition_ref),
      mount_id: Map.fetch!(materialization, :mount_id),
      route_label: Map.fetch!(materialization, :route_label),
      continuation_id: Map.fetch!(materialization, :continuation_id),
      program_digest: program.digest,
      input_evidence_digest: Value.digest!(Map.fetch!(materialization, :input)),
      plan_digests: plan_digests(plans),
      prompt_receipt_digests: Enum.map(receipts, & &1.digest),
      projection_digest: projection.digest
    }
  end

  @spec exact_program(Program.t(), Program.t(), Response.t()) :: :ok | {:error, term()}
  defp exact_program(declared, program, response) do
    cond do
      declared.digest != program.digest -> {:error, :execution_materialization_program_mismatch}
      response.program_digest != program.digest -> {:error, :execution_response_program_mismatch}
      true -> :ok
    end
  end

  @spec normalize_plans(term(), Program.t()) :: {:ok, map()} | {:error, term()}
  defp normalize_plans(plans, program) when is_map(plans) and not is_struct(plans) do
    entries = Enum.map(plans, fn {ref, plan} -> {stable_name(ref), plan} end)
    normalized = Map.new(entries)

    cond do
      map_size(normalized) != length(entries) ->
        {:error, :duplicate_execution_materialization_prompt_plan_ref}

      Enum.sort(Map.keys(normalized)) != Enum.sort(program.prompt_refs) ->
        {:error, :execution_materialization_prompt_plan_set_mismatch}

      Enum.any?(normalized, fn {_ref, plan} -> not match?(%Plan{}, plan) end) ->
        {:error, :invalid_execution_materialization_prompt_plan}

      Enum.any?(normalized, fn {_ref, plan} -> plan_hash(plan) != plan.metadata.hash end) ->
        {:error, :execution_materialization_prompt_plan_digest_mismatch}

      true ->
        {:ok, normalized}
    end
  end

  defp normalize_plans(value, _program),
    do: {:error, {:invalid_execution_materialization_plans, shape(value)}}

  @spec normalize_receipts(term(), Program.t(), String.t(), map()) ::
          {:ok, [Receipt.t()]} | {:error, term()}
  defp normalize_receipts(receipts, program, definition_ref, plans) when is_list(receipts) do
    receipts
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {receipt, index}, {:ok, acc} ->
      result =
        case receipt do
          %Receipt{} -> receipt |> Receipt.to_data() |> Receipt.from_data()
          data when is_map(data) -> Receipt.from_data(data)
          value -> {:error, {:invalid_prompt_receipt, shape(value)}}
        end

      case result do
        {:ok, receipt} ->
          {:cont, {:ok, [receipt | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_execution_materialization_receipt, index, reason}}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.sort_by(normalized, &stable_name(&1.prompt_ref))
        validate_receipts(normalized, program, definition_ref, plans)

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_receipts(value, _program, _definition_ref, _plans),
    do: {:error, {:invalid_execution_materialization_receipts, shape(value)}}

  @spec validate_receipts([Receipt.t()], Program.t(), String.t(), map()) ::
          {:ok, [Receipt.t()]} | {:error, term()}
  defp validate_receipts(receipts, program, definition_ref, plans) do
    actual = Enum.map(receipts, &stable_name(&1.prompt_ref))

    cond do
      actual != Enum.sort(program.prompt_refs) ->
        {:error, :execution_materialization_prompt_receipt_set_mismatch}

      Enum.any?(receipts, &(&1.definition_ref != definition_ref)) ->
        {:error, :execution_materialization_receipt_definition_mismatch}

      Enum.any?(receipts, fn receipt ->
        plan = Map.fetch!(plans, stable_name(receipt.prompt_ref))
        receipt.rendered_digest != Value.digest!(Plan.legacy(plan))
      end) ->
        {:error, :execution_materialization_receipt_plan_mismatch}

      true ->
        {:ok, receipts}
    end
  end

  @spec projection_binding(
          Projection.t(),
          SkillDefinition.t(),
          Program.t(),
          Response.t(),
          term(),
          map(),
          [Receipt.t()]
        ) :: :ok | {:error, term()}
  defp projection_binding(projection, definition, program, response, input, plans, receipts) do
    with :ok <- Projection.verify(projection, SkillDefinition.canonical(definition)),
         :ok <- projection_shape(projection, definition.ref, program, plans, receipts),
         content = projection.content,
         true <- Map.get(content, :mount_id) == response.mount_id,
         true <- Map.get(content, :route) == %{label: response.route_label},
         true <- Map.get(content, :continuation_id) == response.continuation_id,
         true <- Map.get(content, :input_evidence_digest) == Value.digest!(input) do
      :ok
    else
      false -> {:error, :execution_materialization_projection_mismatch}
      {:error, _reason} = error -> error
    end
  end

  @spec projection_shape(Projection.t(), Ref.t(), Program.t(), map(), [Receipt.t()]) ::
          :ok | {:error, term()}
  defp projection_shape(%Projection{} = projection, definition_ref, program, plans, receipts) do
    with :ok <- projection_identity(projection, definition_ref) do
      projection_content(projection.content, program, plans, receipts)
    end
  end

  @spec projection_identity(Projection.t(), Ref.t()) :: :ok | {:error, term()}
  defp projection_identity(projection, definition_ref) do
    cond do
      projection.generator_id != "spectre.projection.execution" ->
        {:error, :execution_materialization_projection_generator_mismatch}

      projection.generator_version != 1 ->
        {:error, :execution_materialization_projection_version_mismatch}

      projection.definition_ref != definition_ref ->
        {:error, :execution_materialization_projection_definition_mismatch}

      true ->
        :ok
    end
  end

  @spec projection_content(term(), Program.t(), map(), [Receipt.t()]) ::
          :ok | {:error, term()}
  defp projection_content(content, program, plans, receipts) do
    cond do
      not is_map(content) ->
        {:error, :invalid_execution_materialization_projection}

      Map.get(content, :program) != %{
        id: program.id,
        version: program.version,
        digest: program.digest
      } ->
        {:error, :execution_materialization_projection_program_mismatch}

      Map.get(content, :plan_digests) != plan_digests(plans) ->
        {:error, :execution_materialization_projection_plan_mismatch}

      not valid_projection_receipts?(Map.get(content, :prompt_receipts)) ->
        {:error, :invalid_execution_materialization_projection_receipts}

      Enum.map(Map.get(content, :prompt_receipts), &Map.get(&1, :digest)) !=
          Enum.map(receipts, & &1.digest) ->
        {:error, :execution_materialization_projection_receipt_mismatch}

      true ->
        :ok
    end
  end

  @spec valid_projection_receipts?(term()) :: boolean()
  defp valid_projection_receipts?(receipts) when is_list(receipts) do
    Enum.all?(receipts, fn receipt ->
      is_map(receipt) and not is_struct(receipt) and
        is_binary(Map.get(receipt, :digest))
    end)
  end

  defp valid_projection_receipts?(_receipts), do: false

  @spec plan_digests(map()) :: map()
  defp plan_digests(plans), do: Map.new(plans, fn {ref, plan} -> {ref, plan_hash(plan)} end)

  @spec plan_hash(Plan.t()) :: String.t()
  defp plan_hash(%Plan{} = plan) do
    plan |> Plan.legacy() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end

  @spec exact_digest(term(), term(), atom()) :: :ok | {:error, term()}
  defp exact_digest(value, value, _field), do: :ok
  defp exact_digest(_declared, _actual, field), do: {:error, {field, :digest_mismatch}}

  @spec portable(term(), atom()) :: :ok | {:error, term()}
  defp portable(value, field) do
    case Value.validate(value) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_execution_materialization, field, reason}}
    end
  end

  @spec portable_value(term(), atom()) :: {:ok, term()} | {:error, term()}
  defp portable_value(value, field) do
    case portable(value, field) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  @spec continuation_id(term()) :: :ok | {:error, term()}
  defp continuation_id(value) when is_binary(value) and value != "", do: :ok
  defp continuation_id(value), do: {:error, {:invalid_execution_continuation_id, value}}

  @spec stable_name(term()) :: String.t()
  defp stable_name(value) when is_atom(value), do: Atom.to_string(value)
  defp stable_name(value) when is_binary(value), do: value
  defp stable_name(value), do: inspect(value)

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
