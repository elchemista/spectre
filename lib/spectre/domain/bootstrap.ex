defmodule Spectre.Domain.Bootstrap do
  @moduledoc false

  alias Spectre.Adapter
  alias Spectre.Domain.Event
  alias Spectre.Domain.Projection
  alias Spectre.Duty.Derive
  alias Spectre.GovernedAct.State
  alias Spectre.{Constitution, Duty, Genesis, HostProfile, Mandate, Principal, Surface}

  @type prepared :: %{batch_id: String.t(), payloads: [map()]}

  @spec prepare(String.t(), keyword()) :: {:ok, prepared()} | {:error, term()}
  def prepare(domain_ref, opts) when is_binary(domain_ref) and is_list(opts) do
    with {:ok, constitution} <- constitution(opts),
         {:ok, genesis} <- required_record(opts, :genesis, Genesis),
         {:ok, principals} <- record_list(opts, :principals, Principal),
         {:ok, host_profile} <- required_record(opts, :host_profile, HostProfile),
         {:ok, surface} <- required_record(opts, :surface, Surface),
         {:ok, mandates} <- record_list(opts, :root_mandates, Mandate),
         :ok <-
           verify_bundle(
             domain_ref,
             constitution,
             genesis,
             principals,
             host_profile,
             surface,
             mandates
           ),
         :ok <- verify_attestation(genesis, opts),
         {:ok, payloads} <- events(genesis, principals, host_profile, surface, mandates) do
      {:ok, %{batch_id: "genesis:" <> genesis.ref, payloads: payloads}}
    end
  end

  def prepare(_domain_ref, _opts), do: {:error, :invalid_domain_bootstrap}

  @spec verify_projection(Projection.t(), keyword()) :: :ok | {:error, term()}
  def verify_projection(%State{} = projection, opts) when is_list(opts) do
    case State.surface(projection) do
      %Surface{declarations: declarations} when map_size(declarations) == 0 ->
        with :ok <- verify_optional_genesis(projection, opts),
             :ok <- verify_projection_constitution(projection),
             :ok <- verify_projection_duty_routes(projection),
             do: verify_projection_emergency(projection)

      %Surface{} ->
        with %Genesis{} = genesis <- projection.genesis,
             :ok <- verify_projection_links(projection, genesis),
             :ok <- verify_constitution(genesis, projection.constitution),
             :ok <- verify_attestation(genesis, opts),
             :ok <- verify_projection_duty_routes(projection),
             :ok <- verify_projection_emergency(projection) do
          :ok
        else
          nil -> {:error, :genesis_required}
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_domain_genesis}
        end

      nil ->
        {:error, :governed_surface_required}

      _invalid ->
        {:error, :invalid_governed_surface}
    end
  end

  def verify_projection(_projection, _opts), do: {:error, :invalid_domain_projection}

  defp verify_optional_genesis(%State{genesis: nil}, _opts), do: :ok

  defp verify_optional_genesis(%State{genesis: %Genesis{} = genesis} = projection, opts) do
    with :ok <- verify_projection_links(projection, genesis),
         do: verify_attestation(genesis, opts)
  end

  defp verify_optional_genesis(_projection, _opts), do: {:error, :invalid_domain_genesis}

  defp verify_projection_constitution(%State{genesis: nil}), do: :ok

  defp verify_projection_constitution(%State{
         genesis: %Genesis{} = genesis,
         constitution: constitution
       }),
       do: verify_constitution(genesis, constitution)

  defp verify_bundle(
         domain_ref,
         constitution,
         genesis,
         principals,
         host_profile,
         surface,
         mandates
       ) do
    cond do
      genesis.domain_ref != domain_ref ->
        {:error, :genesis_domain_mismatch}

      genesis.constitution_ref != Constitution.ref!(constitution) ->
        {:error, :genesis_constitution_mismatch}

      genesis.principal_refs != sorted_refs(principals) ->
        {:error, :genesis_principal_refs_mismatch}

      genesis.root_mandate_refs != sorted_refs(mandates) ->
        {:error, :genesis_root_mandate_refs_mismatch}

      genesis.host_profile_ref != host_profile.ref ->
        {:error, :genesis_host_profile_mismatch}

      genesis.surface_ref != surface.ref or genesis.surface_revision != surface.revision ->
        {:error, :genesis_surface_mismatch}

      Enum.any?(mandates, &(&1.parent_ref != nil or &1.source_ref != genesis.ref)) ->
        {:error, :invalid_root_mandate_source}

      true ->
        known_authorities = sorted_refs(principals) ++ sorted_refs(mandates)

        with :ok <- Constitution.validate_duty_routes(constitution, known_authorities),
             do: verify_emergency_mandate(genesis, mandates, constitution)
    end
  end

  defp verify_emergency_mandate(%Genesis{emergency_mandate_ref: nil}, _mandates, _rules),
    do: :ok

  defp verify_emergency_mandate(genesis, mandates, rules) do
    case Enum.find(mandates, &(&1.ref == genesis.emergency_mandate_ref)) do
      nil ->
        {:error, :genesis_emergency_mandate_missing}

      %Mandate{} = mandate ->
        with :ok <- emergency_cannot_delegate(mandate),
             :ok <- emergency_cannot_rewrite_itself(mandate) do
          emergency_duration_within_policy(mandate, rules)
        end
    end
  end

  defp emergency_cannot_delegate(%Mandate{
         delegation: %{"allowed" => false, "max_depth" => 0}
       }),
       do: :ok

  defp emergency_cannot_delegate(_mandate), do: {:error, :emergency_mandate_may_not_delegate}

  defp emergency_cannot_rewrite_itself(%Mandate{classes: classes}) do
    forbidden =
      MapSet.new(
        ~w(mandate.delegate mandate.restrict surface.revise host_profile.revise definition.revise)
      )

    if Enum.any?(classes, &MapSet.member?(forbidden, &1)),
      do: {:error, :emergency_mandate_may_not_rewrite_exception},
      else: :ok
  end

  defp emergency_duration_within_policy(mandate, rules) do
    case Constitution.emergency_max_duration(rules) do
      {:ok, maximum} ->
        if mandate.expires_at - mandate.not_before <= maximum,
          do: :ok,
          else: {:error, :emergency_mandate_duration_exceeded}

      {:error, _reason} = error ->
        error
    end
  end

  defp verify_projection_emergency(%State{genesis: nil}), do: :ok

  defp verify_projection_emergency(
         %State{genesis: %Genesis{} = genesis, constitution: rules} = projection
       ),
       do: verify_emergency_mandate(genesis, Map.values(projection.mandates), rules)

  defp verify_projection_duty_routes(%State{genesis: nil}), do: :ok

  defp verify_projection_duty_routes(%State{} = projection) do
    known_authorities = Map.keys(projection.principals) ++ Map.keys(projection.mandates)
    rules = projection.constitution

    with :ok <- Constitution.validate(rules),
         :ok <- Constitution.validate_duty_routes(rules, known_authorities) do
      verify_projection_duty_conflicts(projection, rules)
    end
  end

  defp verify_projection_duty_conflicts(projection, rules) do
    Enum.reduce_while(projection.duties, :ok, fn {_cause_key, duty}, :ok ->
      configured =
        if Duty.configurable_class?(duty.class),
          do: Constitution.conflict_refs(rules, duty.class),
          else: []

      expected =
        Derive.conflict_refs(duty.accountable, configured, duty_cause_act(projection, duty))

      if duty.conflict_refs == expected,
        do: {:cont, :ok},
        else: {:halt, {:error, {:duty_conflict_refs_mismatch, duty.ref}}}
    end)
  end

  defp duty_cause_act(projection, %Duty{act_ref: act_ref}) when is_binary(act_ref),
    do: Map.get(projection.acts, act_ref)

  defp duty_cause_act(
         projection,
         %Duty{class: :scope_promise_overdue, cause_key: {:scope_promise_overdue, scope_ref}}
       ) do
    case Map.get(projection.scopes, scope_ref) do
      nil -> nil
      opening -> Map.get(projection.acts, opening.source_act_ref)
    end
  end

  defp duty_cause_act(_projection, _duty), do: nil

  defp verify_projection_links(projection, genesis) do
    principals = projection.principals |> Map.keys() |> Enum.sort()
    mandates = projection.mandates |> Map.keys() |> Enum.sort()
    initial_host_profile = Map.get(projection.host_profiles, genesis.host_profile_ref)
    initial_surface = Map.get(projection.surfaces, genesis.surface_ref)

    cond do
      genesis.domain_ref != projection.domain_ref ->
        {:error, :genesis_domain_mismatch}

      not MapSet.subset?(MapSet.new(genesis.principal_refs), MapSet.new(principals)) ->
        {:error, :genesis_principal_refs_mismatch}

      not MapSet.subset?(MapSet.new(genesis.root_mandate_refs), MapSet.new(mandates)) ->
        {:error, :genesis_root_mandate_refs_missing}

      not match?(%HostProfile{}, initial_host_profile) ->
        {:error, :genesis_host_profile_mismatch}

      not match?(%Surface{}, initial_surface) or
          genesis.surface_revision != initial_surface.revision ->
        {:error, :genesis_surface_mismatch}

      true ->
        :ok
    end
  end

  defp verify_constitution(genesis, rules) do
    with :ok <- Constitution.validate(rules),
         {:ok, ref} <- Constitution.ref(rules) do
      if genesis.constitution_ref == ref,
        do: :ok,
        else: {:error, :genesis_constitution_mismatch}
    end
  end

  defp constitution(opts) do
    rules = Keyword.get(opts, :constitution, %{})

    with :ok <- Constitution.validate(rules), do: {:ok, rules}
  end

  defp verify_attestation(genesis, opts) do
    with {:ok, {module, verifier_opts}} <- verifier(opts),
         :ok <- Adapter.validate(module, verify: 2),
         {:ok, result} <- Adapter.invoke(module, :verify, [genesis, verifier_opts]) do
      result
    else
      {:error, {:adapter_callback_exception, _module, :verify, exception}} ->
        {:error, {:genesis_verifier_failed, exception}}

      {:error, {:adapter_callback_failure, _module, :verify, kind}} ->
        {:error, {:genesis_verifier_failed, kind}}

      {:error, {:adapter_module_not_loaded, _module}} ->
        {:error, :genesis_verifier_unavailable}

      {:error, {:adapter_callback_missing, _module, :verify, 2}} ->
        {:error, :genesis_verifier_unavailable}

      {:error, {:invalid_adapter_module, _module}} ->
        {:error, :genesis_verifier_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp verifier(opts) do
    case Keyword.fetch(opts, :genesis_verifier) do
      {:ok, module} when is_atom(module) and not is_nil(module) ->
        {:ok, {module, []}}

      {:ok, {module, verifier_opts}}
      when is_atom(module) and not is_nil(module) and is_list(verifier_opts) ->
        if Keyword.keyword?(verifier_opts),
          do: {:ok, {module, verifier_opts}},
          else: {:error, :invalid_genesis_verifier_options}

      {:ok, _invalid} ->
        {:error, :invalid_genesis_verifier}

      :error ->
        {:error, :genesis_verifier_required}
    end
  end

  defp required_record(opts, key, module) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> module.new(value)
      :error -> {:error, {:missing_domain_bootstrap_record, key}}
    end
  end

  defp record_list(opts, key, module) do
    case Keyword.fetch(opts, key) do
      {:ok, values} when is_list(values) -> normalize_records(values, module, [])
      {:ok, _invalid} -> {:error, {:invalid_domain_bootstrap_records, key}}
      :error -> {:error, {:missing_domain_bootstrap_records, key}}
    end
  end

  defp normalize_records([], _module, records), do: {:ok, Enum.reverse(records)}

  defp normalize_records([value | rest], module, records) do
    with {:ok, record} <- module.new(value),
         do: normalize_records(rest, module, [record | records])
  end

  defp events(genesis, principals, host_profile, surface, mandates) do
    records =
      [{:genesis, genesis}] ++
        Enum.map(principals, &{:principal, &1}) ++
        [{:host_profile, host_profile}, {:surface, surface}] ++
        Enum.map(mandates, &{:mandate, &1})

    Enum.reduce_while(records, {:ok, []}, fn {kind, record}, {:ok, payloads} ->
      case Event.record(kind, record) do
        {:ok, payload} -> {:cont, {:ok, [payload | payloads]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      {:error, _reason} = error -> error
    end
  end

  defp sorted_refs(records), do: records |> Enum.map(& &1.ref) |> Enum.sort()
end
