defmodule Spectre.Forge.Proposal do
  @moduledoc """
  Content-addressed Forge output wrapping an inert governance ChangeSet.

  A Proposal carries Reflection, Experience, critic and oracle lineage. It has
  no activation capability and is useful only when passed to the trusted
  governance Composer as its contained ChangeSet.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Forge.Critique
  alias Spectre.Forge.OracleApproval
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.Data

  @schema_version 1
  @max_critiques 16
  @direct_operation_types ~w(
    disable_skill mount_skill replace_skill select_state_migration
    update_applicability update_skill_config
  )
  @fields [
    :schema_version,
    :change_set,
    :reflection_digest,
    :experience_snapshot_digest,
    :critiques,
    :oracle_approvals,
    :trusted_oracle_refs,
    :parent_proposal_digest,
    :digest
  ]

  @enforce_keys @fields
  defstruct schema_version: @schema_version,
            change_set: nil,
            reflection_digest: nil,
            experience_snapshot_digest: nil,
            critiques: [],
            oracle_approvals: [],
            trusted_oracle_refs: [],
            parent_proposal_digest: nil,
            digest: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          change_set: ChangeSet.t(),
          reflection_digest: String.t(),
          experience_snapshot_digest: String.t(),
          critiques: [Critique.t()],
          oracle_approvals: [OracleApproval.t()],
          trusted_oracle_refs: [String.t()],
          parent_proposal_digest: String.t() | nil,
          digest: String.t()
        }

  @doc "Returns the Forge Proposal transport schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and seals a Forge Proposal."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = proposal) do
    proposal |> to_data() |> new()
  rescue
    exception -> {:error, {:invalid_forge_proposal_struct, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:invalid_forge_proposal_struct, kind}}
  end

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_forge_proposal, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with :ok <- exact_fields(attrs),
         @schema_version <- value(attrs, :schema_version, @schema_version),
         {:ok, change_set} <- ChangeSet.new(value(attrs, :change_set)),
         :ok <- digest(value(attrs, :reflection_digest), :reflection_digest),
         :ok <- digest(value(attrs, :experience_snapshot_digest), :experience_snapshot_digest),
         {:ok, critiques} <- critiques(value(attrs, :critiques, [])),
         {:ok, approvals} <- approvals(value(attrs, :oracle_approvals, [])),
         {:ok, trusted_oracles} <- trusted_oracles(value(attrs, :trusted_oracle_refs, [])),
         :ok <- unique_lineage(critiques, approvals),
         :ok <- optional_digest(value(attrs, :parent_proposal_digest), :parent_proposal_digest),
         base = %{
           schema_version: @schema_version,
           change_set: change_set,
           reflection_digest: value(attrs, :reflection_digest),
           experience_snapshot_digest: value(attrs, :experience_snapshot_digest),
           critiques: critiques,
           oracle_approvals: approvals,
           trusted_oracle_refs: trusted_oracles,
           parent_proposal_digest: value(attrs, :parent_proposal_digest)
         },
         :ok <- verify_lineage(base),
         expected = content_digest(base),
         :ok <- supplied_digest(value(attrs, :digest), expected) do
      {:ok, struct!(__MODULE__, Map.put(base, :digest, expected))}
    else
      version when is_integer(version) -> {:error, {:unsupported_forge_proposal_schema, version}}
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_forge_proposal, shape(value)}}
    end
  end

  def new(value), do: {:error, {:invalid_forge_proposal, shape(value)}}

  @doc "Returns portable Proposal data."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = proposal) do
    %{
      "schema_version" => proposal.schema_version,
      "change_set" => ChangeSet.to_data(proposal.change_set),
      "reflection_digest" => proposal.reflection_digest,
      "experience_snapshot_digest" => proposal.experience_snapshot_digest,
      "critiques" => Enum.map(proposal.critiques, &Critique.to_data/1),
      "oracle_approvals" => Enum.map(proposal.oracle_approvals, &OracleApproval.to_data/1),
      "trusted_oracle_refs" => proposal.trusted_oracle_refs,
      "parent_proposal_digest" => proposal.parent_proposal_digest,
      "digest" => proposal.digest
    }
  end

  @doc "Restores a Proposal from decoded transport data."
  def from_data(data), do: new(data)

  @doc "Encodes a Proposal with the production canonical codec."
  def encode(%__MODULE__{} = proposal), do: proposal |> to_data() |> Value.encode()

  @doc "Decodes and verifies a Proposal."
  def decode(encoded) when is_binary(encoded) do
    with {:ok, data} <- Value.decode(encoded), do: from_data(data)
  end

  def decode(value), do: {:error, {:invalid_forge_proposal_binary, shape(value)}}

  @doc "Returns the stable textual Proposal reference."
  @spec ref(t()) :: String.t()
  def ref(%__MODULE__{digest: digest}), do: "forge-proposal:sha256:" <> digest

  @doc "Revalidates the complete Proposal."
  @spec verify(t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = proposal) do
    case proposal |> to_data() |> from_data() do
      {:ok, ^proposal} -> :ok
      {:ok, _other} -> {:error, :forge_proposal_integrity_mismatch}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, {:invalid_forge_proposal_struct, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:invalid_forge_proposal_struct, kind}}
  end

  defp content_digest(base) do
    Value.digest!(%{
      "schema_version" => base.schema_version,
      "change_set" => ChangeSet.to_data(base.change_set),
      "reflection_digest" => base.reflection_digest,
      "experience_snapshot_digest" => base.experience_snapshot_digest,
      "critiques" => Enum.map(base.critiques, &Critique.to_data/1),
      "oracle_approvals" => Enum.map(base.oracle_approvals, &OracleApproval.to_data/1),
      "trusted_oracle_refs" => base.trusted_oracle_refs,
      "parent_proposal_digest" => base.parent_proposal_digest
    })
  end

  defp exact_fields(attrs) do
    aliases = Enum.flat_map(@fields, &[&1, Atom.to_string(&1)])
    collisions = Data.alias_collisions(attrs, @fields)

    case {Map.keys(attrs) -- aliases, collisions} do
      {[], []} ->
        :ok

      {unknown, []} ->
        {:error, {:unknown_forge_proposal_fields, Enum.sort_by(unknown, &inspect/1)}}

      {_unknown, collisions} ->
        {:error, {:ambiguous_forge_proposal_fields, collisions}}
    end
  end

  defp critiques(values) when is_list(values) and length(values) <= @max_critiques do
    restore(values, Critique)
  end

  defp critiques(values) when is_list(values),
    do: {:error, {:forge_critique_limit_exceeded, length(values), @max_critiques}}

  defp critiques(value), do: {:error, {:invalid_forge_critiques, shape(value)}}

  defp approvals(values) when is_list(values) and length(values) <= @max_critiques do
    restore(values, OracleApproval)
  end

  defp approvals(values) when is_list(values),
    do: {:error, {:forge_oracle_approval_limit_exceeded, length(values), @max_critiques}}

  defp approvals(value), do: {:error, {:invalid_forge_oracle_approvals, shape(value)}}

  defp restore(values, module) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, result} ->
      case module.new(value) do
        {:ok, restored} -> {:cont, {:ok, [restored | result]}}
        {:error, reason} -> {:halt, {:error, {:invalid_forge_lineage_item, index, reason}}}
      end
    end)
    |> then(fn
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end)
  end

  defp unique_lineage(critiques, approvals) do
    critique_digests = Enum.map(critiques, & &1.digest)
    approval_refs = Enum.map(approvals, &OracleApproval.ref/1)

    if length(critique_digests) == length(Enum.uniq(critique_digests)) and
         length(approval_refs) == length(Enum.uniq(approval_refs)),
       do: :ok,
       else: {:error, :duplicate_forge_lineage}
  end

  defp trusted_oracles(values) when is_list(values) do
    if Enum.all?(
         values,
         &(is_binary(&1) and &1 != "" and not String.starts_with?(&1, "Elixir."))
       ),
       do: {:ok, values |> Enum.uniq() |> Enum.sort()},
       else: {:error, :invalid_forge_trusted_oracle_refs}
  end

  defp trusted_oracles(_value), do: {:error, :invalid_forge_trusted_oracle_refs}

  defp verify_lineage(base) do
    with :ok <- critique_evidence(base),
         :ok <- approval_evidence(base),
         :ok <- operation_evidence(base) do
      provenance_evidence(base)
    end
  end

  defp critique_evidence(base) do
    if Enum.all?(base.critiques, fn critique ->
         critique.reflection_digest == base.reflection_digest and
           critique.experience_snapshot_digest == base.experience_snapshot_digest
       end),
       do: :ok,
       else: {:error, :forge_critique_evidence_mismatch}
  end

  defp approval_evidence(base) do
    case Enum.find(
           base.oracle_approvals,
           &(not approval_matches_critique?(&1, base.critiques))
         ) do
      nil -> :ok
      _approval -> {:error, :forge_oracle_approval_without_critique}
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

  defp operation_evidence(base) do
    with :ok <- allowed_operation_types(base.change_set.operations),
         {:ok, expected} <- expected_case_data(base),
         {:ok, actual} <- operation_case_data(base.change_set.operations),
         true <- expected == actual do
      :ok
    else
      false -> {:error, :forge_eval_case_lineage_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp allowed_operation_types(operations) do
    allowed = @direct_operation_types ++ ["add_eval_case"]

    case Enum.find(operations, &(&1.type not in allowed)) do
      nil -> :ok
      operation -> {:error, {:forge_operation_not_allowed, operation.type}}
    end
  end

  defp expected_case_data(base) do
    base.critiques
    |> Enum.reduce_while({:ok, %{}}, fn critique, {:ok, cases} ->
      if approved?(critique, base.oracle_approvals, base.trusted_oracle_refs) do
        add_case(cases, critique.eval_case)
      else
        {:cont, {:ok, cases}}
      end
    end)
    |> case_data_result()
  end

  defp operation_case_data(operations) do
    operations
    |> Enum.filter(&(&1.type == "add_eval_case"))
    |> Enum.reduce_while({:ok, %{}}, fn operation, {:ok, cases} ->
      case operation.payload do
        %{"case" => evaluation_case} when map_size(operation.payload) == 1 ->
          add_case(cases, evaluation_case)

        _payload ->
          {:halt, {:error, :invalid_forge_eval_case_operation}}
      end
    end)
    |> case_data_result()
  end

  defp add_case(cases, nil), do: {:cont, {:ok, cases}}

  defp add_case(cases, %{"id" => id} = evaluation_case) when is_binary(id) do
    case Map.fetch(cases, id) do
      :error -> {:cont, {:ok, Map.put(cases, id, evaluation_case)}}
      {:ok, ^evaluation_case} -> {:cont, {:ok, cases}}
      {:ok, _different} -> {:halt, {:error, {:conflicting_forge_eval_case, id}}}
    end
  end

  defp add_case(_cases, _value), do: {:halt, {:error, :invalid_forge_eval_case}}

  defp case_data_result({:ok, cases}), do: {:ok, Enum.sort(cases)}
  defp case_data_result({:error, _reason} = error), do: error

  defp approved?(%Critique{eval_case: nil}, _approvals, _trusted), do: false

  defp approved?(critique, approvals, trusted) do
    critique.oracle_ref in trusted or
      Enum.any?(approvals, fn approval ->
        OracleApproval.approves?(
          approval,
          Critique.case_digest(critique),
          critique.oracle_ref
        )
      end)
  end

  defp provenance_evidence(base) do
    forge = Map.get(base.change_set.provenance, "forge")

    expected = %{
      "reflection_digest" => base.reflection_digest,
      "experience_snapshot_digest" => base.experience_snapshot_digest,
      "critique_digests" => Enum.map(base.critiques, & &1.digest),
      "oracle_approval_refs" => Enum.map(base.oracle_approvals, &OracleApproval.ref/1),
      "trusted_oracle_refs" => base.trusted_oracle_refs,
      "parent_proposal_digest" => base.parent_proposal_digest
    }

    if forge == expected,
      do: :ok,
      else: {:error, :forge_proposal_provenance_mismatch}
  end

  defp optional_digest(nil, _field), do: :ok
  defp optional_digest(value, field), do: digest(value, field)

  defp digest(value, _field) when is_binary(value) and byte_size(value) == 64 do
    if match?({:ok, <<_::256>>}, Base.decode16(value, case: :lower)),
      do: :ok,
      else: {:error, {:invalid_forge_proposal_digest, value}}
  end

  defp digest(value, field), do: {:error, {:invalid_forge_proposal_digest, field, value}}

  defp supplied_digest(nil, _expected), do: :ok
  defp supplied_digest(expected, expected), do: :ok
  defp supplied_digest(_supplied, _expected), do: {:error, :forge_proposal_digest_mismatch}

  defp value(attrs, key, default \\ nil),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
