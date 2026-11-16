defmodule Spectre.Server.GAM.Managed.Material do
  @moduledoc false

  @hidden ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/u

  @doc false
  @spec render(term()) :: binary()
  def render(value) when is_binary(value), do: quoted(value)
  def render(nil), do: "nil"
  def render(value) when is_boolean(value) or is_number(value), do: to_string(value)
  def render(value) when is_atom(value), do: ":" <> quoted(Atom.to_string(value))

  def render(value) when is_map(value) do
    labels = Enum.frequencies_by(Map.keys(value), &label/1)

    entries =
      value
      |> Enum.sort_by(fn {key, _} -> {label(key), exact_key(key)} end)
      |> Enum.map(fn {key, item} ->
        name = if labels[label(key)] == 1, do: label(key), else: exact_key(key)
        name <> ": " <> render(item)
      end)

    collection("{", "}", entries)
  end

  def render(value) when is_list(value), do: collection("[", "]", Enum.map(value, &render/1))

  def render(value) when is_tuple(value),
    do: collection("tuple(", ")", value |> Tuple.to_list() |> Enum.map(&render/1))

  @spec collection(binary(), binary(), [binary()]) :: binary()
  defp collection(open, close, []), do: open <> close

  defp collection(open, close, entries),
    do: open <> "\n" <> Enum.map_join(entries, "\n", &indent/1) <> "\n" <> close

  @spec indent(binary()) :: binary()
  defp indent(value), do: "  " <> String.replace(value, "\n", "\n  ")

  @spec label(term()) :: binary()
  defp label(key) when is_atom(key) or is_binary(key) do
    text = to_string(key)

    if Regex.match?(~r/\A[A-Za-z][A-Za-z0-9_ ]*\z/, text),
      do: text |> String.replace("_", " ") |> String.capitalize(),
      else: exact_key(key)
  end

  defp label(key), do: exact_key(key)

  @spec exact_key(term()) :: binary()
  defp exact_key(key) when is_binary(key), do: quoted(key)
  defp exact_key(key) when is_atom(key), do: ":" <> quoted(Atom.to_string(key))
  defp exact_key(key), do: "key(" <> render(key) <> ")"

  @spec quoted(binary()) :: binary()
  defp quoted(value) do
    if String.valid?(value) do
      "\"" <> (value |> String.codepoints() |> Enum.map_join(&escape/1)) <> "\""
    else
      "binary(0x" <> Base.encode16(value) <> ")"
    end
  end

  @spec escape(binary()) :: binary()
  defp escape("\""), do: "\\\""
  defp escape("\\"), do: "\\\\"
  defp escape("\n"), do: "\\n"
  defp escape("\r"), do: "\\r"
  defp escape("\t"), do: "\\t"

  defp escape(char) do
    if Regex.match?(@hidden, char) do
      <<codepoint::utf8>> = char
      "\\u{" <> String.upcase(Integer.to_string(codepoint, 16)) <> "}"
    else
      char
    end
  end
end
