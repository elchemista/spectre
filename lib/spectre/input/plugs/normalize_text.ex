defmodule Spectre.Input.Plugs.NormalizeText do
  @moduledoc """
  Normalizes `input.text` before Spectre handles a turn.

  Options:

    * `:trim` - trims leading/trailing whitespace. Defaults to `true`.
    * `:collapse_whitespace` - collapses whitespace runs to one space.
      Defaults to `true`.
    * `:case` - `:downcase`, `:upcase`, or `nil`. Defaults to `nil`.
    * `:unicode` - `:nfc`, `:nfd`, `:nfkc`, `:nfkd`, or `false`.
      Defaults to `:nfc`.
  """

  @behaviour Spectre.Input.Plug

  @impl Spectre.Input.Plug
  def rehearsable?, do: true

  @impl Spectre.Input.Plug
  def init(opts), do: opts

  @impl Spectre.Input.Plug
  def call(%Spectre.Input{} = input, _context, opts) do
    {:cont, %{input | text: normalize(input.text, opts)}}
  end

  @spec normalize(String.t(), keyword()) :: String.t()
  defp normalize(text, opts) do
    text
    |> maybe_normalize_unicode(Keyword.get(opts, :unicode, :nfc))
    |> maybe_case(Keyword.get(opts, :case))
    |> maybe_collapse_whitespace(Keyword.get(opts, :collapse_whitespace, true))
    |> maybe_trim(Keyword.get(opts, :trim, true))
  end

  defp maybe_normalize_unicode(text, false), do: text
  defp maybe_normalize_unicode(text, nil), do: text
  defp maybe_normalize_unicode(text, form), do: String.normalize(text, form)

  defp maybe_case(text, :downcase), do: String.downcase(text)
  defp maybe_case(text, :upcase), do: String.upcase(text)
  defp maybe_case(text, _case), do: text

  defp maybe_collapse_whitespace(text, true), do: String.replace(text, ~r/\s+/u, " ")
  defp maybe_collapse_whitespace(text, _collapse?), do: text

  defp maybe_trim(text, true), do: String.trim(text)
  defp maybe_trim(text, _trim?), do: text
end
