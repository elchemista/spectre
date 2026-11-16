defmodule Spectre.Server.GAM.Managed.Content do
  @moduledoc false
  alias Spectre.GAM
  alias Spectre.Server.GAM.Managed.Payload

  @fields ~w(payload execution_identity execution_context managed_policy bound)

  def protect_consequence(nil, consequence, _domain, _command), do: {:ok, consequence}

  def protect_consequence(config, consequence, domain, command) do
    with {:ok, reference} <-
           Payload.protect(
             config,
             Map.take(consequence, @fields),
             %{kind: :operation, domain_ref: domain, command_id: command}
           ) do
      {:ok, Map.merge(consequence, Map.new(@fields, &{&1, reference}))}
    end
  end

  def consequence(nil, consequence, _domain), do: {:ok, consequence}

  def consequence(
        config,
        %{"payload" => %{"spectre_payload" => 1, "reference" => _} = reference} = consequence,
        domain
      )
      when map_size(reference) == 2 do
    with {:ok, material} <- Payload.restore(config, reference, context(domain, :operation)),
         {:ok, material} <- operation_material(material) do
      {:ok, Map.merge(consequence, material)}
    end
  end

  def consequence(_config, consequence, _domain), do: {:ok, consequence}

  defp operation_material(material) when is_map(material) do
    if Enum.all?(@fields, &is_map(Map.get(material, &1))),
      do: {:ok, Map.take(material, @fields)},
      else: {:error, :invalid_operation_payload}
  end

  defp operation_material(_), do: {:error, :invalid_operation_payload}

  def act(config, %{consequence: consequence} = act, domain) do
    with {:ok, consequence} <- consequence(config, consequence, domain),
         do: {:ok, %{act | consequence: consequence}}
  end

  def presentation(nil, presentation, _domain), do: {:ok, presentation}

  def presentation(
        config,
        %{rendered_payload: payload, candidate_binding_ref: binding} = show,
        domain
      ) do
    with {:ok, reference} <-
           Payload.protect(
             config,
             payload,
             %{kind: :presentation, domain_ref: domain, candidate_binding_ref: binding}
           ) do
      show
      |> Map.from_struct()
      |> Map.drop([:ref, :material_digest])
      |> Map.put(:rendered_payload, reference)
      |> GAM.Presentation.new()
    end
  end

  def shown(config, material, domain) do
    with {:ok, rendered} <-
           Payload.restore(config, material["rendered_payload"], context(domain, :presentation)),
         do: {:ok, Map.put(material, "rendered_payload", rendered)}
  end

  def context(domain, kind), do: %{kind: kind, domain_ref: domain}
end
