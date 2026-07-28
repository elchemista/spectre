defmodule Spectre.Stack.Value do
  @moduledoc false

  @spec portable?(term()) :: boolean()
  def portable?(value) when is_pid(value) or is_port(value) or is_reference(value), do: false
  def portable?(value) when is_function(value), do: false
  def portable?([]), do: true
  def portable?([head | tail]), do: portable?(head) and portable_list_tail?(tail)

  def portable?(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.all?(&portable?/1)
  end

  def portable?(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.all?(fn {key, item} -> portable?(key) and portable?(item) end)
  end

  def portable?(_value), do: true

  @spec portable_list_tail?(term()) :: boolean()
  defp portable_list_tail?([]), do: true

  defp portable_list_tail?([head | tail]),
    do: portable?(head) and portable_list_tail?(tail)

  defp portable_list_tail?(_tail), do: false

  @spec ensure_portable!(term(), String.t()) :: term()
  def ensure_portable!(value, label) do
    unless portable?(value) do
      raise ArgumentError,
            "#{label} must be immutable data and cannot contain a PID, port, reference, or function"
    end

    value
  end

  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec entry_id(term()) :: term()
  def entry_id(%{id: id}), do: id
  def entry_id(entry), do: entry

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) do
    not is_nil(id) and portable?(id) and
      (is_atom(id) or is_binary(id) or is_integer(id) or is_tuple(id))
  end
end
