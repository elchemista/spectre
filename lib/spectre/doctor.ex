defmodule Spectre.Doctor do
  @moduledoc """
  Static and configuration checks for Spectre's declared trust boundary.

  The dependency check catches ordinary direct calls from Zone M into the
  executor/credential/ledger boundary.  It is deliberately not described as a
  sandbox: dynamic dispatch, ports, host configuration and arbitrary code on a
  shared BEAM node remain deployment assumptions unless the executor is
  physically isolated.
  """

  alias Spectre.Genesis
  alias Spectre.HostProfile
  alias Spectre.Ingress
  alias Spectre.Ledger.Store
  alias Spectre.Surface

  defmodule Report do
    @moduledoc "Structured result returned by `Spectre.Doctor.check/1`."

    @enforce_keys [:ok?, :checks, :errors, :warnings, :zones]
    defstruct @enforce_keys

    @type finding :: %{required(:check) => atom(), required(:reason) => term()}
    @type t :: %__MODULE__{
            ok?: boolean(),
            checks: [atom()],
            errors: [finding()],
            warnings: [finding()],
            zones: %{required(:mind) => [module()], required(:executor) => [module()]}
          }
  end

  @core_mind_modules [Spectre.Mind, Spectre.Mind.Turn]
  @core_executor_modules [
    Spectre.Attempt.Executor,
    Spectre.Attempt.Runner,
    Spectre.Secret.Broker,
    Spectre.Secret.Broker.Passthrough
  ]
  @kernel_boundary_modules [
    Spectre,
    Spectre.Domain.Sequencer,
    Spectre.Kernel,
    Spectre.Kernel.Commit,
    Spectre.Kernel.Grant,
    Spectre.Ledger,
    Spectre.Ledger.Store
  ]

  @doc "Runs every applicable check and returns all findings without raising."
  @spec check(keyword()) :: Report.t()
  def check(opts \\ [])

  def check(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      mind = modules_option(opts, :mind_modules, @core_mind_modules)
      executor = modules_option(opts, :executor_modules, @core_executor_modules)
      zones = %{mind: mind, executor: executor}

      {errors, warnings, checks} =
        {[], [], []}
        |> run_check(:zone_dependencies, fn -> zone_dependencies(mind, executor) end)
        |> run_check(:ledger_store, fn -> configured_store(opts) end)
        |> run_check(:ingress, fn -> configured_ingress(opts) end)
        |> run_check(:boundary_declaration, fn -> boundary_declaration(opts) end)

      %Report{
        ok?: errors == [],
        checks: Enum.reverse(checks),
        errors: Enum.reverse(errors),
        warnings: Enum.reverse(warnings),
        zones: zones
      }
    else
      invalid_report(:invalid_doctor_options)
    end
  end

  def check(_opts), do: invalid_report(:invalid_doctor_options)

  @doc "Returns the direct statically linked module dependencies of a compiled module."
  @spec dependencies(module()) :: {:ok, MapSet.t(module())} | {:error, term()}
  def dependencies(module) when is_atom(module) and not is_nil(module) do
    with true <- Code.ensure_loaded?(module),
         path when is_list(path) or is_binary(path) <- :code.which(module),
         {:ok, {_module, chunks}} <- :beam_lib.chunks(path, [:imports, :attributes]) do
      imports =
        chunks
        |> Keyword.fetch!(:imports)
        |> Enum.map(fn {dependency, _function, _arity} -> dependency end)

      behaviours =
        chunks
        |> Keyword.fetch!(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      {:ok, MapSet.new(imports ++ behaviours)}
    else
      false -> {:error, {:doctor_module_unavailable, module}}
      :non_existing -> {:error, {:doctor_module_unavailable, module}}
      :preloaded -> {:ok, MapSet.new()}
      {:error, reason} -> {:error, {:doctor_beam_unreadable, module, compact_reason(reason)}}
      _invalid -> {:error, {:doctor_module_unavailable, module}}
    end
  end

  def dependencies(module), do: {:error, {:invalid_doctor_module, module}}

  defp zone_dependencies(mind_modules, executor_modules) do
    invalid = Enum.reject(mind_modules ++ executor_modules, &(is_atom(&1) and not is_nil(&1)))

    if invalid == [] do
      forbidden = MapSet.new(executor_modules ++ @kernel_boundary_modules)

      Enum.reduce(mind_modules, {:ok, []}, fn module, {status, findings} ->
        case dependencies(module) do
          {:ok, dependencies} ->
            violations =
              dependencies
              |> MapSet.intersection(forbidden)
              |> MapSet.delete(module)
              |> MapSet.to_list()
              |> Enum.sort()

            case violations do
              [] -> {status, findings}
              _ -> {:error, [{:zone_m_references_boundary, module, violations} | findings]}
            end

          {:error, reason} ->
            {:error, [reason | findings]}
        end
      end)
      |> normalize_findings()
    else
      {:error, {:invalid_zone_modules, invalid}}
    end
  end

  defp configured_store(opts) do
    case Keyword.fetch(opts, :store) do
      :error ->
        {:warning, :ledger_store_not_checked}

      {:ok, store} ->
        with {:ok, {module, _adapter_opts}} <- Store.normalize(store),
             true <- Code.ensure_loaded?(module),
             true <- function_exported?(module, :append, 5),
             true <- function_exported?(module, :load, 2),
             true <- function_exported?(module, :lookup_batch, 3),
             true <- function_exported?(module, :export, 2) do
          :ok
        else
          false -> {:error, :ledger_store_callbacks_unavailable}
          {:error, _reason} = error -> error
        end
    end
  end

  defp configured_ingress(opts) do
    case Keyword.fetch(opts, :ingress) do
      :error ->
        {:error, :domain_ingress_required}

      {:ok, module} ->
        case Ingress.resolve(module) do
          {:ok, {_module, _ref}} -> :ok
          {:error, _reason} = error -> error
        end
    end
  end

  defp boundary_declaration(opts) do
    supplied = Enum.any?([:genesis, :host_profile, :surface], &Keyword.has_key?(opts, &1))

    if supplied do
      with {:ok, genesis} <- fetch_record(opts, :genesis, Genesis),
           {:ok, profile} <- fetch_record(opts, :host_profile, HostProfile),
           {:ok, surface} <- fetch_record(opts, :surface, Surface),
           :ok <- boundary_refs_match(genesis, profile, surface) do
        profile_warning(profile)
      end
    else
      {:warning, :boundary_declaration_not_checked}
    end
  end

  defp boundary_refs_match(genesis, profile, surface) do
    cond do
      genesis.host_profile_ref != profile.ref -> {:error, :genesis_host_profile_mismatch}
      genesis.surface_ref != surface.ref -> {:error, :genesis_surface_mismatch}
      genesis.surface_revision != surface.revision -> {:error, :genesis_surface_mismatch}
      true -> :ok
    end
  end

  defp profile_warning(%HostProfile{mode: :development}),
    do: {:warning, :development_profile_is_not_gam_conformance}

  defp profile_warning(%HostProfile{mode: :mediated}),
    do: {:warning, :mediated_profile_depends_on_host_side_channel_assumptions}

  defp profile_warning(%HostProfile{mode: :isolated}), do: :ok

  defp fetch_record(opts, key, module) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> module.new(value)
      :error -> {:error, {:missing_boundary_declaration, key}}
    end
  end

  defp modules_option(opts, key, defaults) do
    case Keyword.get(opts, key, []) do
      modules when is_list(modules) -> Enum.uniq(defaults ++ modules)
      invalid -> defaults ++ [invalid]
    end
  end

  defp run_check({errors, warnings, checks}, check, function) do
    case function.() do
      :ok -> {errors, warnings, [check | checks]}
      {:ok, findings} -> {errors, add_findings(warnings, check, findings), [check | checks]}
      {:warning, reason} -> {errors, [finding(check, reason) | warnings], [check | checks]}
      {:error, reasons} -> {add_findings(errors, check, reasons), warnings, [check | checks]}
    end
  end

  defp normalize_findings({:ok, []}), do: :ok
  defp normalize_findings({:error, findings}), do: {:error, Enum.reverse(findings)}

  defp add_findings(target, check, reasons) when is_list(reasons),
    do: Enum.reduce(reasons, target, &[finding(check, &1) | &2])

  defp add_findings(target, check, reason), do: [finding(check, reason) | target]

  defp finding(check, reason), do: %{check: check, reason: reason}

  defp invalid_report(reason) do
    %Report{
      ok?: false,
      checks: [],
      errors: [finding(:options, reason)],
      warnings: [],
      zones: %{mind: [], executor: []}
    }
  end

  defp compact_reason({module, reason}) when is_atom(module), do: {module, compact_reason(reason)}
  defp compact_reason(reason) when is_atom(reason), do: reason
  defp compact_reason(_reason), do: :unknown
end
