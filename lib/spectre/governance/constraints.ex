defmodule Spectre.Governance.Constraints do
  @moduledoc false

  alias Spectre.Authority.Envelope
  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Governance.Data
  alias Spectre.Skill.Applicability
  alias Spectre.Skill.Definition, as: SkillDefinition

  @enforce_keys [:prompt_token_ceiling, :applicability_ceilings]
  defstruct prompt_token_ceiling: nil, applicability_ceilings: %{}

  @type t :: %__MODULE__{
          prompt_token_ceiling: non_neg_integer() | nil,
          applicability_ceilings: %{optional(String.t()) => map()}
        }

  @spec new(Envelope.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(%Envelope{} = authority, opts) when is_list(opts) do
    with {:ok, configured} <- prompt_ceiling(Keyword.get(opts, :prompt_token_ceiling)),
         {:ok, granted} <- prompt_ceiling(Map.get(authority.limits, :max_tokens)),
         {:ok, ceilings} <-
           normalize_applicability_ceilings(Keyword.get(opts, :applicability_ceilings, %{})) do
      {:ok,
       %__MODULE__{
         prompt_token_ceiling: strictest_ceiling(configured, granted),
         applicability_ceilings: ceilings
       }}
    end
  end

  def new(%Envelope{}, value), do: {:error, {:invalid_governance_constraint_options, value}}

  @spec restore(term(), term()) :: {:ok, t()} | {:error, term()}
  def restore(prompt_token_ceiling, applicability_ceilings) do
    with {:ok, prompt_token_ceiling} <- prompt_ceiling(prompt_token_ceiling),
         {:ok, applicability_ceilings} <-
           normalize_applicability_ceilings(applicability_ceilings) do
      {:ok,
       %__MODULE__{
         prompt_token_ceiling: prompt_token_ceiling,
         applicability_ceilings: applicability_ceilings
       }}
    end
  end

  @spec normalize_applicability_ceilings(term()) :: {:ok, map()} | {:error, term()}
  def normalize_applicability_ceilings(value) do
    with {:ok, normalized} <- Data.normalize_map(value) do
      Enum.reduce_while(normalized, {:ok, %{}}, &normalize_applicability_ceiling/2)
    end
  end

  @spec verify_definition(Canonical.t(), Envelope.t(), t()) :: :ok | {:error, term()}
  def verify_definition(
        %Canonical{} = definition,
        %Envelope{} = authority,
        %__MODULE__{} = constraints
      ) do
    with {:ok, mounts} <- mounted_skills(definition),
         :ok <- verify_prompt_window(mounts, authority, constraints.prompt_token_ceiling) do
      verify_applicability_ceilings(mounts, constraints.applicability_ceilings)
    end
  end

  @spec within_applicability_ceiling(Applicability.t(), Applicability.t()) ::
          :ok | {:error, term()}
  def within_applicability_ceiling(%Applicability{} = value, %Applicability{} = ceiling) do
    checks = [
      scopes_within_ceiling?(value.scopes, ceiling.scopes),
      subset?(ceiling.required_tags, value.required_tags),
      subset?(ceiling.forbidden_tags, value.forbidden_tags),
      subset?(ceiling.conflicts, value.conflicts)
    ]

    if Enum.all?(checks), do: :ok, else: {:error, :skill_applicability_ceiling_exceeded}
  end

  defp verify_prompt_window(mounts, authority, ceiling) do
    with :ok <- verify_skill_authority(mounts, authority) do
      reserved_tokens =
        Enum.reduce(mounts, 0, fn {_mount_id, skill}, total ->
          total + SkillDefinition.prompt_budget(skill).reserved_tokens
        end)

      cond do
        reserved_tokens == 0 ->
          :ok

        is_nil(ceiling) ->
          {:error, :governance_prompt_budget_not_granted}

        reserved_tokens > ceiling ->
          {:error, {:governance_prompt_window_exceeded, reserved_tokens, ceiling}}

        true ->
          :ok
      end
    end
  end

  defp verify_skill_authority(mounts, authority) do
    Enum.reduce_while(mounts, :ok, fn {_mount_id, skill}, :ok ->
      with :ok <- verify_operations(skill, authority),
           :ok <- verify_prompt_classes(skill, authority) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp verify_operations(skill, authority) do
    case Enum.find(SkillDefinition.operation_refs(skill), fn ref ->
           not Enum.any?(authority.operations, &same_name?(&1, ref))
         end) do
      nil -> :ok
      ref -> {:error, {:governance_operation_authority_exceeded, ref}}
    end
  end

  defp verify_prompt_classes(skill, authority) do
    case Enum.find(SkillDefinition.prompt_fragments(skill), fn fragment ->
           not Enum.any?(authority.prompt_budget_classes, &same_name?(&1, fragment.budget_class))
         end) do
      nil -> :ok
      fragment -> {:error, {:governance_prompt_budget_class_not_granted, fragment.budget_class}}
    end
  end

  defp verify_applicability_ceilings(mounts, ceilings) do
    Enum.reduce_while(mounts, :ok, &verify_applicability_ceiling(&1, &2, ceilings))
  end

  defp normalize_applicability_ceiling({mount_id, ceiling}, {:ok, acc}) do
    with true <- valid_mount_id?(mount_id),
         {:ok, ceiling} <- Applicability.new(ceiling),
         {:ok, portable} <- ceiling |> Applicability.to_data() |> Data.normalize_map() do
      {:cont, {:ok, Map.put(acc, mount_id, portable)}}
    else
      false ->
        {:halt, {:error, {:invalid_skill_applicability_ceiling_mount, mount_id}}}

      {:error, reason} ->
        {:halt, {:error, {:invalid_skill_applicability_ceiling, mount_id, reason}}}
    end
  end

  defp verify_applicability_ceiling({mount_id, skill}, :ok, ceilings) do
    case Map.fetch(ceilings, mount_id) do
      :error ->
        {:cont, :ok}

      {:ok, ceiling_data} ->
        verify_applicability_ceiling(skill, ceiling_data)
    end
  end

  defp verify_applicability_ceiling(skill, ceiling_data) do
    with {:ok, ceiling} <- Applicability.new(ceiling_data),
         :ok <- within_applicability_ceiling(SkillDefinition.applicability(skill), ceiling) do
      {:cont, :ok}
    else
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp mounted_skills(definition) do
    with {:ok, component} <- Canonical.fetch_component(definition, :skills),
         payload when is_map(payload) <- component.payload,
         mounts when is_list(mounts) <- get(payload, :mounts, []) do
      mounts
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, &restore_mount/2)
      |> then(fn
        {:ok, restored} -> {:ok, Enum.reverse(restored)}
        {:error, _reason} = error -> error
      end)
    else
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_governance_skill_mounts, shape(value)}}
    end
  end

  defp restore_mount({mount, index}, {:ok, restored}) when is_map(mount) do
    case {get(mount, :id), get(mount, :definition)} do
      {mount_id, data} when is_binary(mount_id) and mount_id != "" and is_map(data) ->
        with {:ok, canonical} <- Canonical.from_data(data),
             {:ok, skill} <- SkillDefinition.from_canonical(canonical) do
          {:cont, {:ok, [{mount_id, skill} | restored]}}
        else
          {:error, reason} ->
            {:halt, {:error, {:invalid_governed_skill_mount, index, reason}}}
        end

      {_mount_id, data} when not is_map(data) ->
        {:cont, {:ok, restored}}

      _other ->
        {:halt, {:error, {:invalid_governed_skill_mount, index}}}
    end
  end

  defp restore_mount({_mount, index}, _acc),
    do: {:halt, {:error, {:invalid_governed_skill_mount, index}}}

  # An empty declaration is a wildcard. It cannot be a subset of a finite scope ceiling.
  defp scopes_within_ceiling?(_values, []), do: true
  defp scopes_within_ceiling?([], _finite_ceiling), do: false
  defp scopes_within_ceiling?(values, ceiling), do: subset?(values, ceiling)

  defp subset?(left, right),
    do: Enum.all?(left, fn item -> Enum.any?(right, &same_name?(&1, item)) end)

  defp prompt_ceiling(nil), do: {:ok, nil}
  defp prompt_ceiling(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp prompt_ceiling(value),
    do: {:error, {:invalid_governance_prompt_token_ceiling, value}}

  defp strictest_ceiling(nil, nil), do: nil
  defp strictest_ceiling(left, nil), do: left
  defp strictest_ceiling(nil, right), do: right
  defp strictest_ceiling(left, right), do: min(left, right)

  defp valid_mount_id?(value) when is_binary(value) and value != "",
    do: not String.starts_with?(value, "Elixir.")

  defp valid_mount_id?(_value), do: false

  defp same_name?(left, right) when is_atom(left), do: same_name?(Atom.to_string(left), right)
  defp same_name?(left, right) when is_atom(right), do: same_name?(left, Atom.to_string(right))
  defp same_name?(left, right) when is_binary(left) and is_binary(right), do: left == right

  defp same_name?(left, right) do
    case {Value.encode(left), Value.encode(right)} do
      {{:ok, left}, {:ok, right}} -> left == right
      _other -> false
    end
  end

  defp get(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
