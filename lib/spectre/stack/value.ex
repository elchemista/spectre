defmodule Spectre.Stack.Value do
  @moduledoc """
  Portability checks and identity helpers for stack entry values.

  Stack definitions must be immutable data: no PIDs, ports, references or
  functions at any depth. These helpers enforce that constraint and derive
  deterministic digests and entry identifiers from portable values.
  """

  @doc """
  Returns `true` when `value` contains no PID, port, reference, function or
  improper list at any depth.
  """
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

  @doc """
  Returns `value` unchanged, raising `ArgumentError` when it is not portable.

  `label` names the offending value in the error message.
  """
  @spec ensure_portable!(term(), String.t()) :: term()
  def ensure_portable!(value, label) do
    unless portable?(value) do
      raise ArgumentError,
            "#{label} must be immutable data and cannot contain a PID, port, reference, or function"
    end

    value
  end

  @doc """
  Hashes `value` into a deterministic lowercase hex digest.

  The same value always produces the same digest, so digests can detect
  stack definition changes across restarts.
  """
  @spec digest(term()) :: String.t()
  def digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Extracts the identifier of a stack entry: its `:id` field when present,
  otherwise the entry itself.
  """
  @spec entry_id(term()) :: term()
  def entry_id(%{id: id}), do: id
  def entry_id(entry), do: entry

  @doc """
  Returns `true` when `id` is a portable atom, binary, integer or tuple.
  """
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) do
    not is_nil(id) and portable?(id) and
      (is_atom(id) or is_binary(id) or is_integer(id) or is_tuple(id))
  end
end
