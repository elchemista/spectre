defmodule Spectre.Doctor do
  @moduledoc "Read-only public-contract diagnostics that never start resources or invoke stores."

  alias Spectre.Action
  alias Spectre.Action.Provider, as: ActionProvider
  alias Spectre.Action.Schema, as: ActionSchema
  alias Spectre.Action.Spec, as: ActionSpec
  alias Spectre.ActionConfig
  alias Spectre.Definition
  alias Spectre.Doctor.Report
  alias Spectre.EffectConfig
  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Operation.Delivery.Consent
  alias Spectre.Prompt.AssetAudit
  alias Spectre.Stack.Conformance, as: StackConformance
  alias Spectre.Stack.Definition, as: StackDefinition

  @contract_version 1
  @options [:agent, :checkpoint_store, :consents, :packages, :stack]
  @egress_allowlist_keys [
    :allowlist,
    :egress_allowlist,
    :allowed_destinations,
    :allowed_domains,
    :allowed_hosts
  ]

  @doc "Runs runtime, Foundation, Agent, Stack, package, and store diagnostics."
  @spec run(keyword()) :: {:ok, Report.t()} | {:error, term()}
  def run(opts) when is_list(opts) do
    with :ok <- options(opts) do
      {agent_checks, definition} = agent_checks(opts[:agent])

      checks =
        [
          safe("runtime.elixir", &elixir_check/0),
          safe("runtime.otp", &otp_check/0),
          safe("runtime.spectre", &spectre_check/0),
          safe("foundation.contract", &foundation_check/0)
        ] ++
          agent_checks ++
          [
            safe("delivery.consent_expiry", fn ->
              consent_expiry_check(opts[:consents])
            end),
            safe("stack.compatibility", fn ->
              stack_check(option(opts, :stack, definition))
            end),
            safe("packages.compatibility", fn -> packages_check(opts[:packages]) end),
            safe("checkpoint_store.config", fn ->
              checkpoint_check(option(opts, :checkpoint_store, definition))
            end)
          ]

      {:ok, report(checks)}
    end
  end

  def run(_value), do: {:error, :invalid_doctor_options}

  @doc "Returns the stable Doctor report contract version."
  @spec contract_version() :: 1
  def contract_version, do: @contract_version

  defp options(opts) do
    if Keyword.keyword?(opts) do
      keys = Keyword.keys(opts)

      cond do
        length(keys) != length(Enum.uniq(keys)) ->
          {:error, :duplicate_doctor_options}

        Enum.any?(keys, &(&1 not in @options)) ->
          {:error, :unknown_doctor_options}

        true ->
          option_values(opts)
      end
    else
      {:error, :invalid_doctor_options}
    end
  end

  defp option_values(opts) do
    cond do
      not module_option?(opts[:agent]) ->
        {:error, {:invalid_doctor_option, :agent}}

      not (module_option?(opts[:stack]) or is_list(opts[:stack])) ->
        {:error, {:invalid_doctor_option, :stack}}

      not (is_nil(opts[:packages]) or is_list(opts[:packages])) ->
        {:error, {:invalid_doctor_option, :packages}}

      not (is_nil(opts[:consents]) or is_list(opts[:consents])) ->
        {:error, {:invalid_doctor_option, :consents}}

      true ->
        :ok
    end
  end

  defp module_option?(nil), do: true
  defp module_option?(module) when is_atom(module), do: module not in [false, true]
  defp module_option?(_value), do: false

  defp elixir_check do
    case Version.parse(System.version()) do
      {:ok, version} ->
        check(:ok, "runtime.elixir", :elixir_version_observed, %{
          version: Version.to_string(version)
        })

      :error ->
        check(:error, "runtime.elixir", :elixir_version_invalid)
    end
  end

  defp otp_check do
    release = :erlang.system_info(:otp_release) |> List.to_string()

    case Integer.parse(release) do
      {version, ""} when version > 0 ->
        check(:ok, "runtime.otp", :otp_release_observed, %{release: release})

      _invalid ->
        check(:error, "runtime.otp", :otp_release_invalid)
    end
  end

  defp spectre_check do
    version = Spectre.version()
    app_version = app_version()

    cond do
      Version.parse(version) == :error ->
        check(:error, "runtime.spectre", :spectre_version_invalid)

      is_binary(app_version) and app_version != version ->
        check(:error, "runtime.spectre", :spectre_application_version_mismatch, %{
          version: version
        })

      true ->
        check(:ok, "runtime.spectre", :spectre_version_observed, %{version: version})
    end
  end

  defp app_version do
    case Application.spec(:spectre, :vsn) do
      version when is_binary(version) -> version
      version when is_list(version) -> List.to_string(version)
      _unavailable -> nil
    end
  end

  defp foundation_check do
    matrix = Foundation.matrix()

    with true <- is_map(matrix),
         true <- matrix[:contract_version] == Foundation.contract_version(),
         true <- matrix[:release] == Spectre.version(),
         {:ok, formats} <- formats(matrix[:durable_formats]),
         path when is_list(path) and path != [] <- matrix[:golden_path],
         true <- Enum.all?(path, &exported?/1) do
      check(:ok, "foundation.contract", :foundation_contract_valid, %{
        contract_version: Foundation.contract_version(),
        durable_formats: formats,
        golden_path_count: length(path)
      })
    else
      _invalid -> check(:error, "foundation.contract", :foundation_contract_invalid)
    end
  end

  defp formats(formats) when is_map(formats) and map_size(formats) > 0 do
    Enum.reduce_while(formats, {:ok, %{}}, fn
      {name, %{writer: writer, readers: readers}}, {:ok, result}
      when is_atom(name) and is_integer(writer) and writer > 0 and is_list(readers) ->
        if writer in readers and Enum.all?(readers, &(is_integer(&1) and &1 > 0)) do
          value = %{writer: writer, readers: readers}
          {:cont, {:ok, Map.put(result, Atom.to_string(name), value)}}
        else
          {:halt, :error}
        end

      _entry, _result ->
        {:halt, :error}
    end)
  end

  defp formats(_formats), do: :error

  defp exported?({module, function, arity})
       when is_atom(module) and is_atom(function) and is_integer(arity) and arity >= 0,
       do: Code.ensure_loaded?(module) and function_exported?(module, function, arity)

  defp exported?(_entry), do: false

  defp agent_checks(nil) do
    {[
       check(:skipped, "agent.definition", :agent_not_requested),
       check(:skipped, "agent.manifest", :agent_not_requested),
       check(:skipped, "agent.prompt_trust", :agent_not_requested),
       check(:skipped, "agent.planner_action_protection", :agent_not_requested),
       check(:skipped, "agent.planner_action_schema", :agent_not_requested),
       check(:skipped, "agent.executor_egress", :agent_not_requested),
       check(:skipped, "agent.reply_sanitization", :agent_not_requested)
     ], nil}
  end

  defp agent_checks(agent) do
    case Code.ensure_loaded?(agent) && Definition.fetch(agent) do
      {:ok, %Definition{kind: :agent} = definition} ->
        definition_check =
          check(:ok, "agent.definition", :agent_definition_valid, %{
            module: inspect(agent),
            declared_version: definition.version
          })

        checks = [
          definition_check,
          safe("agent.manifest", fn -> manifest_check(agent) end),
          safe("agent.prompt_trust", fn -> prompt_trust_check(definition) end),
          safe("agent.planner_action_protection", fn ->
            planner_action_protection_check(definition)
          end),
          safe("agent.planner_action_schema", fn -> planner_action_schema_check(definition) end),
          safe("agent.executor_egress", fn -> executor_egress_check(definition) end),
          safe("agent.reply_sanitization", fn -> reply_sanitization_check(definition) end)
        ]

        {checks, definition}

      false ->
        agent_failure(agent, :agent_not_loaded)

      _invalid ->
        agent_failure(agent, :agent_definition_invalid)
    end
  rescue
    _exception -> agent_failure(agent, :agent_definition_exception)
  catch
    _kind, _reason -> agent_failure(agent, :agent_definition_failure)
  end

  defp agent_failure(agent, code) do
    {[
       check(:error, "agent.definition", code, %{module: inspect(agent)}),
       check(:skipped, "agent.manifest", :agent_definition_unavailable),
       check(:skipped, "agent.prompt_trust", :agent_definition_unavailable),
       check(:skipped, "agent.planner_action_protection", :agent_definition_unavailable),
       check(:skipped, "agent.planner_action_schema", :agent_definition_unavailable),
       check(:skipped, "agent.executor_egress", :agent_definition_unavailable),
       check(:skipped, "agent.reply_sanitization", :agent_definition_unavailable)
     ], nil}
  end

  defp prompt_trust_check(definition) do
    case AssetAudit.audit(definition) do
      {:ok, []} ->
        check(:ok, "agent.prompt_trust", :prompt_assets_data_bounded)

      {:ok, findings} ->
        check(:warning, "agent.prompt_trust", :unbounded_prompt_data_interpolation, %{
          finding_count: length(findings),
          findings: findings
        })

      {:error, reason} ->
        check(:error, "agent.prompt_trust", :prompt_asset_audit_failed, %{
          reason: inspect(reason)
        })
    end
  end

  defp planner_action_protection_check(%Definition{owner: agent}) do
    protections = Definition.protections(agent)

    case planner_action_specs(agent) do
      {:ok, specs} ->
        unprotected =
          Enum.reject(specs, fn spec ->
            action = Action.new(spec.name, via: spec.via)
            Enum.any?(protections, &Action.matches_ref?(&1.action, action))
          end)

        if unprotected == [] do
          check(
            :ok,
            "agent.planner_action_protection",
            :planner_actions_protected,
            %{planner_action_count: length(specs)}
          )
        else
          check(
            :warning,
            "agent.planner_action_protection",
            :unprotected_planner_actions,
            %{
              planner_action_count: length(specs),
              unprotected_count: length(unprotected),
              actions: Enum.map(unprotected, &action_ref/1)
            }
          )
        end

      {:error, count} ->
        check(
          :error,
          "agent.planner_action_protection",
          :planner_action_catalog_unavailable,
          %{provider_failure_count: count}
        )
    end
  end

  defp planner_action_specs(agent) do
    agent
    |> ActionConfig.providers()
    |> Enum.reduce({[], 0}, fn mount, {specs, failures} ->
      case ActionProvider.actions(mount, :all) do
        {:ok, provider_specs} ->
          planner_specs = Enum.filter(provider_specs, &ActionSpec.planner_visible?/1)
          {planner_specs ++ specs, failures}

        {:error, _reason} ->
          {specs, failures + 1}
      end
    end)
    |> case do
      {specs, 0} -> {:ok, Enum.reverse(specs)}
      {_specs, failures} -> {:error, failures}
    end
  end

  defp planner_action_schema_check(%Definition{owner: agent}) do
    case planner_action_specs(agent) do
      {:ok, specs} ->
        planner_action_schema_result(specs)

      {:error, count} ->
        check(
          :error,
          "agent.planner_action_schema",
          :planner_action_schema_catalog_unavailable,
          %{provider_failure_count: count}
        )
    end
  end

  defp planner_action_schema_result(specs) do
    findings = Enum.flat_map(specs, &planner_action_schema_findings/1)

    if findings == [] do
      check(:ok, "agent.planner_action_schema", :planner_action_schemas_bounded, %{
        planner_action_count: length(specs)
      })
    else
      check(:warning, "agent.planner_action_schema", :planner_action_schemas_permissive, %{
        planner_action_count: length(specs),
        finding_count: length(findings),
        unconstrained_count: Enum.count(findings, &(&1.reason == :unconstrained)),
        open_object_count: Enum.count(findings, &(&1.reason == :additional_properties_permitted)),
        actions: findings
      })
    end
  end

  defp planner_action_schema_findings(spec) do
    cond do
      not ActionSchema.constrained?(spec.schema) ->
        [Map.put(action_ref(spec), :reason, :unconstrained)]

      not ActionSchema.rejects_additional_properties?(spec.schema) ->
        [Map.put(action_ref(spec), :reason, :additional_properties_permitted)]

      true ->
        []
    end
  end

  defp action_ref(spec),
    do: %{provider: inspect(spec.via), action: to_string(spec.name)}

  defp executor_egress_check(%Definition{owner: agent}) do
    action_providers =
      agent
      |> ActionConfig.providers()
      |> Enum.reject(&(&1.module == Spectre.Action.Provider.Local))
      |> Enum.map(&%{kind: {:action, &1.id}, opts: &1.opts})

    effect_executors =
      agent
      |> EffectConfig.executors()
      |> Enum.map(&%{kind: {:effect, &1.kind}, opts: &1.opts})

    executors = action_providers ++ effect_executors
    unbounded = Enum.reject(executors, &egress_allowlisted?(&1.opts))

    if unbounded == [] do
      check(:ok, "agent.executor_egress", :executor_egress_bounded, %{
        executor_count: length(executors)
      })
    else
      check(:warning, "agent.executor_egress", :executor_egress_allowlist_missing, %{
        executor_count: length(executors),
        unbounded_count: length(unbounded),
        executors: Enum.map(unbounded, &inspect(&1.kind))
      })
    end
  end

  defp egress_allowlisted?(opts) do
    direct? = Enum.any?(@egress_allowlist_keys, &bounded_allowlist?(Keyword.get(opts, &1)))

    nested? =
      case Keyword.get(opts, :egress) do
        egress when is_list(egress) and egress != [] ->
          Keyword.keyword?(egress) and
            Enum.any?(@egress_allowlist_keys, &bounded_allowlist?(Keyword.get(egress, &1)))

        _other ->
          false
      end

    direct? or nested?
  end

  defp bounded_allowlist?(%MapSet{} = values), do: MapSet.size(values) > 0
  defp bounded_allowlist?(values) when is_list(values), do: values != []
  defp bounded_allowlist?(values) when is_map(values), do: map_size(values) > 0
  defp bounded_allowlist?(_values), do: false

  defp reply_sanitization_check(%Definition{config: config}) do
    model_opts =
      case Keyword.get(config, :model) do
        {_adapter, _function, opts} when is_list(opts) -> opts
        _model -> []
      end

    sanitize? =
      Keyword.get(config, :sanitize_reply, Keyword.get(model_opts, :sanitize_reply, true))

    if sanitize? == false do
      check(:warning, "agent.reply_sanitization", :reply_sanitization_disabled)
    else
      check(:ok, "agent.reply_sanitization", :reply_sanitization_enabled)
    end
  end

  defp consent_expiry_check(nil),
    do: check(:skipped, "delivery.consent_expiry", :delivery_consents_not_supplied)

  defp consent_expiry_check(consents) do
    {valid, invalid} =
      Enum.reduce(consents, {[], 0}, fn value, {accepted, rejected} ->
        case normalize_consent(value) do
          {:ok, consent} -> {[consent | accepted], rejected}
          :error -> {accepted, rejected + 1}
        end
      end)

    without_expiry = Enum.count(valid, &is_nil(&1.expires_at))

    cond do
      invalid > 0 ->
        check(:error, "delivery.consent_expiry", :delivery_consents_invalid, %{
          invalid_count: invalid
        })

      without_expiry > 0 ->
        check(:warning, "delivery.consent_expiry", :delivery_consent_expiry_missing, %{
          consent_count: length(valid),
          unbounded_count: without_expiry
        })

      true ->
        check(:ok, "delivery.consent_expiry", :delivery_consents_expiring, %{
          consent_count: length(valid)
        })
    end
  end

  defp normalize_consent(%Consent{} = consent) do
    if Consent.validate(consent) == :ok, do: {:ok, consent}, else: :error
  end

  defp normalize_consent(value) when is_map(value) or is_list(value) do
    {:ok, Consent.new(value)}
  rescue
    _exception -> :error
  end

  defp normalize_consent(_value), do: :error

  defp manifest_check(agent) do
    with {:ok, canonical} <- Definition.canonical(agent),
         {:ok, manifest} <- Definition.manifest(agent),
         {:ok, result} <- Foundation.verify_definition(canonical, manifest) do
      check(:ok, "agent.manifest", :agent_manifest_verified, %{
        definition_ref: result.definition_ref,
        definition_digest: result.definition_digest,
        manifest_digest: result.manifest_digest,
        manifest_contract: result.manifest_contract
      })
    else
      _error ->
        check(:error, "agent.manifest", :agent_manifest_invalid, %{module: inspect(agent)})
    end
  end

  defp option(opts, name, %Definition{} = definition) do
    if Keyword.has_key?(opts, name), do: opts[name], else: definition_option(definition, name)
  end

  defp option(opts, name, nil), do: opts[name]
  defp definition_option(definition, :stack), do: definition.stack
  defp definition_option(definition, :checkpoint_store), do: definition.config[:checkpoint_store]

  defp stack_check(nil), do: check(:skipped, "stack.compatibility", :stack_not_configured)

  defp stack_check(stack) when is_atom(stack) do
    case StackDefinition.fetch(stack) do
      {:ok, definition} ->
        check(:ok, "stack.compatibility", :stack_definition_valid, %{
          module: inspect(stack),
          package_count: length(definition.installations),
          digest: definition.digest
        })

      _error ->
        check(:error, "stack.compatibility", :stack_definition_invalid, %{
          module: inspect(stack)
        })
    end
  end

  defp stack_check(entries),
    do: matrix_check(entries, "stack.compatibility", :stack_matrix_valid, :stack_matrix_invalid)

  defp packages_check(nil),
    do: check(:skipped, "packages.compatibility", :packages_not_requested)

  defp packages_check([]), do: check(:error, "packages.compatibility", :packages_empty)

  defp packages_check(entries),
    do:
      matrix_check(
        entries,
        "packages.compatibility",
        :packages_matrix_valid,
        :packages_matrix_invalid
      )

  defp matrix_check(entries, id, success, failure) do
    case StackConformance.run(entries) do
      {:ok, result} ->
        check(:ok, id, success, %{
          contract_version: result.contract_version,
          package_count: result.package_count,
          digest: result.stack_digest
        })

      _error ->
        check(:error, id, failure)
    end
  end

  defp checkpoint_check(value) when value in [nil, false],
    do: check(:skipped, "checkpoint_store.config", :checkpoint_store_not_configured)

  defp checkpoint_check(store) do
    case CheckpointStore.normalize(store) do
      {:ok, {module, opts}} -> checkpoint_callbacks(module, opts)
      _error -> checkpoint_error(:checkpoint_store_config_invalid)
    end
  end

  defp checkpoint_callbacks(module, opts) do
    code =
      cond do
        not Keyword.keyword?(opts) -> :checkpoint_store_options_invalid
        not Code.ensure_loaded?(module) -> :checkpoint_store_not_loaded
        not function_exported?(module, :load, 2) -> :checkpoint_store_load_missing
        not function_exported?(module, :compare_and_swap, 5) -> :checkpoint_store_cas_missing
        true -> nil
      end

    if code do
      checkpoint_error(code, module)
    else
      check(:ok, "checkpoint_store.config", :checkpoint_store_callbacks_valid, %{
        module: inspect(module)
      })
    end
  end

  defp checkpoint_error(code, module \\ nil) do
    details = if module, do: %{module: inspect(module)}, else: %{}
    check(:error, "checkpoint_store.config", code, details)
  end

  defp check(status, id, code, details \\ %{}) do
    summary = code |> Atom.to_string() |> String.replace("_", " ")
    %{id: id, status: status, code: code, summary: summary, details: details}
  end

  defp safe(id, callback) do
    case callback.() do
      %{id: ^id, status: status, code: code, summary: summary, details: details} = result
      when status in [:ok, :warning, :error, :skipped] and is_atom(code) and
             is_binary(summary) and is_map(details) ->
        result

      _invalid ->
        check(:error, id, :doctor_check_invalid)
    end
  rescue
    _exception -> check(:error, id, :doctor_check_exception)
  catch
    _kind, _reason -> check(:error, id, :doctor_check_failure)
  end

  defp report(checks) do
    counts = Enum.frequencies_by(checks, & &1.status)

    summary = %{
      total: length(checks),
      passed: counts[:ok] || 0,
      warnings: counts[:warning] || 0,
      errors: counts[:error] || 0,
      skipped: counts[:skipped] || 0
    }

    status =
      if summary.errors > 0, do: :error, else: if(summary.warnings > 0, do: :warning, else: :ok)

    %Report{
      contract_version: @contract_version,
      spectre_version: Spectre.version(),
      status: status,
      checks: checks,
      summary: summary
    }
  end
end
