defmodule Spectre.Instance.Telemetry do
  @moduledoc false

  alias Spectre.Canonical.Value
  alias Spectre.Instance.State, as: InstanceState

  @doc """
  Emits one Instance event with an opaque identity and no subject data.

  Measurements are numeric values. Revisions, identifier digests, and failure
  classes belong in the separate metadata map.
  """
  @spec emit(atom(), InstanceState.t(), map(), map()) :: :ok
  def emit(event, %InstanceState{} = data, measurements, metadata \\ %{})
      when is_map(measurements) and is_map(metadata) do
    Spectre.Telemetry.emit(
      [:instance, event],
      measurements,
      Map.merge(metadata, %{
        agent: data.agent,
        instance_id: instance_id(data),
        generation: data.generation
      }),
      data.base_opts
    )
  end

  @doc "Returns a stable digest for an identifier without exposing its raw value."
  @spec id_digest(term()) :: String.t()
  def id_digest(value) do
    case Value.digest(value) do
      {:ok, digest} -> digest
      {:error, _reason} -> "unavailable"
    end
  end

  @doc "Reduces an arbitrary failure term to a privacy-safe atom class."
  @spec reason_class(term()) :: atom()
  def reason_class(%{kind: kind}) when is_atom(kind), do: kind

  def reason_class(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      kind when is_atom(kind) -> kind
      _other -> :error
    end
  end

  def reason_class(reason) when is_atom(reason), do: reason
  def reason_class(_reason), do: :error

  @spec instance_id(InstanceState.t()) :: String.t()
  defp instance_id(%InstanceState{ref: %{key: key}}) when is_binary(key),
    do: id_digest(key)

  defp instance_id(%InstanceState{}), do: "unavailable"
end
