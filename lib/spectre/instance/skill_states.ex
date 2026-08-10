defmodule Spectre.Instance.SkillStates do
  @moduledoc false

  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Instance.Activation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Commit
  alias Spectre.Instance.Events
  alias Spectre.Instance.Loops
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Skill.StateBinding

  @type section :: %{
          optional(String.t()) => %{
            required(:active_branch) => String.t() | nil,
            required(:branches) => %{optional(String.t()) => StateBinding.t()}
          }
        }

  @spec fetch(InstanceState.t(), atom() | String.t(), keyword()) ::
          {:ok, StateBinding.t()} | {:error, term()}
  def fetch(%InstanceState{} = data, skill_id, opts \\ []) when is_list(opts) do
    with {:ok, skill_id} <- normalize_skill_id(skill_id),
         {:ok, entry} <- fetch_entry(skill_states(data), skill_id) do
      select_binding(entry, Keyword.get(opts, :branch_id, :active))
    end
  end

  @spec list(InstanceState.t(), atom() | String.t(), keyword()) ::
          {:ok, [StateBinding.t()]} | {:error, term()}
  def list(%InstanceState{} = data, skill_id, opts \\ []) when is_list(opts) do
    with {:ok, skill_id} <- normalize_skill_id(skill_id),
         {:ok, entry} <- fetch_entry(skill_states(data), skill_id) do
      include_purged? = Keyword.get(opts, :include_purged?, false)

      branches =
        entry.branches
        |> Map.values()
        |> Enum.filter(&(include_purged? or &1.retention != :purged))
        |> Enum.sort_by(&{&1.state_generation, &1.branch_id}, :desc)

      {:ok, branches}
    end
  end

  @spec update(InstanceState.t(), atom() | String.t(), term(), keyword()) ::
          {:ok, StateBinding.t(), InstanceState.t()} | {:error, term()}
  def update(%InstanceState{} = data, skill_id, value, opts) when is_list(opts) do
    with {:ok, skill_id} <- normalize_skill_id(skill_id),
         {:ok, entry} <- fetch_entry(skill_states(data), skill_id),
         {:ok, binding} <- select_binding(entry, Keyword.get(opts, :branch_id, :active)),
         :ok <- active_binding(binding),
         active_definition <- Events.active_definition_ref(data),
         :ok <- same_owner(binding, active_definition),
         :ok <- Events.authorize(data, binding.owning_definition_ref, :commit),
         {:ok, binding} <-
           StateBinding.update(binding, value,
             expected_generation: Keyword.get(opts, :expected_generation),
             expected_revision: Keyword.get(opts, :expected_revision),
             state_schema_ref: Keyword.get(opts, :state_schema_ref),
             owning_definition_ref: active_definition,
             fencing_token: data.owner_lease.fencing_token,
             updated_at: Keyword.get(opts, :updated_at, System.system_time(:millisecond)),
             provenance: Keyword.get(opts, :provenance, binding.provenance)
           ),
         states <- put_binding(skill_states(data), binding),
         {:ok, next} <- commit_update(data, states, binding, opts) do
      {:ok, binding, next}
    end
  end

  def update(%InstanceState{}, _skill_id, _value, opts),
    do: {:error, {:invalid_skill_state_options, shape(opts)}}

  @spec transition_retention(
          InstanceState.t(),
          atom() | String.t(),
          String.t(),
          StateBinding.retention(),
          keyword()
        ) :: {:ok, StateBinding.t(), InstanceState.t()} | {:error, term()}
  def transition_retention(data, skill_id, branch_id, retention, opts)

  def transition_retention(
        %InstanceState{} = data,
        skill_id,
        branch_id,
        retention,
        opts
      )
      when retention in [:gc_eligible, :abandoned, :purged] and is_list(opts) do
    with {:ok, skill_id} <- normalize_skill_id(skill_id),
         {:ok, entry} <- fetch_entry(skill_states(data), skill_id),
         {:ok, binding} <- select_binding(entry, branch_id),
         :ok <- retention_safe(data, binding, retention),
         {:ok, binding} <-
           StateBinding.transition_retention(binding, retention,
             expected_revision: Keyword.get(opts, :expected_revision),
             fencing_token: data.owner_lease.fencing_token,
             updated_at: Keyword.get(opts, :updated_at, System.system_time(:millisecond)),
             provenance: Keyword.get(opts, :provenance, binding.provenance)
           ),
         states <- put_binding(skill_states(data), binding),
         {:ok, next} <- commit_retention(data, states, binding, opts) do
      {:ok, binding, next}
    end
  end

  def transition_retention(%InstanceState{}, _skill_id, _branch_id, retention, _opts),
    do: {:error, {:invalid_skill_state_retention, retention}}

  @spec prepare_activation(InstanceState.t(), DefinitionRef.t(), keyword()) ::
          {:ok, section(), map()} | {:error, term()}
  def prepare_activation(%InstanceState{} = data, %DefinitionRef{} = target, opts)
      when is_list(opts) do
    states = skill_states(data)
    activated_at = Keyword.get(opts, :activated_at, System.system_time(:millisecond))

    with {:ok, transitions} <-
           normalize_transitions(Keyword.get(opts, :skill_state_transitions, %{})),
         requirements <- transition_requirements(states, target),
         :ok <- require_explicit_transitions(requirements, transitions),
         source_active <- active_bindings(states),
         {:ok, states} <- deactivate_previous(states, target, transitions, data, activated_at),
         {:ok, states} <-
           apply_transitions(
             states,
             transitions,
             source_active,
             target,
             data,
             activated_at
           ),
         :ok <- validate_active_owners(states, target) do
      {:ok, states, activation_bindings(states, target)}
    end
  end

  @spec merge_activation_bindings(map(), map()) :: {:ok, map()} | {:error, term()}
  def merge_activation_bindings(base, skill_bindings)
      when is_map(base) and not is_struct(base) and is_map(skill_bindings) and
             not is_struct(skill_bindings) do
    legacy = Map.reject(base, fn {_key, value} -> StateBinding.activation_pointer?(value) end)

    case Enum.find(Map.keys(skill_bindings), &Map.has_key?(legacy, &1)) do
      nil -> {:ok, Map.merge(legacy, skill_bindings)}
      skill_id -> {:error, {:skill_state_activation_binding_conflict, skill_id}}
    end
  end

  def merge_activation_bindings(base, skill_bindings),
    do: {:error, {:invalid_skill_state_activation_bindings, shape(base), shape(skill_bindings)}}

  @spec activation_bindings(section(), DefinitionRef.t()) :: map()
  def activation_bindings(states, %DefinitionRef{} = target) when is_map(states) do
    Enum.reduce(states, %{}, fn {skill_id, entry}, bindings ->
      case active_entry_binding(entry) do
        %StateBinding{} = binding ->
          maybe_put_activation_binding(bindings, skill_id, binding, target)

        nil ->
          bindings
      end
    end)
  end

  defp maybe_put_activation_binding(bindings, skill_id, binding, target) do
    if same_ref?(binding.owning_definition_ref, target),
      do: Map.put(bindings, skill_id, StateBinding.activation_pointer(binding)),
      else: bindings
  end

  @spec validate(section()) :: :ok | {:error, term()}
  def validate(states) when is_map(states) and not is_struct(states) do
    Enum.reduce_while(states, :ok, fn
      {skill_id, %{active_branch: active_branch, branches: branches}}, :ok
      when is_binary(skill_id) and skill_id != "" and is_map(branches) and
             not is_struct(branches) ->
        case validate_entry(skill_id, active_branch, branches) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      {skill_id, _entry}, :ok ->
        {:halt, {:error, {:invalid_skill_state_entry, skill_id}}}
    end)
  end

  def validate(value), do: {:error, {:invalid_skill_states, shape(value)}}

  @spec validate_activation(section(), Activation.t() | nil) :: :ok | {:error, term()}
  def validate_activation(states, activation) do
    with :ok <- validate(states), do: validate_activation_bindings(states, activation)
  end

  @spec definition_referenced?(InstanceState.t(), DefinitionRef.t()) :: boolean()
  def definition_referenced?(%InstanceState{} = data, %DefinitionRef{} = definition_ref) do
    data
    |> skill_states()
    |> all_bindings()
    |> Enum.any?(fn binding ->
      binding.retention != :purged and same_ref?(binding.owning_definition_ref, definition_ref)
    end)
  end

  defp normalize_transitions(transitions)
       when is_map(transitions) and not is_struct(transitions) do
    Enum.reduce_while(transitions, {:ok, %{}}, fn {skill_id, transition}, {:ok, normalized} ->
      with {:ok, skill_id} <- normalize_skill_id(skill_id),
           false <- Map.has_key?(normalized, skill_id) do
        {:cont, {:ok, Map.put(normalized, skill_id, transition)}}
      else
        true -> {:halt, {:error, {:duplicate_skill_state_transition, skill_id}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_transitions(value),
    do: {:error, {:invalid_skill_state_transitions, shape(value)}}

  defp transition_requirements(states, target) do
    states
    |> Enum.reduce([], fn {skill_id, entry}, required ->
      target_dormant = eligible_target_branches(entry, target)

      if target_dormant != [] and not active_target?(entry, target),
        do: [{skill_id, Enum.map(target_dormant, & &1.branch_id) |> Enum.sort()} | required],
        else: required
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp require_explicit_transitions(requirements, transitions) do
    case Enum.find(requirements, fn {skill_id, _branches} ->
           not Map.has_key?(transitions, skill_id)
         end) do
      nil -> :ok
      {skill_id, branches} -> {:error, {:skill_state_transition_required, skill_id, branches}}
    end
  end

  defp deactivate_previous(states, target, transitions, data, activated_at) do
    Enum.reduce_while(states, {:ok, states}, fn {skill_id, entry}, {:ok, acc} ->
      deactivate_previous_entry(
        active_entry_binding(entry),
        skill_id,
        acc,
        target,
        transitions,
        data,
        activated_at
      )
    end)
  end

  defp deactivate_previous_entry(nil, _skill_id, states, _target, _transitions, _data, _at),
    do: {:cont, {:ok, states}}

  defp deactivate_previous_entry(binding, skill_id, states, target, transitions, data, at) do
    if same_ref?(binding.owning_definition_ref, target) and
         not Map.has_key?(transitions, skill_id) do
      {:cont, {:ok, states}}
    else
      binding
      |> dormant(data, at, :definition_deactivated)
      |> continue_with_binding(states)
    end
  end

  defp continue_with_binding({:ok, binding}, states),
    do: {:cont, {:ok, put_binding(states, binding)}}

  defp continue_with_binding({:error, _reason} = error, _states), do: {:halt, error}

  defp apply_transitions(states, transitions, source_active, target, data, activated_at) do
    transitions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, states}, fn {skill_id, transition}, {:ok, acc} ->
      case apply_transition(
             acc,
             skill_id,
             transition,
             Map.get(source_active, skill_id),
             target,
             data,
             activated_at
           ) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_transition(states, skill_id, :resume, _source, target, data, activated_at) do
    with {:ok, entry} <- fetch_entry(states, skill_id),
         {:ok, binding} <- unique_target_branch(entry, target, :resume) do
      activate_selected(states, binding, data, activated_at, :branch_resumed)
    end
  end

  defp apply_transition(
         states,
         skill_id,
         {:resume, branch_id},
         _source,
         target,
         data,
         activated_at
       ) do
    with {:ok, entry} <- fetch_entry(states, skill_id),
         {:ok, binding} <- select_target_branch(entry, branch_id, target, :resume) do
      activate_selected(states, binding, data, activated_at, :branch_resumed)
    end
  end

  defp apply_transition(states, skill_id, :abandon, _source, target, data, activated_at) do
    with {:ok, entry} <- fetch_entry(states, skill_id),
         {:ok, binding} <- unique_target_branch(entry, target, :abandon) do
      abandon_selected(states, binding, data, activated_at)
    end
  end

  defp apply_transition(
         states,
         skill_id,
         {:abandon, branch_id},
         _source,
         target,
         data,
         activated_at
       ) do
    with {:ok, entry} <- fetch_entry(states, skill_id),
         {:ok, binding} <- select_target_branch(entry, branch_id, target, :abandon) do
      abandon_selected(states, binding, data, activated_at)
    end
  end

  defp apply_transition(
         states,
         skill_id,
         {:init, schema_ref, value},
         _source,
         target,
         data,
         activated_at
       ) do
    entry = Map.get(states, skill_id, empty_entry())

    if eligible_target_branches(entry, target) == [] do
      create_branch(
        states,
        skill_id,
        schema_ref,
        value,
        nil,
        target,
        data,
        {activated_at, :branch_initialized}
      )
    else
      {:error, {:skill_state_init_requires_no_dormant_branch, skill_id}}
    end
  end

  defp apply_transition(
         states,
         skill_id,
         {:fork, schema_ref, value},
         source,
         target,
         data,
         activated_at
       ) do
    with {:ok, source} <- require_source(source, skill_id, :fork),
         :ok <- same_fork_schema(source, schema_ref) do
      create_branch(
        states,
        skill_id,
        schema_ref,
        value,
        source,
        target,
        data,
        {activated_at, :branch_forked}
      )
    end
  end

  defp apply_transition(
         states,
         skill_id,
         {:fork, source_branch_id, schema_ref, value},
         _source,
         target,
         data,
         activated_at
       ) do
    with {:ok, source} <- source_branch(states, skill_id, source_branch_id, :fork),
         :ok <- same_fork_schema(source, schema_ref) do
      create_branch(
        states,
        skill_id,
        schema_ref,
        value,
        source,
        target,
        data,
        {activated_at, :branch_forked}
      )
    end
  end

  defp apply_transition(
         states,
         skill_id,
         {:migrate, schema_ref, value},
         source,
         target,
         data,
         activated_at
       ) do
    with {:ok, source} <- require_source(source, skill_id, :migrate) do
      create_branch(
        states,
        skill_id,
        schema_ref,
        value,
        source,
        target,
        data,
        {activated_at, :branch_migrated}
      )
    end
  end

  defp apply_transition(
         states,
         skill_id,
         {:migrate, source_branch_id, schema_ref, value},
         _source,
         target,
         data,
         activated_at
       ) do
    with {:ok, source} <- source_branch(states, skill_id, source_branch_id, :migrate) do
      create_branch(
        states,
        skill_id,
        schema_ref,
        value,
        source,
        target,
        data,
        {activated_at, :branch_migrated}
      )
    end
  end

  defp apply_transition(_states, skill_id, transition, _source, _target, _data, _activated_at),
    do: {:error, {:invalid_skill_state_transition, skill_id, transition}}

  defp create_branch(
         states,
         skill_id,
         schema_ref,
         value,
         source,
         target,
         data,
         {activated_at, transition}
       ) do
    entry = Map.get(states, skill_id, empty_entry())
    generation = next_generation(entry)
    parent_branch_id = if source, do: source.branch_id, else: nil

    with {:ok, states} <- deactivate_entry_active(states, skill_id, nil, data, activated_at),
         {:ok, binding} <-
           StateBinding.new(%{
             skill_id: skill_id,
             state_schema_ref: schema_ref,
             state_generation: generation,
             branch_id: Spectre.Identity.uuid7(),
             parent_branch_id: parent_branch_id,
             owning_definition_ref: target,
             revision: 0,
             fencing_token: data.owner_lease.fencing_token,
             status: :active,
             retention: :retained,
             state: value,
             created_at: activated_at,
             updated_at: activated_at,
             provenance: %{
               source: :activation,
               transition: transition,
               activation_generation: Activation.generation(data.activation) + 1
             }
           }) do
      {:ok, put_binding(states, binding)}
    end
  end

  defp activate_selected(states, binding, data, activated_at, transition) do
    with {:ok, states} <-
           deactivate_entry_active(
             states,
             binding.skill_id,
             binding.branch_id,
             data,
             activated_at
           ),
         {:ok, entry} <- fetch_entry(states, binding.skill_id),
         {:ok, current} <- select_binding(entry, binding.branch_id),
         {:ok, activated} <-
           StateBinding.transition_status(current, :active,
             expected_revision: current.revision,
             fencing_token: data.owner_lease.fencing_token,
             updated_at: activated_at,
             provenance: %{
               source: :activation,
               transition: transition,
               activation_generation: Activation.generation(data.activation) + 1
             }
           ) do
      {:ok, put_binding(states, activated)}
    end
  end

  defp abandon_selected(states, binding, data, activated_at) do
    with {:ok, states} <-
           deactivate_entry_active(states, binding.skill_id, nil, data, activated_at),
         {:ok, entry} <- fetch_entry(states, binding.skill_id),
         {:ok, current} <- select_binding(entry, binding.branch_id),
         {:ok, abandoned} <-
           StateBinding.transition_retention(current, :abandoned,
             expected_revision: current.revision,
             fencing_token: data.owner_lease.fencing_token,
             updated_at: activated_at,
             provenance: %{
               source: :activation,
               transition: :branch_abandoned,
               activation_generation: Activation.generation(data.activation) + 1
             }
           ) do
      {:ok, put_binding(states, abandoned)}
    end
  end

  defp deactivate_entry_active(states, skill_id, except_branch, data, activated_at) do
    entry = Map.get(states, skill_id, empty_entry())

    case active_entry_binding(entry) do
      %StateBinding{branch_id: branch_id} when branch_id != except_branch ->
        case dormant(active_entry_binding(entry), data, activated_at, :branch_deactivated) do
          {:ok, binding} -> {:ok, put_binding(states, binding)}
          {:error, _reason} = error -> error
        end

      _none_or_selected ->
        {:ok, states}
    end
  end

  defp dormant(binding, data, activated_at, transition) do
    StateBinding.transition_status(binding, :dormant,
      expected_revision: binding.revision,
      fencing_token: data.owner_lease.fencing_token,
      updated_at: activated_at,
      provenance: %{
        source: :activation,
        transition: transition,
        activation_generation: Activation.generation(data.activation) + 1
      }
    )
  end

  defp source_branch(states, skill_id, branch_id, operation) do
    with {:ok, entry} <- fetch_entry(states, skill_id),
         {:ok, binding} <- select_binding(entry, branch_id),
         :ok <- usable_source(binding, operation) do
      {:ok, binding}
    end
  end

  defp require_source(%StateBinding{} = binding, _skill_id, operation),
    do: usable_source(binding, operation) |> then_source(binding)

  defp require_source(nil, skill_id, operation),
    do: {:error, {:skill_state_source_required, skill_id, operation}}

  defp then_source(:ok, binding), do: {:ok, binding}
  defp then_source({:error, _reason} = error, _binding), do: error

  defp usable_source(%StateBinding{retention: :retained}, _operation), do: :ok

  defp usable_source(binding, operation),
    do:
      {:error, {:skill_state_source_unavailable, binding.branch_id, operation, binding.retention}}

  defp same_fork_schema(source, schema_ref) when source.state_schema_ref == schema_ref, do: :ok

  defp same_fork_schema(source, schema_ref),
    do: {:error, {:skill_state_fork_schema_mismatch, schema_ref, source.state_schema_ref}}

  defp unique_target_branch(entry, target, operation) do
    case eligible_target_branches(entry, target) do
      [binding] -> {:ok, binding}
      [] -> {:error, {:skill_state_target_branch_not_found, operation}}
      many -> {:error, {:ambiguous_skill_state_branch, operation, Enum.map(many, & &1.branch_id)}}
    end
  end

  defp select_target_branch(entry, branch_id, target, operation) do
    with {:ok, binding} <- select_binding(entry, branch_id),
         true <- same_ref?(binding.owning_definition_ref, target),
         true <- binding.retention == :retained do
      {:ok, binding}
    else
      false -> {:error, {:invalid_skill_state_target_branch, operation, branch_id}}
      {:error, _reason} = error -> error
    end
  end

  defp eligible_target_branches(entry, target) do
    entry.branches
    |> Map.values()
    |> Enum.filter(fn binding ->
      same_ref?(binding.owning_definition_ref, target) and binding.status == :dormant and
        binding.retention == :retained
    end)
    |> Enum.sort_by(&{&1.state_generation, &1.branch_id}, :desc)
  end

  defp active_target?(entry, target) do
    case active_entry_binding(entry) do
      %StateBinding{} = binding -> same_ref?(binding.owning_definition_ref, target)
      nil -> false
    end
  end

  defp active_bindings(states) do
    Map.new(states, fn {skill_id, entry} -> {skill_id, active_entry_binding(entry)} end)
  end

  defp active_entry_binding(%{active_branch: nil}), do: nil

  defp active_entry_binding(%{active_branch: branch_id, branches: branches}),
    do: Map.get(branches, branch_id)

  defp next_generation(%{branches: branches}) do
    branches
    |> Map.values()
    |> Enum.map(& &1.state_generation)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp validate_active_owners(states, target) do
    case Enum.find(all_bindings(states), fn binding ->
           binding.status == :active and not same_ref?(binding.owning_definition_ref, target)
         end) do
      nil ->
        :ok

      binding ->
        {:error, {:skill_state_active_owner_mismatch, binding.skill_id, binding.branch_id}}
    end
  end

  defp validate_entry(skill_id, active_branch, branches) do
    with :ok <- validate_branch_entries(skill_id, branches),
         :ok <- validate_parent_links(branches) do
      validate_active_branch(active_branch, branches)
    end
  end

  defp validate_branch_entries(skill_id, branches) do
    Enum.reduce_while(branches, :ok, fn
      {branch_id, %StateBinding{} = binding}, :ok
      when is_binary(branch_id) and branch_id != "" ->
        case StateBinding.new(binding) do
          {:ok, ^binding} when binding.skill_id == skill_id and binding.branch_id == branch_id ->
            {:cont, :ok}

          {:ok, _binding} ->
            {:halt, {:error, {:skill_state_branch_key_mismatch, skill_id, branch_id}}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_skill_state_branch, skill_id, branch_id, reason}}}
        end

      {branch_id, _binding}, :ok ->
        {:halt, {:error, {:invalid_skill_state_branch, skill_id, branch_id}}}
    end)
  end

  defp validate_parent_links(branches) do
    Enum.reduce_while(branches, :ok, fn {_branch_id, binding}, :ok ->
      case validate_parent_link(branches, binding) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_parent_link(_branches, %StateBinding{parent_branch_id: nil}), do: :ok

  defp validate_parent_link(branches, binding) do
    case Map.get(branches, binding.parent_branch_id) do
      %StateBinding{state_generation: parent_generation}
      when parent_generation < binding.state_generation ->
        :ok

      _missing_or_future ->
        {:error, {:invalid_skill_state_parent, binding.branch_id, binding.parent_branch_id}}
    end
  end

  defp validate_active_branch(nil, branches) do
    if Enum.any?(branches, fn {_id, binding} -> binding.status == :active end),
      do: {:error, :skill_state_active_branch_missing},
      else: :ok
  end

  defp validate_active_branch(active_branch, branches) when is_binary(active_branch) do
    active = Enum.filter(branches, fn {_id, binding} -> binding.status == :active end)

    case {Map.get(branches, active_branch), active} do
      {%StateBinding{status: :active, retention: :retained}, [{^active_branch, _binding}]} -> :ok
      _invalid -> {:error, {:invalid_skill_state_active_branch, active_branch}}
    end
  end

  defp validate_active_branch(value, _branches),
    do: {:error, {:invalid_skill_state_active_branch, value}}

  defp validate_activation_bindings(states, nil) do
    if Enum.any?(all_bindings(states), &(&1.status == :active)),
      do: {:error, :skill_state_active_without_activation},
      else: :ok
  end

  defp validate_activation_bindings(states, %Activation{} = activation) do
    expected = activation_bindings(states, activation.definition_ref)

    actual =
      Map.filter(activation.state_bindings, fn {_key, value} ->
        StateBinding.activation_pointer?(value)
      end)

    cond do
      actual != expected ->
        {:error, :skill_state_activation_binding_mismatch}

      Enum.any?(all_bindings(states), fn binding ->
        binding.status == :active and
            not same_ref?(binding.owning_definition_ref, activation.definition_ref)
      end) ->
        {:error, :skill_state_activation_owner_mismatch}

      true ->
        :ok
    end
  end

  defp validate_activation_bindings(_states, value),
    do: {:error, {:invalid_skill_state_activation, value}}

  defp retention_safe(_data, _binding, :abandoned), do: :ok

  defp retention_safe(data, binding, retention) when retention in [:gc_eligible, :purged] do
    reason =
      cond do
        binding.status == :active ->
          :active_branch

        activation_references?(data.activation, binding) ->
          :activation

        Enum.any?(data.runs, fn {_id, run} ->
          same_ref?(run.definition_ref, binding.owning_definition_ref)
        end) ->
          :run

        Enum.any?(Loops.all_operation_loops(data), fn {loop, _control} ->
          same_ref?(Events.operation_definition_ref(data, loop), binding.owning_definition_ref)
        end) ->
          :operation

        child_references?(skill_states(data), binding) ->
          :child_branch

        true ->
          nil
      end

    if reason,
      do:
        {:error, {:skill_state_retention_referenced, binding.skill_id, binding.branch_id, reason}},
      else: :ok
  end

  defp activation_references?(nil, _binding), do: false

  defp activation_references?(%Activation{} = activation, binding) do
    Enum.any?(activation.state_bindings, fn {_skill_id, pointer} ->
      StateBinding.activation_pointer?(pointer) and pointer["branch_id"] == binding.branch_id
    end)
  end

  defp child_references?(states, binding) do
    Enum.any?(all_bindings(states), fn child ->
      child.parent_branch_id == binding.branch_id and child.retention != :purged
    end)
  end

  defp commit_update(data, states, binding, opts) do
    Commit.canonical_sections(data, %{skill_states: states},
      correlation_id: Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7()),
      causation_id: Keyword.get(opts, :causation_id),
      provenance: Keyword.get(opts, :provenance, %{source: :skill_state}),
      metadata: %{
        transition: :skill_state_updated,
        skill_id: binding.skill_id,
        branch_id: binding.branch_id,
        state_generation: binding.state_generation,
        state_revision: binding.revision
      }
    )
  end

  defp commit_retention(data, states, binding, opts) do
    Commit.canonical_sections(data, %{skill_states: states},
      correlation_id: Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7()),
      causation_id: Keyword.get(opts, :causation_id),
      provenance: Keyword.get(opts, :provenance, %{source: :skill_state_retention}),
      metadata: %{
        transition: :skill_state_retention_changed,
        skill_id: binding.skill_id,
        branch_id: binding.branch_id,
        retention: binding.retention,
        state_revision: binding.revision
      }
    )
  end

  defp skill_states(%InstanceState{} = data) do
    case Canonical.fetch(data.canonical, :skill_states) do
      {:ok, states} when is_map(states) and not is_struct(states) -> states
      _invalid -> %{}
    end
  end

  defp fetch_entry(states, skill_id) do
    case Map.get(states, skill_id) do
      %{active_branch: _active_branch, branches: branches} = entry when is_map(branches) ->
        {:ok, entry}

      nil ->
        {:error, {:skill_state_not_found, skill_id}}

      _invalid ->
        {:error, {:invalid_skill_state_entry, skill_id}}
    end
  end

  defp select_binding(entry, :active) do
    case active_entry_binding(entry) do
      %StateBinding{} = binding -> {:ok, binding}
      nil -> {:error, :active_skill_state_not_found}
    end
  end

  defp select_binding(%{branches: branches}, branch_id)
       when is_binary(branch_id) and branch_id != "" do
    case Map.get(branches, branch_id) do
      %StateBinding{} = binding -> {:ok, binding}
      nil -> {:error, {:skill_state_branch_not_found, branch_id}}
    end
  end

  defp select_binding(_entry, value), do: {:error, {:invalid_skill_state_branch, value}}

  defp put_binding(states, %StateBinding{} = binding) do
    entry = Map.get(states, binding.skill_id, empty_entry())
    branches = Map.put(entry.branches, binding.branch_id, binding)

    active_branch =
      if binding.status == :active,
        do: binding.branch_id,
        else: dormant_active_branch(entry.active_branch, binding.branch_id)

    Map.put(states, binding.skill_id, %{active_branch: active_branch, branches: branches})
  end

  defp dormant_active_branch(branch_id, branch_id), do: nil
  defp dormant_active_branch(active_branch, _branch_id), do: active_branch

  defp empty_entry, do: %{active_branch: nil, branches: %{}}

  defp all_bindings(states) do
    Enum.flat_map(states, fn {_skill_id, entry} -> Map.values(entry.branches) end)
  end

  defp active_binding(%StateBinding{status: :active, retention: :retained}), do: :ok

  defp active_binding(binding),
    do: {:error, {:skill_state_not_active, binding.branch_id, binding.status, binding.retention}}

  defp same_owner(binding, definition_ref) do
    if same_ref?(binding.owning_definition_ref, definition_ref),
      do: :ok,
      else: {:error, {:skill_state_owner_violation, binding.skill_id, binding.branch_id}}
  end

  defp normalize_skill_id(value) when is_binary(value) and value != "", do: {:ok, value}
  defp normalize_skill_id(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_skill_id(value), do: {:error, {:invalid_skill_state_id, value}}

  defp same_ref?(%DefinitionRef{} = left, %DefinitionRef{} = right),
    do: DefinitionRef.to_string(left) == DefinitionRef.to_string(right)

  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_integer(value), do: :integer
  defp shape(_value), do: :other
end
