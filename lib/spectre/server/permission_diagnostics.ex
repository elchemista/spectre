defmodule Spectre.Server.PermissionDiagnostics do
  @moduledoc """
  Checks concrete mount operation references against root configuration.

  Root authority and mount restrictions intentionally intersect. Reports expose
  configuration references only, never capabilities or execution payloads.
  A narrower root is permitted by default; `strict_permissions: true` rejects
  a mounted operation absent from root configuration before resources start.
  """

  @doc "Reports mounted operations unavailable under the supplied root allowlist."
  @spec report(module(), map()) :: [map()]
  def report(agent, operations) when is_atom(agent) and is_map(operations) do
    Code.ensure_loaded!(agent)

    mounts =
      if function_exported?(agent, :__spectre_skills__, 0),
        do: agent.__spectre_skills__(),
        else: []

    Enum.flat_map(mounts, fn mount ->
      allowed = Keyword.get(mount.opts, :governed, Map.values(mount.bindings))

      allowed
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(operations, &1))
      |> Enum.map(fn operation ->
        %{
          code: :mount_operation_not_enabled,
          mount: mount.id,
          operation: operation,
          severity: :warning
        }
      end)
    end)
  end

  @doc false
  @spec validate_options!(module(), keyword()) :: :ok
  def validate_options!(agent, opts) do
    strict = Keyword.get(opts, :strict_permissions, false)
    unless is_boolean(strict), do: raise(ArgumentError, "strict_permissions must be boolean")

    if strict and is_list(Keyword.get(opts, :gam)) and not Keyword.has_key?(opts, :skill) do
      operations = Keyword.get(opts[:gam], :operations, %{})

      validate_operations!(agent, operations)
    end

    :ok
  end

  defp validate_operations!(agent, operations) when is_map(operations) do
    case report(agent, operations) do
      [] ->
        :ok

      issues ->
        raise ArgumentError, "incompatible Skill operation permissions: #{inspect(issues)}"
    end
  end

  defp validate_operations!(_agent, _operations), do: :ok
end
