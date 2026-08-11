defmodule Spectre.Morph.Surface.Policy do
  @moduledoc """
  Applies the immutable Morph proposal ceiling to governance operations.

  The policy computes the meet between the compiled Surface and host-provided
  ceilings during composition, then re-derives the parent-to-candidate diff at
  activation. Transient Change fields are never authority-bearing inputs.
  """

  alias Spectre.Definition.Canonical
  alias Spectre.Governance.ChangeSet.Operation
  alias Spectre.Governance.Constraints
  alias Spectre.Morph.Surface
  alias Spectre.Morph.Surface.MountIndex
  alias Spectre.Morph.Surface.Mutation
  alias Spectre.Skill.Applicability

  @doc false
  @spec constrain(Surface.t(), [Operation.t()], keyword()) ::
          {:ok, keyword()} | {:error, term()}
  def constrain(%Surface{} = surface, operations, opts) do
    with :ok <- permitted_operations(surface, operations),
         {:ok, mount_ids} <- changed_mount_ids(surface, operations),
         {:ok, ceilings} <-
           meet_ceilings(
             surface,
             mount_ids,
             Keyword.get(opts, :applicability_ceilings, %{})
           ),
         {:ok, prompt_ceiling} <-
           meet_prompt_ceiling(
             surface.prompt_token_ceiling,
             Keyword.get(opts, :prompt_token_ceiling)
           ) do
      {:ok,
       opts
       |> Keyword.put(:applicability_ceilings, ceilings)
       |> Keyword.put(:prompt_token_ceiling, prompt_ceiling)}
    end
  end

  @doc false
  @spec verify(
          Surface.t(),
          Canonical.t(),
          Canonical.t(),
          number() | nil,
          map() | nil
        ) :: :ok | {:error, term()}
  def verify(surface, parent, candidate, prompt_ceiling, ceilings) do
    with {:ok, candidate_surface} <- Surface.from_canonical(candidate),
         true <- candidate_surface == surface,
         :ok <- unchanged_non_skill_components(parent, candidate),
         {:ok, mutations} <- MountIndex.mutations(parent, candidate),
         :ok <- permitted_mutations(surface, mutations),
         :ok <- persisted_prompt_ceiling(surface, prompt_ceiling),
         :ok <- persisted_applicability_ceilings(surface, mutations, ceilings) do
      :ok
    else
      false -> {:error, :governance_change_surface_is_immutable}
      {:error, _reason} = error -> error
    end
  end

  @spec permitted_operations(Surface.t(), [Operation.t()]) :: :ok | {:error, term()}
  defp permitted_operations(surface, operations) do
    # Candidate evaluation cases are internal proof obligations, not proposal
    # authority. They may accompany a permitted Skill mutation but cannot
    # alter the Definition by themselves.
    case Enum.find(operations, fn operation ->
           operation.type != "add_eval_case" and not Surface.allows?(surface, operation.type)
         end) do
      nil -> :ok
      operation -> {:error, {:morph_operation_outside_surface, operation.type}}
    end
  end

  @spec changed_mount_ids(Surface.t(), [Operation.t()]) ::
          {:ok, [String.t()]} | {:error, term()}
  defp changed_mount_ids(surface, operations) do
    operations
    |> Enum.reduce_while({:ok, MapSet.new()}, fn operation, {:ok, ids} ->
      case changed_mount_id(surface, operation) do
        :skip -> {:cont, {:ok, ids}}
        {:ok, mount_id} -> {:cont, {:ok, MapSet.put(ids, mount_id)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, ids} -> {:ok, Enum.sort(ids)}
      {:error, _reason} = error -> error
    end)
  end

  @spec changed_mount_id(Surface.t(), Operation.t()) ::
          :skip | {:ok, String.t()} | {:error, term()}
  defp changed_mount_id(_surface, %Operation{type: "add_eval_case"}), do: :skip

  defp changed_mount_id(surface, %Operation{type: type, payload: payload}) do
    mount_id = Map.get(payload, "mount_id")

    cond do
      not Surface.allows?(surface, type) ->
        {:error, {:morph_operation_outside_surface, type}}

      valid_mount_id?(mount_id) ->
        {:ok, mount_id}

      true ->
        {:error, {:invalid_morph_surface_mount_id, mount_id}}
    end
  end

  @spec valid_mount_id?(term()) :: boolean()
  defp valid_mount_id?(value) do
    is_binary(value) and value != "" and not String.starts_with?(value, "Elixir.")
  end

  @spec meet_prompt_ceiling(number(), term()) :: {:ok, number()} | {:error, term()}
  defp meet_prompt_ceiling(declared, nil), do: {:ok, declared}

  defp meet_prompt_ceiling(declared, configured)
       when is_number(configured) and configured >= 0,
       do: {:ok, min(declared, configured)}

  defp meet_prompt_ceiling(_declared, configured),
    do: {:error, {:invalid_morph_prompt_ceiling, configured}}

  @spec meet_ceilings(Surface.t(), [String.t()], term()) ::
          {:ok, map()} | {:error, term()}
  defp meet_ceilings(surface, mount_ids, configured) do
    with {:ok, normalized} <- Constraints.normalize_applicability_ceilings(configured) do
      reduce_declared_ceilings(surface, mount_ids, normalized)
    end
  end

  @spec reduce_declared_ceilings(Surface.t(), [String.t()], map()) ::
          {:ok, map()} | {:error, term()}
  defp reduce_declared_ceilings(surface, mount_ids, configured) do
    surface
    |> Surface.applicability_ceilings(mount_ids)
    |> Enum.reduce_while({:ok, configured}, fn {mount_id, declared}, {:ok, acc} ->
      case merge_declared_ceiling(acc, mount_id, declared) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec merge_declared_ceiling(map(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defp merge_declared_ceiling(configured, mount_id, declared_data) do
    with {:ok, declared} <- Applicability.new(declared_data) do
      merge_configured_ceiling(configured, mount_id, declared)
    end
  end

  @spec merge_configured_ceiling(map(), String.t(), Applicability.t()) ::
          {:ok, map()} | {:error, term()}
  defp merge_configured_ceiling(configured, mount_id, declared) do
    case Map.fetch(configured, mount_id) do
      :error ->
        {:ok, Map.put(configured, mount_id, Applicability.to_data(declared))}

      {:ok, configured_data} ->
        with {:ok, ceiling} <- Applicability.new(configured_data),
             :ok <- Constraints.within_applicability_ceiling(ceiling, declared) do
          {:ok, configured}
        end
    end
  end

  @spec unchanged_non_skill_components(Canonical.t(), Canonical.t()) ::
          :ok | {:error, :morph_changed_component_outside_surface}
  defp unchanged_non_skill_components(parent, candidate) do
    if non_skill_components(parent) == non_skill_components(candidate),
      do: :ok,
      else: {:error, :morph_changed_component_outside_surface}
  end

  @spec non_skill_components(Canonical.t()) :: [Spectre.Definition.Component.t()]
  defp non_skill_components(canonical) do
    Enum.reject(canonical.components, &(&1.component_type == :skills))
  end

  @spec permitted_mutations(Surface.t(), [Mutation.t()]) :: :ok | {:error, term()}
  defp permitted_mutations(surface, mutations) do
    case Enum.find(mutations, &(not Surface.allows?(surface, &1.operation))) do
      nil ->
        :ok

      mutation ->
        operation = Atom.to_string(mutation.operation)
        {:error, {:morph_operation_outside_surface, operation, mutation.mount_id}}
    end
  end

  @spec persisted_prompt_ceiling(Surface.t(), term()) :: :ok | {:error, term()}
  defp persisted_prompt_ceiling(surface, value)
       when is_number(value) and value >= 0 and value <= surface.prompt_token_ceiling,
       do: :ok

  defp persisted_prompt_ceiling(surface, value),
    do: {:error, {:morph_prompt_ceiling_not_sealed, value, surface.prompt_token_ceiling}}

  @spec persisted_applicability_ceilings(Surface.t(), [Mutation.t()], term()) ::
          :ok | {:error, term()}
  defp persisted_applicability_ceilings(surface, mutations, ceilings) do
    with {:ok, normalized} <- Constraints.normalize_applicability_ceilings(ceilings) do
      mount_ids = Enum.map(mutations, & &1.mount_id)

      surface
      |> Surface.applicability_ceilings(mount_ids)
      |> verify_persisted_applicability_ceilings(normalized)
    end
  end

  @spec verify_persisted_applicability_ceilings(map(), map()) :: :ok | {:error, term()}
  defp verify_persisted_applicability_ceilings(declared, ceilings) do
    Enum.reduce_while(declared, :ok, fn {mount_id, declared_data}, :ok ->
      case persisted_applicability_ceiling(ceilings, mount_id, declared_data) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec persisted_applicability_ceiling(map(), String.t(), map()) ::
          :ok | {:error, term()}
  defp persisted_applicability_ceiling(ceilings, mount_id, declared_data) do
    with {:ok, persisted_data} <- Map.fetch(ceilings, mount_id),
         {:ok, persisted} <- Applicability.new(persisted_data),
         {:ok, declared} <- Applicability.new(declared_data),
         :ok <- Constraints.within_applicability_ceiling(persisted, declared) do
      :ok
    else
      :error -> {:error, {:morph_applicability_ceiling_not_sealed, mount_id}}
      {:error, _reason} = error -> error
    end
  end
end
