defmodule Spectre.Instance.DefinitionCompatibility do
  @moduledoc false

  # Centralizes the Morph change-surface rules used at admission, activation,
  # and recovery. These checks must evolve together: accepting a profile at
  # activation while rejecting the same profile after restart would make a
  # valid canonical snapshot unrecoverable.

  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Resolver, as: DefinitionResolver
  alias Spectre.Execution.Closure
  alias Spectre.Instance.Activation
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Run

  @frozen_execution_options [
    :adapter,
    :arbitrator,
    :bag_accept,
    :classifier,
    :classifier_accept,
    :classifier_margin,
    :conflict,
    :embedding,
    :embedding_accept,
    :embedding_margin,
    :input_max_bytes,
    :input_pipeline,
    :jaro_accept,
    :labels,
    :llm_classifier?,
    :model,
    :no_decision,
    :pipeline,
    :policy_global_interrupts?,
    :policy_interrupt_only?,
    :policy_interrupt_via,
    :semantic_cache?,
    :spectre_agent,
    :spectre_rules,
    :turn_handlers,
    :via
  ]

  @doc false
  @spec change_surface?(term()) :: boolean()
  def change_surface?(definition) do
    match?(
      {:ok, _component},
      Canonical.fetch_component(definition, :change_surface)
    )
  end

  @doc false
  @spec verify_profile(keyword(), term()) :: :ok | {:error, term()}
  def verify_profile(base_opts, definition) when is_list(base_opts) do
    if change_surface?(definition) do
      case frozen_options(base_opts) do
        [] -> :ok
        keys -> {:error, {:morph_instance_execution_profile_overridden, keys}}
      end
    else
      :ok
    end
  end

  @doc false
  @spec validate_turn(InstanceState.t(), keyword()) :: :ok | {:error, term()}
  def validate_turn(
        %InstanceState{activation: %Activation{provenance: provenance}},
        opts
      )
      when is_list(opts) do
    if Map.get(provenance, :change_surface?, false) do
      case frozen_options(opts) do
        [] -> :ok
        keys -> {:error, {:morph_turn_execution_profile_overridden, keys}}
      end
    else
      :ok
    end
  end

  def validate_turn(%InstanceState{}, _opts), do: :ok

  @doc false
  @spec verify_activation_marker(Activation.t(), term()) :: :ok | {:error, term()}
  def verify_activation_marker(%Activation{} = activation, definition) do
    expected = change_surface?(definition)

    case Map.fetch(activation.provenance, :change_surface?) do
      {:ok, ^expected} ->
        :ok

      :error when expected == false ->
        # Checkpoints written before Morph had no marker. They remain valid
        # only when the resolved Definition has no change surface either.
        :ok

      supplied ->
        {:error,
         {:restored_activation_change_surface_marker_mismatch, marker_value(supplied), expected}}
    end
  end

  @doc false
  @spec verify_run_marker(Run.t(), term()) :: :ok | {:error, term()}
  def verify_run_marker(%Run{} = run, definition) do
    expected = change_surface?(definition)
    supplied = runtime_skill_dispatch?(run)

    if supplied == expected,
      do: :ok,
      else: {:error, {:run_change_surface_marker_mismatch, supplied, expected}}
  end

  @doc false
  @spec verify_pinned_run(Run.t(), term(), term(), keyword()) :: :ok | {:error, term()}
  def verify_pinned_run(
        %Run{activation_generation: 0},
        _definition_store,
        _checkpoint_store,
        _base_opts
      ),
      do: :ok

  def verify_pinned_run(%Run{}, nil, _checkpoint_store, _base_opts),
    do: {:error, :pinned_run_requires_definition_store}

  def verify_pinned_run(run, definition_store, checkpoint_store, base_opts) do
    opts =
      base_opts
      |> Keyword.put(:checkpoint_store, checkpoint_store)
      |> Keyword.put(:observe_builds, true)
      |> Keyword.put(:on_drift, :reject)

    case DefinitionResolver.resolve_for_activation(definition_store, run.definition_ref, opts) do
      {:ok, resolution} ->
        expected = Closure.digest(resolution.manifest.execution_closure)

        with :ok <- verify_run_marker(run, resolution.definition),
             true <- expected == run.closure_digest do
          :ok
        else
          false -> {:error, {:run_closure_digest_mismatch, run.closure_digest, expected}}
          {:error, _reason} = error -> error
        end

      :not_found ->
        {:error, {:pinned_run_definition_not_found, to_string(run.definition_ref)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp runtime_skill_dispatch?(%Run{} = run) do
    Map.get(
      run.metadata,
      :runtime_skill_dispatch?,
      Map.get(run.metadata, "runtime_skill_dispatch?", false)
    ) == true
  end

  defp frozen_options(opts) do
    opts
    |> Keyword.keys()
    |> Enum.filter(&(&1 in @frozen_execution_options))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp marker_value({:ok, value}), do: value
  defp marker_value(:error), do: :missing
end
