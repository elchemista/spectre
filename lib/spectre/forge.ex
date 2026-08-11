defmodule Spectre.Forge do
  @moduledoc """
  Data-only proposal plane for governed Definition changes.

  Forge consumes a verified Reflection projection and redacted Experience
  snapshot, optionally gathers compiled multi-model critics, and emits an
  inert `Spectre.Forge.Proposal`. This module intentionally exposes no
  activation, approval, evaluator registration or authority mutation API.
  """

  alias Spectre.Definition.Ref
  alias Spectre.Experience.Store, as: ExperienceStore
  alias Spectre.Forge.Critic
  alias Spectre.Forge.Critique
  alias Spectre.Forge.OracleApproval
  alias Spectre.Forge.Proposal
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Instance.Activation
  alias Spectre.Projection

  @forge_operation_types ~w(
    disable_skill mount_skill replace_skill select_state_migration
    update_applicability update_skill_config
  )
  @max_operations 256
  @max_oracle_approvals 16
  @max_trusted_oracles 256

  @doc "Returns the constitutional operation vocabulary Forge may propose directly."
  @spec operation_types() :: [String.t()]
  def operation_types, do: @forge_operation_types

  @doc "Returns the external-evidence map used by Composer and activation verification."
  @spec evidence(Projection.t(), ExperienceStore.snapshot()) :: map()
  def evidence(%Projection{} = reflection, %{digest: snapshot_digest}) do
    %{
      "reflection_projection_digest" => reflection.digest,
      "experience_snapshot_digest" => snapshot_digest
    }
  end

  @doc "Builds a new Proposal against the exact current Activation and evidence."
  @spec propose(Activation.t(), Projection.t(), ExperienceStore.snapshot(), [term()], keyword()) ::
          {:ok, Proposal.t()} | {:error, term()}
  def propose(activation, reflection, snapshot, operations, opts \\ [])

  def propose(
        %Activation{},
        %Projection{},
        _snapshot,
        operations,
        opts
      )
      when is_list(operations) and length(operations) > @max_operations and is_list(opts),
      do: {:error, {:forge_operation_limit_exceeded, @max_operations}}

  def propose(
        %Activation{} = activation,
        %Projection{} = reflection,
        snapshot,
        operations,
        opts
      )
      when is_list(operations) and is_list(opts) do
    with :ok <- options(opts),
         :ok <- verify_inputs(activation, reflection, snapshot),
         {:ok, base_operations} <- direct_operations(operations),
         {:ok, critiques} <-
           Critic.run(Keyword.get(opts, :critics, []), reflection, snapshot,
             critic_opts: Keyword.get(opts, :critic_opts, [])
           ),
         {:ok, approvals} <- approvals(Keyword.get(opts, :oracle_approvals, [])),
         {:ok, trusted_oracles} <- trusted_oracles(Keyword.get(opts, :trusted_oracle_refs, [])),
         :ok <- validate_approval_lineage(approvals, critiques),
         {:ok, case_operations} <- approved_case_operations(critiques, approvals, trusted_oracles),
         false <- base_operations == [] and case_operations == [],
         true <- length(base_operations) + length(case_operations) <= @max_operations,
         {:ok, author_ref} <- required(Keyword.get(opts, :author_ref), :author_ref),
         {:ok, reason} <- required(Keyword.get(opts, :reason), :reason),
         {:ok, created_at} <- timestamp(Keyword.get(opts, :created_at)),
         external_evidence = evidence(reflection, snapshot),
         {:ok, provenance} <-
           provenance(
             reflection,
             snapshot,
             critiques,
             approvals,
             trusted_oracles,
             Keyword.get(opts, :provenance, %{}),
             Keyword.get(opts, :parent_proposal_digest)
           ),
         {:ok, change_set} <-
           ChangeSet.new(%{
             base_activation_receipt: activation.activation_receipt,
             base_candidate_ref: activation.candidate_ref,
             observed_definition_ref: activation.definition_ref,
             observed_authority_epoch: activation.authority_epoch,
             observed_evidence_digest: ChangeSet.evidence_digest(activation, external_evidence),
             operations: base_operations ++ case_operations,
             author_ref: author_ref,
             provenance: provenance,
             reason: reason,
             created_at: created_at
           }),
         {:ok, proposal} <-
           Proposal.new(%{
             change_set: change_set,
             reflection_digest: reflection.digest,
             experience_snapshot_digest: snapshot.digest,
             critiques: critiques,
             oracle_approvals: approvals,
             trusted_oracle_refs: trusted_oracles,
             parent_proposal_digest: Keyword.get(opts, :parent_proposal_digest)
           }) do
      {:ok, proposal}
    else
      true -> {:error, :forge_proposal_requires_typed_operation}
      false -> {:error, {:forge_operation_limit_exceeded, @max_operations}}
      {:error, _reason} = error -> error
    end
  end

  def propose(_activation, _reflection, _snapshot, operations, opts),
    do: {:error, {:invalid_forge_proposal_input, shape(operations), shape(opts)}}

  @doc "Explicitly rebuilds a Proposal against new Activation and evidence."
  @spec rebase(
          Proposal.t(),
          Activation.t(),
          Projection.t(),
          ExperienceStore.snapshot(),
          keyword()
        ) ::
          {:ok, Proposal.t()} | {:error, term()}
  def rebase(proposal, activation, reflection, snapshot, opts \\ [])

  def rebase(
        %Proposal{} = proposal,
        %Activation{} = activation,
        %Projection{} = reflection,
        snapshot,
        opts
      )
      when is_list(opts) do
    with :ok <- options(opts),
         :ok <- Proposal.verify(proposal) do
      operations =
        proposal.change_set.operations
        |> Enum.reject(&(&1.type in ["add_eval_case", "replace_eval_case"]))
        |> Enum.map(&Operation.to_data/1)

      propose(
        activation,
        reflection,
        snapshot,
        operations,
        opts
        |> Keyword.put_new(:author_ref, proposal.change_set.author_ref)
        |> Keyword.put_new(:reason, proposal.change_set.reason)
        |> Keyword.put_new(:trusted_oracle_refs, proposal.trusted_oracle_refs)
        |> Keyword.put(:parent_proposal_digest, proposal.digest)
      )
    end
  end

  def rebase(_proposal, _activation, _reflection, _snapshot, _opts),
    do: {:error, :invalid_forge_rebase}

  defp verify_inputs(activation, reflection, snapshot) do
    with :ok <- Projection.verify_ref(reflection, activation.definition_ref),
         "spectre.projection.reflection" <- reflection.generator_id,
         1 <- reflection.generator_version,
         :ok <- ExperienceStore.verify_snapshot(snapshot),
         true <- snapshot.definition_ref == activation.definition_ref,
         true <- is_map(reflection.content),
         true <-
           get_in(reflection.content, ["effective", "activation", "activation_receipt"]) ==
             activation.activation_receipt,
         true <-
           get_in(reflection.content, ["effective", "activation", "authority_epoch"]) ==
             activation.authority_epoch,
         true <-
           get_in(reflection.content, ["observed", "snapshot_digest"]) == snapshot.digest,
         true <-
           get_in(reflection.content, ["definition_ref"]) ==
             Ref.to_string(activation.definition_ref) do
      :ok
    else
      false -> {:error, :forge_reflection_evidence_mismatch}
      {:error, _reason} = error -> error
      _value -> {:error, :invalid_forge_reflection_projection}
    end
  end

  defp direct_operations(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, operations} ->
      with {:ok, operation} <- Operation.new(value),
           true <- operation.type in @forge_operation_types do
        {:cont, {:ok, [operation | operations]}}
      else
        false -> {:halt, {:error, {:forge_operation_not_allowed, index}}}
        {:error, reason} -> {:halt, {:error, {:invalid_forge_operation, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, operations} -> {:ok, Enum.reverse(operations)}
      {:error, _reason} = error -> error
    end)
  end

  defp approvals(values) when is_list(values) and length(values) <= @max_oracle_approvals do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, approvals} ->
      case OracleApproval.new(value) do
        {:ok, approval} -> {:cont, {:ok, [approval | approvals]}}
        {:error, reason} -> {:halt, {:error, {:invalid_forge_oracle_approval, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, approvals} -> {:ok, Enum.reverse(approvals)}
      {:error, _reason} = error -> error
    end)
  end

  defp approvals(values) when is_list(values),
    do: {:error, {:forge_oracle_approval_limit_exceeded, @max_oracle_approvals}}

  defp approvals(value), do: {:error, {:invalid_forge_oracle_approvals, shape(value)}}

  defp trusted_oracles(values) when is_list(values) and length(values) <= @max_trusted_oracles do
    if Enum.all?(
         values,
         &(is_binary(&1) and &1 != "" and not String.starts_with?(&1, "Elixir."))
       ),
       do: {:ok, values |> Enum.uniq() |> Enum.sort()},
       else: {:error, :invalid_forge_trusted_oracle_refs}
  end

  defp trusted_oracles(values) when is_list(values),
    do: {:error, {:forge_trusted_oracle_limit_exceeded, @max_trusted_oracles}}

  defp trusted_oracles(_value), do: {:error, :invalid_forge_trusted_oracle_refs}

  defp validate_approval_lineage(approvals, critiques) do
    case Enum.find(approvals, &(not approval_matches_critique?(&1, critiques))) do
      nil ->
        :ok

      approval ->
        {:error, {:forge_oracle_approval_without_critique, OracleApproval.ref(approval)}}
    end
  end

  defp approved_case_operations(critiques, approvals, trusted_oracles) do
    critiques
    |> Enum.reduce_while({:ok, %{}}, fn critique, {:ok, cases} ->
      critique
      |> approved_case(approvals, trusted_oracles)
      |> add_approved_case(cases)
    end)
    |> then(fn
      {:ok, cases} ->
        operations =
          cases
          |> Enum.sort_by(fn {id, _case} -> id end)
          |> Enum.map(fn {_id, evaluation_case} ->
            {:ok, operation} =
              Operation.new(%{
                "type" => "add_eval_case",
                "payload" => %{"case" => evaluation_case}
              })

            operation
          end)

        {:ok, operations}

      {:error, _reason} = error ->
        error
    end)
  end

  defp approved_case(%Critique{eval_case: nil}, _approvals, _trusted), do: nil

  defp approved_case(%Critique{} = critique, approvals, trusted) do
    approved? =
      critique.oracle_ref in trusted or
        Enum.any?(approvals, fn approval ->
          OracleApproval.approves?(
            approval,
            Critique.case_digest(critique),
            critique.oracle_ref
          )
        end)

    if approved?, do: critique.eval_case, else: nil
  end

  defp add_approved_case(nil, cases), do: {:cont, {:ok, cases}}

  defp add_approved_case(evaluation_case, cases) do
    id = Map.fetch!(evaluation_case, "id")

    case Map.fetch(cases, id) do
      :error -> {:cont, {:ok, Map.put(cases, id, evaluation_case)}}
      {:ok, ^evaluation_case} -> {:cont, {:ok, cases}}
      {:ok, _different} -> {:halt, {:error, {:conflicting_forge_eval_case, id}}}
    end
  end

  defp approval_matches_critique?(approval, critiques) do
    Enum.any?(critiques, fn critique ->
      OracleApproval.approves?(
        approval,
        Critique.case_digest(critique),
        critique.oracle_ref
      )
    end)
  end

  defp provenance(reflection, snapshot, critiques, approvals, trusted, host, parent) do
    with {:ok, host, redactions} <- Spectre.Experience.Redactor.redact(host) do
      {:ok,
       %{
         "forge" => %{
           "reflection_digest" => reflection.digest,
           "experience_snapshot_digest" => snapshot.digest,
           "critique_digests" => Enum.map(critiques, & &1.digest),
           "oracle_approval_refs" => Enum.map(approvals, &OracleApproval.ref/1),
           "trusted_oracle_refs" => trusted,
           "parent_proposal_digest" => parent
         },
         "host" => host,
         "host_redactions" => redactions
       }}
    end
  end

  defp required(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp required(value, field), do: {:error, {:forge_field_required, field, value}}

  defp timestamp(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp timestamp(value), do: {:error, {:invalid_forge_created_at, value}}

  defp options(opts) do
    if Keyword.keyword?(opts) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: {:error, :invalid_forge_options}
  end

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
