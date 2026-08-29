defmodule Spectre.Router.Adapter.Diagnostics do
  @moduledoc false

  alias Spectre.Definition
  alias Spectre.Router.Adapter.Compiler
  alias Spectre.Router.Adapter.Plan

  @doc false
  @spec checks(Definition.t(), keyword()) :: [map()]
  def checks(%Definition{} = definition, router_opts) when is_list(router_opts) do
    compiled = Compiler.compiled_adapters(definition.router)
    effective_opts = Keyword.merge(definition.router, router_opts)

    case Plan.build(compiled, effective_opts) do
      {:ok, plan} -> plan_checks(definition, compiled, plan)
      {:error, reason} -> plan_errors(reason)
    end
  rescue
    _exception -> plan_errors(:router_adapter_diagnostics_exception)
  catch
    _kind, _reason -> plan_errors(:router_adapter_diagnostics_failure)
  end

  @doc false
  @spec skipped(atom()) :: [map()]
  def skipped(reason) when is_atom(reason) do
    [
      check(:skipped, "router.adapters", reason),
      check(:skipped, "router.adapter_dependencies", reason),
      check(:skipped, "router.adapter_descriptors", reason),
      check(:skipped, "router.adapter_thresholds", reason)
    ]
  end

  @spec plan_checks(Definition.t(), map(), Plan.t()) :: [map()]
  defp plan_checks(definition, compiled, plan) do
    entries = Plan.entries(plan)
    active_ids = Enum.map(entries, & &1.id)
    dependencies = Compiler.dependency_report(definition, active_ids)

    [
      inventory_check(compiled, entries),
      dependency_check(dependencies),
      descriptor_check(entries),
      threshold_check(entries)
    ]
  end

  @spec inventory_check(map(), [Plan.entry()]) :: map()
  defp inventory_check(compiled, entries) do
    adapters =
      Enum.map(entries, fn entry ->
        %{id: entry.id, module: inspect(entry.module), order: entry.order}
      end)

    check(:ok, "router.adapters", :router_adapters_observed, %{
      registered_count: map_size(compiled),
      active_count: length(entries),
      adapters: adapters
    })
  end

  @spec dependency_check(%{warnings: [map()], errors: [map()]}) :: map()
  defp dependency_check(%{warnings: warnings, errors: errors}) do
    details = %{
      warning_count: length(warnings),
      error_count: length(errors),
      findings: Enum.map(errors ++ warnings, &dependency_details/1)
    }

    cond do
      errors != [] ->
        check(
          :error,
          "router.adapter_dependencies",
          :router_adapter_dependencies_unresolvable,
          details
        )

      warnings != [] ->
        check(
          :warning,
          "router.adapter_dependencies",
          :router_adapter_dependencies_degraded,
          details
        )

      true ->
        check(
          :ok,
          "router.adapter_dependencies",
          :router_adapter_dependencies_resolved,
          details
        )
    end
  end

  @spec dependency_details(map()) :: map()
  defp dependency_details(finding) do
    %{
      status: finding.status,
      scope: inspect(finding.scope),
      label: inspect(finding.label),
      unresolved: Enum.map(finding.unresolved, &to_string/1)
    }
  end

  @spec descriptor_check([Plan.entry()]) :: map()
  defp descriptor_check(entries) do
    unavailable =
      Enum.flat_map(entries, fn
        %{id: id, availability: {:unavailable, _diagnostic}} -> [id]
        _available -> []
      end)

    if unavailable == [] do
      check(:ok, "router.adapter_descriptors", :router_adapter_descriptors_available, %{
        adapter_count: length(entries)
      })
    else
      check(
        :warning,
        "router.adapter_descriptors",
        :router_adapter_descriptors_unavailable,
        %{adapter_count: length(entries), unavailable: unavailable}
      )
    end
  end

  @spec threshold_check([Plan.entry()]) :: map()
  defp threshold_check(entries) do
    thresholds =
      Enum.map(entries, fn entry ->
        %{
          id: entry.id,
          band: entry.descriptor.strength,
          accept: entry.descriptor.accept,
          margin: entry.descriptor.margin,
          order: entry.order
        }
      end)

    check(:ok, "router.adapter_thresholds", :router_adapter_thresholds_observed, %{
      adapters: thresholds
    })
  end

  @spec plan_errors(term()) :: [map()]
  defp plan_errors(reason) do
    code = diagnostic_reason(reason)

    [
      check(:error, "router.adapters", code),
      check(:skipped, "router.adapter_dependencies", :router_adapter_plan_unavailable),
      check(:skipped, "router.adapter_descriptors", :router_adapter_plan_unavailable),
      check(:skipped, "router.adapter_thresholds", :router_adapter_plan_unavailable)
    ]
  end

  @spec diagnostic_reason(term()) :: atom()
  defp diagnostic_reason({reason, _detail}) when is_atom(reason), do: reason
  defp diagnostic_reason(reason) when is_atom(reason), do: reason
  defp diagnostic_reason(_reason), do: :router_adapter_plan_invalid

  @spec check(atom(), String.t(), atom(), map()) :: map()
  defp check(status, id, code, details \\ %{}) do
    summary = code |> Atom.to_string() |> String.replace("_", " ")
    %{id: id, status: status, code: code, summary: summary, details: details}
  end
end
