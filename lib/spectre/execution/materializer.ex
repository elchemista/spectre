defmodule Spectre.Execution.Materializer do
  @moduledoc """
  Resolves a runtime Skill Work route into an exact execution materialization.

  Routing, prompt rendering and continuation pinning happen once. The result
  can then enter the shared operational runtime without re-reading mutable
  Skill state or executing authored code.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Execution.Handoff
  alias Spectre.Execution.Materialization
  alias Spectre.Projection
  alias Spectre.Projection.Execution, as: ExecutionProjection
  alias Spectre.Prompt.Materializer, as: PromptMaterializer
  alias Spectre.Skill.Definition, as: SkillDefinition
  alias Spectre.Skill.Runtime, as: SkillRuntime
  alias Spectre.Skill.Runtime.Response

  @doc "Materializes the selected Work and returns the runtime with its new pin."
  @spec materialize(SkillRuntime.t(), term(), map(), keyword()) ::
          {:ok, Materialization.t(), SkillRuntime.t()} | {:error, term()}
  def materialize(runtime, input, context \\ %{}, opts \\ [])

  def materialize(%SkillRuntime{} = runtime, input, context, opts)
      when is_map(context) and is_list(opts) do
    with :ok <- materialization_options(opts),
         {:ok, %Response{kind: :work} = response, next_runtime} <-
           SkillRuntime.respond(runtime, input, context, opts),
         {:ok, definition} <- SkillRuntime.continuation(next_runtime, response.continuation_id),
         {:ok, program} <- SkillDefinition.work(definition, response.work_ref),
         true <- program.digest == response.program_digest,
         {:ok, plans, receipts} <- prompt_materializations(definition, program, input, context),
         plan_digests <- Map.new(plans, fn {ref, plan} -> {ref, plan.metadata.hash} end),
         evidence <- %{
           input_evidence_digest: Value.digest!(response.work_input),
           prompt_receipt_digests: Enum.map(receipts, & &1.digest)
         },
         {:ok, projection} <-
           Projection.generate(SkillDefinition.canonical(definition), ExecutionProjection,
             program: program,
             input: response.work_input,
             prompt_receipts: receipts,
             plan_digests: plan_digests,
             mount_id: response.mount_id,
             route: %{label: response.route_label},
             continuation_id: response.continuation_id,
             evidence: evidence
           ),
         {:ok, materialization} <-
           Materialization.new(
             definition,
             response,
             program,
             response.work_input,
             plans,
             receipts,
             projection
           ) do
      {:ok, materialization, next_runtime}
    else
      {:ok, %Response{} = response, _runtime} ->
        {:error, {:runtime_skill_response_is_not_work, response.kind}}

      false ->
        {:error, :runtime_skill_work_program_mismatch}

      {:error, _reason} = error ->
        error
    end
  end

  def materialize(%SkillRuntime{}, _input, context, opts),
    do: {:error, {:invalid_execution_materialization_options, shape(context), shape(opts)}}

  def materialize(runtime, _input, context, opts),
    do: {:error, {:invalid_execution_materializer, shape(runtime), shape(context), shape(opts)}}

  @doc "Returns the explicit typed Flow-to-Work handoff for a materialization."
  @spec handoff(Materialization.t()) :: {:ok, Handoff.t()} | {:error, term()}
  def handoff(%Materialization{} = materialization) do
    Handoff.flow_to_work(
      materialization.definition_ref,
      materialization.route_label,
      materialization.program.id,
      materialization.input,
      correlation_id: materialization.continuation_id,
      provenance: %{
        skill_mount_id: materialization.mount_id,
        execution_materialization_digest: materialization.digest
      }
    )
  end

  def handoff(value), do: {:error, {:invalid_execution_materialization, shape(value)}}

  @spec prompt_materializations(SkillDefinition.t(), Spectre.Execution.Program.t(), term(), map()) ::
          {:ok, map(), [Spectre.Prompt.Receipt.t()]} | {:error, term()}
  defp prompt_materializations(definition, program, input, context) do
    fragments = SkillDefinition.prompt_fragments(definition)
    definition_ref = definition |> SkillDefinition.ref() |> Spectre.Definition.Ref.to_string()

    Enum.reduce_while(program.prompt_refs, {:ok, %{}, []}, fn prompt_ref,
                                                              {:ok, plans, receipts} ->
      case Enum.find(fragments, &(stable_name(&1.id) == prompt_ref)) do
        nil ->
          {:halt, {:error, {:execution_prompt_fragment_missing, prompt_ref}}}

        fragment ->
          case PromptMaterializer.materialize(fragment, input, context, definition_ref) do
            {:ok, plan, receipt} ->
              {:cont, {:ok, Map.put(plans, prompt_ref, plan), [receipt | receipts]}}

            {:error, _reason} = error ->
              {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, plans, receipts} -> {:ok, plans, Enum.reverse(receipts)}
      {:error, _reason} = error -> error
    end
  end

  @spec stable_name(term()) :: String.t()
  defp stable_name(value) when is_atom(value), do: Atom.to_string(value)
  defp stable_name(value) when is_binary(value), do: value
  defp stable_name(_value), do: nil

  @spec materialization_options(term()) :: :ok | {:error, term()}
  defp materialization_options(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, :invalid_execution_materialization_options}
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other
end
