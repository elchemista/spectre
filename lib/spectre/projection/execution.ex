defmodule Spectre.Projection.Execution do
  @moduledoc """
  Deterministic, privacy-safe view of one data-driven Work materialization.

  The projection binds an exact Skill Definition and program to resolved input
  evidence and prompt receipts. It contains digests and placement metadata,
  never prompt text, input values, callbacks, model clients, or authority.
  """

  @behaviour Spectre.Projection

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref
  alias Spectre.Execution.Program
  alias Spectre.Prompt.Receipt
  alias Spectre.Skill.Definition, as: SkillDefinition

  @generator_id "spectre.projection.execution"
  @generator_version 1

  @impl true
  @spec id() :: String.t()
  def id, do: @generator_id

  @impl true
  @spec version() :: pos_integer()
  def version, do: @generator_version

  @impl true
  @spec project(Canonical.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def project(%Canonical{} = canonical, opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, definition} <- SkillDefinition.from_canonical(canonical),
         {:ok, program} <- program_option(Keyword.get(opts, :program)),
         {:ok, declared} <- SkillDefinition.work(definition, program.id),
         :ok <- exact_program(declared, program),
         {:ok, input_digest} <- Value.digest(Keyword.get(opts, :input)),
         {:ok, receipts} <- receipts(Keyword.get(opts, :prompt_receipts, [])),
         :ok <- receipt_set(program, receipts, Ref.to_string(definition.ref)),
         {:ok, plan_digests} <- plan_digests(Keyword.get(opts, :plan_digests, %{}), program),
         {:ok, route} <- portable_map(Keyword.get(opts, :route, %{}), :route),
         {:ok, mount_id} <- portable_value(Keyword.get(opts, :mount_id), :mount_id),
         {:ok, continuation_id} <- continuation_id(Keyword.get(opts, :continuation_id)) do
      {:ok,
       %{
         schema_version: 1,
         definition_ref: Ref.to_string(definition.ref),
         program: %{id: program.id, version: program.version, digest: program.digest},
         mount_id: mount_id,
         route: route,
         continuation_id: continuation_id,
         input_evidence_digest: input_digest,
         plan_digests: plan_digests,
         prompt_receipts: Enum.map(receipts, &receipt_summary/1),
         budget: program.budget
       }}
    else
      false -> {:error, {:invalid_execution_projection_options, :list}}
      {:error, _reason} = error -> error
    end
  end

  def project(%Canonical{}, opts),
    do: {:error, {:invalid_execution_projection_options, shape(opts)}}

  @spec program_option(term()) :: {:ok, Program.t()} | {:error, term()}
  defp program_option(%Program{} = program), do: Program.new(program)
  defp program_option(value), do: {:error, {:invalid_execution_projection_program, shape(value)}}

  @spec exact_program(Program.t(), Program.t()) :: :ok | {:error, term()}
  defp exact_program(%Program{digest: digest}, %Program{digest: digest}), do: :ok

  defp exact_program(declared, supplied),
    do: {:error, {:execution_projection_program_mismatch, declared.digest, supplied.digest}}

  @spec receipts(term()) :: {:ok, [Receipt.t()]} | {:error, term()}
  defp receipts(values) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      result =
        case value do
          %Receipt{} = receipt -> receipt |> Receipt.to_data() |> Receipt.from_data()
          data when is_map(data) -> Receipt.from_data(data)
          other -> {:error, {:invalid_prompt_receipt, shape(other)}}
        end

      case result do
        {:ok, receipt} ->
          {:cont, {:ok, [receipt | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_execution_projection_receipt, index, reason}}}
      end
    end)
    |> case do
      {:ok, receipts} -> {:ok, Enum.sort_by(receipts, &stable_name(&1.prompt_ref))}
      {:error, _reason} = error -> error
    end
  end

  defp receipts(value),
    do: {:error, {:invalid_execution_projection_receipts, shape(value)}}

  @spec receipt_set(Program.t(), [Receipt.t()], String.t()) :: :ok | {:error, term()}
  defp receipt_set(program, receipts, definition_ref) do
    expected = Enum.sort(program.prompt_refs)
    actual = receipts |> Enum.map(&stable_name(&1.prompt_ref)) |> Enum.sort()

    cond do
      expected != actual ->
        {:error, {:execution_projection_prompt_set_mismatch, expected, actual}}

      Enum.any?(receipts, &(&1.definition_ref != definition_ref)) ->
        {:error, :execution_projection_receipt_definition_mismatch}

      true ->
        :ok
    end
  end

  @spec plan_digests(term(), Program.t()) :: {:ok, map()} | {:error, term()}
  defp plan_digests(value, program) when is_map(value) and not is_struct(value) do
    entries = Enum.map(value, fn {key, digest} -> {stable_name(key), digest} end)
    normalized = Map.new(entries)

    cond do
      map_size(normalized) != length(entries) ->
        {:error, :duplicate_execution_projection_plan_ref}

      Enum.sort(Map.keys(normalized)) != Enum.sort(program.prompt_refs) ->
        {:error, :execution_projection_plan_set_mismatch}

      Enum.any?(normalized, fn {_key, digest} ->
        not valid_digest?(digest)
      end) ->
        {:error, :invalid_execution_projection_plan_digest}

      true ->
        {:ok, normalized}
    end
  end

  defp plan_digests(value, _program),
    do: {:error, {:invalid_execution_projection_plan_digests, shape(value)}}

  @spec portable_map(term(), atom()) :: {:ok, map()} | {:error, term()}
  defp portable_map(value, field) when is_map(value) and not is_struct(value) do
    case Value.validate(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, {:nonportable_execution_projection_field, field, reason}}
    end
  end

  defp portable_map(value, field),
    do: {:error, {:invalid_execution_projection_field, field, shape(value)}}

  @spec portable_value(term(), atom()) :: {:ok, term()} | {:error, term()}
  defp portable_value(value, field) do
    case Value.validate(value) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, {:nonportable_execution_projection_field, field, reason}}
    end
  end

  @spec continuation_id(term()) :: {:ok, String.t()} | {:error, term()}
  defp continuation_id(value) when is_binary(value) and value != "", do: {:ok, value}

  defp continuation_id(value),
    do: {:error, {:invalid_execution_projection_continuation, value}}

  @spec receipt_summary(Receipt.t()) :: map()
  defp receipt_summary(receipt) do
    receipt
    |> Receipt.to_data()
    |> Map.take([
      :prompt_ref,
      :fragment_digest,
      :rendered_digest,
      :input_evidence_digest,
      :placement,
      :provenance_digest,
      :bytes,
      :estimated_tokens,
      :digest
    ])
  end

  @spec valid_digest?(term()) :: boolean()
  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: match?({:ok, _bytes}, Base.decode16(digest, case: :lower))

  defp valid_digest?(_digest), do: false

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
