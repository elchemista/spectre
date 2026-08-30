defmodule Spectre.JSON do
  @moduledoc false

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    {:ok, encode!(value)}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec encode!(term()) :: binary()
  def encode!(value), do: value |> Elixir.JSON.encode!() |> IO.iodata_to_binary()

  @spec encode!(term(), term()) :: binary()
  def encode!(value, opts) do
    case pretty_option!(opts) do
      true -> value |> encode!() |> pretty()
      false -> encode!(value)
    end
  end

  @spec decode(binary()) :: {:ok, term()} | {:error, term()}
  def decode(value) do
    {:ok, decode!(value)}
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @spec decode!(binary()) :: term()
  def decode!(value), do: Elixir.JSON.decode!(value)

  @spec pretty_option!(term()) :: boolean()
  defp pretty_option!(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      validate_pretty_options!(opts)
    else
      raise ArgumentError, "expected JSON options to be a keyword list, got: #{inspect(opts)}"
    end
  end

  defp pretty_option!(opts) do
    raise ArgumentError, "expected JSON options to be a keyword list, got: #{inspect(opts)}"
  end

  @spec validate_pretty_options!(keyword()) :: boolean()
  defp validate_pretty_options!(opts) do
    keys = Keyword.keys(opts)
    unknown = Enum.reject(keys, &(&1 == :pretty))

    cond do
      unknown != [] ->
        raise ArgumentError, "unknown JSON options: #{inspect(Enum.uniq(unknown))}"

      Enum.count(keys, &(&1 == :pretty)) > 1 ->
        raise ArgumentError, "duplicate JSON option: :pretty"

      true ->
        validate_pretty_value!(Keyword.get(opts, :pretty, false))
    end
  end

  @spec validate_pretty_value!(term()) :: boolean()
  defp validate_pretty_value!(value) when is_boolean(value), do: value

  defp validate_pretty_value!(value) do
    raise ArgumentError, "expected :pretty to be a boolean, got: #{inspect(value)}"
  end

  @spec pretty(binary()) :: binary()
  defp pretty(json), do: json |> format_json(0, []) |> Enum.reverse() |> IO.iodata_to_binary()

  @spec format_json(binary(), non_neg_integer(), iodata()) :: iodata()
  defp format_json(<<>>, _indent, acc), do: acc

  defp format_json(<<"{}", rest::binary>>, indent, acc),
    do: format_json(rest, indent, ["{}" | acc])

  defp format_json(<<"[]", rest::binary>>, indent, acc),
    do: format_json(rest, indent, ["[]" | acc])

  defp format_json(<<"{", rest::binary>>, indent, acc) do
    next_indent = indent + 1
    format_json(rest, next_indent, [indentation(next_indent), "{\n" | acc])
  end

  defp format_json(<<"[", rest::binary>>, indent, acc) do
    next_indent = indent + 1
    format_json(rest, next_indent, [indentation(next_indent), "[\n" | acc])
  end

  defp format_json(<<"}", rest::binary>>, indent, acc) do
    next_indent = indent - 1
    format_json(rest, next_indent, ["}", ["\n", indentation(next_indent)] | acc])
  end

  defp format_json(<<"]", rest::binary>>, indent, acc) do
    next_indent = indent - 1
    format_json(rest, next_indent, ["]", ["\n", indentation(next_indent)] | acc])
  end

  defp format_json(<<",", rest::binary>>, indent, acc),
    do: format_json(rest, indent, [indentation(indent), ",\n" | acc])

  defp format_json(<<":", rest::binary>>, indent, acc),
    do: format_json(rest, indent, [": " | acc])

  defp format_json(<<"\"", rest::binary>>, indent, acc),
    do: format_string(rest, indent, false, ["\"" | acc])

  defp format_json(<<byte, rest::binary>>, indent, acc),
    do: format_json(rest, indent, [byte | acc])

  @spec format_string(binary(), non_neg_integer(), boolean(), iodata()) :: iodata()
  defp format_string(<<byte, rest::binary>>, indent, true, acc),
    do: format_string(rest, indent, false, [byte | acc])

  defp format_string(<<"\\", rest::binary>>, indent, false, acc),
    do: format_string(rest, indent, true, ["\\" | acc])

  defp format_string(<<"\"", rest::binary>>, indent, false, acc),
    do: format_json(rest, indent, ["\"" | acc])

  defp format_string(<<byte, rest::binary>>, indent, false, acc),
    do: format_string(rest, indent, false, [byte | acc])

  @spec indentation(non_neg_integer()) :: binary()
  defp indentation(level), do: :binary.copy("  ", level)
end
