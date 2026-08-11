defmodule Spectre.Operation.Runtime.Contract do
  @moduledoc """
  Definition and declaration validation for the operation runtime.

  Loads the code-owned `Spectre.Operation.Definition` behind a committed loop
  and enforces everything the definition declares: kind and version
  compatibility, controller callbacks, security policy, branches, blockers,
  waits, triggers, artifact policy and update fields.
  """

  import Spectre.Operation.Runtime.Support

  alias Spectre.Execution.Controller, as: ExecutionController
  alias Spectre.Execution.Program, as: ExecutionProgram
  alias Spectre.Operation.Artifact
  alias Spectre.Operation.Control.Command
  alias Spectre.Operation.Definition
  alias Spectre.Operation.Loop
  alias Spectre.Operation.Request
  alias Spectre.Operation.Spec
  alias Spectre.Operation.Validator
  alias Spectre.Operation.Wait

  @externally_driven_waits [:human, :external, :event, :reconciliation]

  @doc "Loads and validates the current definition for a committed loop."
  @spec current_definition(Loop.t()) :: {:ok, Definition.t()} | {:error, term()}
  def current_definition(loop) do
    with {:ok, definition} <- load_definition(loop),
         :ok <- ensure_kind(definition, loop.kind),
         :ok <- ensure_definition_identity(definition, loop),
         :ok <- ensure_definition_compatibility(definition, loop),
         :ok <- validate_controller_contract(definition, loop.controller) do
      {:ok, definition}
    else
      {:error, _reason} = error -> error
    end
  end

  @spec load_definition(Loop.t()) :: {:ok, Definition.t()} | {:error, term()}
  defp load_definition(%Loop{controller: ExecutionController, metadata: metadata}) do
    with data when is_map(data) <- Map.get(metadata, ExecutionController.program_key()),
         {:ok, program} <- ExecutionProgram.from_data(data),
         true <- program.digest == Map.get(data, :digest, Map.get(data, "digest")) do
      {:ok, ExecutionProgram.operation_definition(program)}
    else
      nil -> {:error, :execution_program_missing_from_loop}
      false -> {:error, :execution_program_digest_mismatch}
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_execution_program_in_loop, shape(value)}}
    end
  end

  defp load_definition(%Loop{} = loop), do: Definition.load(loop.controller)

  @doc "Requires the definition kind to match the requested loop kind."
  @spec ensure_kind(Definition.t(), Loop.kind()) :: :ok | {:error, term()}
  def ensure_kind(%Definition{kind: kind}, kind), do: :ok

  def ensure_kind(definition, expected),
    do: {:error, {:loop_definition_kind_mismatch, expected, definition.kind}}

  @doc "Requires optional controller callbacks implied by the definition."
  @spec validate_controller_contract(Definition.t(), module()) :: :ok | {:error, term()}
  def validate_controller_contract(definition, controller) do
    cond do
      definition.on_budget_exhausted == :controller and
          not function_exported?(controller, :budget_exhausted, 3) ->
        {:error, {:controller_callback_missing, controller, :budget_exhausted, 3}}

      definition.blockers != [] and not function_exported?(controller, :handle_trigger, 3) ->
        {:error, {:controller_callback_missing, controller, :handle_trigger, 3}}

      true ->
        :ok
    end
  end

  @doc "Validates loop origins, destinations and visibility against security policy."
  @spec validate_loop_security(Definition.t(), Loop.t()) :: :ok | {:error, term()}
  def validate_loop_security(%Definition{security: security}, loop) do
    allowed_origins = option(security, :allowed_origins, [])
    allowed_destinations = option(security, :allowed_destinations, [])
    allowed_visibility = option(security, :allowed_visibility, [:origin, :subject])

    cond do
      allowed_origins != [] and
          Enum.any?([loop.origin | loop.authorized_origins], &(&1 not in allowed_origins)) ->
        {:error, {:operational_origin_not_authorized, loop.origin}}

      allowed_destinations != [] and
          Enum.any?(loop.destinations, &(&1 not in allowed_destinations)) ->
        {:error, :operational_destination_not_authorized}

      loop.visibility not in allowed_visibility ->
        {:error, {:operational_visibility_not_authorized, loop.visibility}}

      Enum.uniq(loop.authorized_origins) != loop.authorized_origins ->
        {:error, :duplicate_operational_authorized_origin}

      Enum.uniq(loop.destinations) != loop.destinations ->
        {:error, :duplicate_operational_destination}

      true ->
        :ok
    end
  end

  @doc "Authorizes a control command against the definition security policy."
  @spec authorize_control(Definition.t(), Command.t()) :: :ok | {:error, term()}
  def authorize_control(%Definition{security: security}, %Command{mode: :immediate}) do
    if option(security, :allow_immediate_pause, false),
      do: :ok,
      else: {:error, :immediate_loop_interruption_forbidden_by_definition}
  end

  def authorize_control(_definition, _command), do: :ok

  @doc "Fences a control command against the committed loop revision."
  @spec authorize_revision(Loop.t(), non_neg_integer() | nil) :: :ok | {:error, term()}
  def authorize_revision(_loop, nil), do: :ok
  def authorize_revision(%Loop{revision: revision}, revision), do: :ok

  def authorize_revision(%Loop{revision: current}, supplied),
    do: {:error, {:stale_loop_control_revision, supplied, current}}

  @doc "Stamps definition-owned publication and correlation policy into metadata."
  @spec policy_metadata(map(), Definition.t()) :: map()
  def policy_metadata(metadata, definition) do
    metadata
    |> Map.put(:publication, publication_policy(definition))
    |> Map.put(:trigger_correlation, trigger_correlation_policy(definition))
  end

  @doc "Resolves the declared artifact retention limit."
  @spec artifact_limit(Definition.t()) :: pos_integer()
  def artifact_limit(%Definition{artifact_policy: policy}),
    do: option(policy, :max_count, artifact_limit())

  @doc "Validates artifact kinds and the retention limit for appended artifacts."
  @spec validate_artifacts(Definition.t(), Loop.t(), [term()]) :: :ok | {:error, term()}
  def validate_artifacts(definition, loop, artifacts) do
    allowed = option(definition.artifact_policy, :allowed_kinds, [])
    limit = artifact_limit(definition)

    if length(loop.artifacts) + length(artifacts) > limit do
      {:error, {:operation_artifact_limit_exceeded, limit}}
    else
      Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
        with :ok <- validate_artifact(artifact),
             :ok <- validate_artifact_kind(artifact, allowed) do
          {:cont, :ok}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Validates a requested operation against declared branches."
  @spec validate_branch(Definition.t(), Request.t()) :: :ok | {:error, term()}
  def validate_branch(%Definition{}, %Request{branch: nil}), do: :ok

  def validate_branch(%Definition{branches: branches}, %Request{} = request) do
    case Map.fetch(branches, request.branch) do
      {:ok, allowed} ->
        if request.operation in allowed,
          do: :ok,
          else: {:error, {:operation_outside_declared_branch, request.branch, request.operation}}

      :error ->
        {:error, {:undeclared_work_branch, request.branch}}
    end
  end

  @doc "Validates a blocker against the declared blocker ids."
  @spec validate_blocker(Definition.t(), term()) :: :ok | {:error, term()}
  def validate_blocker(%Definition{blockers: blockers}, blocker) do
    id = blocker_id(blocker)

    if id in blockers,
      do: :ok,
      else: {:error, {:undeclared_operational_blocker, id}}
  end

  @doc "Validates a wait against the declared wait kinds."
  @spec validate_wait(Definition.t(), Wait.t()) :: :ok | {:error, term()}
  def validate_wait(%Definition{kind: :vigil, waits: []}, %Wait{} = wait),
    do: {:error, {:undeclared_vigil_trigger, wait.kind}}

  def validate_wait(%Definition{kind: :vigil, waits: waits}, %Wait{} = wait) do
    if wait.kind in waits,
      do: :ok,
      else: {:error, {:undeclared_vigil_trigger, wait.kind}}
  end

  def validate_wait(%Definition{waits: waits}, %Wait{} = wait) do
    if wait.kind in waits,
      do: :ok,
      else: {:error, {:undeclared_operational_wait, wait.kind}}
  end

  @doc "Validates a delivered trigger, always accepting correlated retry timers."
  @spec validate_delivered_trigger(Definition.t(), Loop.t(), term(), term()) ::
          :ok | {:error, term()}
  def validate_delivered_trigger(
        _definition,
        %Loop{wait: %Wait{id: wait_id, kind: :retry}},
        {:timer, wait_id},
        wait_id
      ),
      do: :ok

  def validate_delivered_trigger(definition, _loop, trigger, _expected_wait),
    do: validate_trigger(definition, trigger)

  @doc "Enforces the declared trigger correlation policy for the active wait."
  @spec validate_trigger_correlation(Definition.t(), Wait.t() | nil, term(), term()) ::
          {:ok, :exact | :legacy} | {:error, term()}
  def validate_trigger_correlation(
        definition,
        %Wait{kind: kind},
        expected_wait,
        expected_generation
      ) do
    missing =
      []
      |> maybe_missing_correlation(:wait_id, expected_wait)
      |> maybe_missing_correlation(:generation, expected_generation)

    if trigger_correlation_policy(definition) == :required and
         kind in @externally_driven_waits and missing != [] do
      {:error, {:operation_trigger_correlation_required, Enum.reverse(missing)}}
    else
      {:ok, if(missing == [], do: :exact, else: :legacy)}
    end
  end

  def validate_trigger_correlation(_definition, nil, _expected_wait, _expected_generation),
    do: {:error, :operation_trigger_wait_missing}

  @doc "Validates changed update fields against the declared update contract."
  @spec validate_updated_fields(term(), term(), Definition.t()) :: :ok | {:error, term()}
  def validate_updated_fields(before, updated, %Definition{update_fields: fields}) do
    cond do
      before == updated ->
        :ok

      :all in fields ->
        :ok

      is_map(before) and is_map(updated) ->
        changed =
          (Map.keys(before) ++ Map.keys(updated))
          |> Enum.uniq()
          |> Enum.filter(&(Map.get(before, &1) != Map.get(updated, &1)))

        case Enum.reject(changed, &(&1 in fields)) do
          [] -> :ok
          rejected -> {:error, {:work_update_fields_not_declared, rejected}}
        end

      true ->
        {:error, :work_update_replacement_not_declared}
    end
  end

  @doc "Requires cognitive constraint updates to be maps."
  @spec validate_cognitive_update(term()) :: :ok | {:error, term()}
  def validate_cognitive_update(value) when is_map(value), do: :ok
  def validate_cognitive_update(value), do: {:error, {:invalid_cognitive_constraints, value}}

  @doc "Validates a declared Vigil significance value."
  @spec validate_significance(Loop.kind(), term()) :: :ok | {:error, term()}
  def validate_significance(:vigil, value)
      when value in [:significant, :silent, true, false, nil],
      do: :ok

  def validate_significance(:vigil, value),
    do: {:error, {:invalid_vigil_significance, value}}

  def validate_significance(_kind, _value), do: :ok

  @doc "Validates a non-negative operation cost."
  @spec validate_cost(map(), term()) :: :ok | {:error, term()}
  def validate_cost(usage, fallback) do
    cost = Map.get(usage, :cost, Map.get(usage, "cost", fallback))

    if is_nil(cost) or (is_number(cost) and cost >= 0),
      do: :ok,
      else: {:error, {:invalid_operation_cost, cost}}
  end

  @doc "Validates a non-negative integral page count."
  @spec validate_pages(map(), term()) :: :ok | {:error, term()}
  def validate_pages(usage, fallback) do
    pages = Map.get(usage, :pages, Map.get(usage, "pages", fallback))

    if is_nil(pages) or (is_integer(pages) and pages >= 0),
      do: :ok,
      else: {:error, {:invalid_operation_pages, pages}}
  end

  @doc "Validates a request input against the operation spec, unless reconciling."
  @spec validate_request_input(Spec.t(), Request.t(), boolean()) :: :ok | {:error, term()}
  def validate_request_input(_spec, %Request{}, true), do: :ok

  def validate_request_input(spec, %Request{} = request, false),
    do: Validator.validate(spec.input, request.input, {:operation_input, spec.id})

  defp ensure_definition_identity(%Definition{id: id}, %Loop{controller_id: id}), do: :ok

  defp ensure_definition_identity(%Definition{id: current}, %Loop{controller_id: stored}),
    do: {:error, {:loop_definition_identity_mismatch, stored, current}}

  defp ensure_definition_compatibility(definition, loop) do
    if Definition.compatible?(loop.controller, loop.controller_version, definition.version),
      do: :ok,
      else: {:error, {:incompatible_loop_definition, loop.controller_version, definition.version}}
  end

  defp publication_policy(%Definition{artifact_policy: policy}) do
    %{
      publish_results: option(policy, :publish_results, true),
      publish_artifacts: option(policy, :publish_artifacts, true),
      publish_progress: option(policy, :publish_progress, true),
      publish_blocker: option(policy, :publish_blocker, true)
    }
  end

  defp trigger_correlation_policy(%Definition{security: security}) do
    case Map.fetch(security, :trigger_correlation) do
      {:ok, policy} ->
        policy

      :error ->
        if(option(security, :require_trigger_correlation, false), do: :required, else: :legacy)
    end
  end

  defp validate_artifact(%Artifact{} = artifact), do: Artifact.validate(artifact)
  defp validate_artifact(artifact), do: portable(artifact, [:operation, :artifact])

  defp validate_artifact_kind(_artifact, []), do: :ok

  defp validate_artifact_kind(artifact, allowed) do
    kind =
      case artifact do
        %Artifact{kind: value} -> value
        %{kind: value} -> value
        %{"kind" => value} -> value
        _other -> nil
      end

    if kind in allowed,
      do: :ok,
      else: {:error, {:operation_artifact_kind_not_allowed, kind}}
  end

  defp validate_trigger(%Definition{kind: :vigil, triggers: triggers}, trigger) do
    type = trigger_class(trigger)

    if type in triggers,
      do: :ok,
      else: {:error, {:undeclared_vigil_trigger, type}}
  end

  defp validate_trigger(%Definition{triggers: []}, _trigger), do: :ok

  defp validate_trigger(%Definition{triggers: triggers}, trigger) do
    type = trigger_class(trigger)

    if type in triggers,
      do: :ok,
      else: {:error, {:undeclared_operational_trigger, type}}
  end

  defp blocker_id(%{id: id}), do: id
  defp blocker_id(%{"id" => id}), do: id
  defp blocker_id(%{type: type}), do: type
  defp blocker_id(%{"type" => type}), do: type
  defp blocker_id({id, _payload}), do: id
  defp blocker_id(id) when is_atom(id) or is_binary(id), do: id
  defp blocker_id(_blocker), do: :invalid

  defp maybe_missing_correlation(missing, field, nil), do: [field | missing]
  defp maybe_missing_correlation(missing, _field, _value), do: missing

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
