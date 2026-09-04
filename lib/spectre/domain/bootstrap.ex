defmodule Spectre.Domain.Bootstrap do
  @moduledoc false

  alias Spectre.Adapter
  alias Spectre.Domain.Event
  alias Spectre.Domain.Projection
  alias Spectre.Duty.Derive
  alias Spectre.GovernedAct.{Emergency, Fold, State}
  alias Spectre.{Constitution, Duty, Genesis, HostProfile, Mandate, Principal, Surface}

  @type prepared :: %{batch_id: String.t(), payloads: [map()]}

  @spec prepare(String.t(), keyword(), non_neg_integer()) ::
          {:ok, prepared()} | {:error, term()}
  def prepare(domain_ref, opts, recorded_at)
      when is_binary(domain_ref) and is_list(opts) and is_integer(recorded_at) and
             recorded_at >= 0 do
    with {:ok, constitution} <- constitution(opts),
         {:ok, genesis} <- required_record(opts, :genesis, Genesis),
         {:ok, principals} <- record_list(opts, :principals, Principal),
         {:ok, host_profile} <- required_record(opts, :host_profile, HostProfile),
         {:ok, surface} <- required_record(opts, :surface, Surface),
         {:ok, mandates} <- record_list(opts, :root_mandates, Mandate),
         {:ok, payloads} <- events(genesis, principals, host_profile, surface, mandates),
         :ok <- preflight(domain_ref, constitution, payloads, recorded_at, opts) do
      {:ok, %{batch_id: "genesis:" <> genesis.ref, payloads: payloads}}
    end
  end

  def prepare(_domain_ref, _opts, _recorded_at), do: {:error, :invalid_domain_bootstrap}

  @spec verify_projection(Projection.t(), keyword()) :: :ok | {:error, term()}
  def verify_projection(%State{} = projection, opts) when is_list(opts) do
    case State.surface(projection) do
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

  # Bootstrap is checked through the same disposable reducer used by live
  # command preflight and durable recovery. This prevents a hand-maintained
  # bundle validator from accepting a Genesis batch that replay would reject.
  defp preflight(domain_ref, constitution, payloads, recorded_at, opts) do
    initial = Projection.new(domain_ref, constitution)

    with {:ok, projection} <- Projection.apply_payloads(initial, payloads, recorded_at),
         :ok <- Fold.validate_complete(projection) do
      verify_projection(projection, opts)
    end
  end

  defp verify_projection_emergency(
         %State{genesis: %Genesis{} = genesis, constitution: rules} = projection
       ),
       do: Emergency.validate(genesis, projection.mandates, rules)

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
end
