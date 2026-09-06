defmodule Spectre.Input.Plugs.NormalizeText do
  @moduledoc """
  Local UTF-8 normalization for text input, without changing its trust level.

  Options: `:trim` and `:collapse_whitespace` (both default to `true`), `:case`
  (`nil`, `:downcase` or `:upcase`, default `nil`), and `:unicode` (`:nfc`,
  `:nfd`, `:nfkc`, `:nfkd` or `false`, default `:nfc`). Unknown or malformed
  options are rejected during initialization. Invalid UTF-8 is an error, not
  silently repaired; binary/media interpretation belongs to the application.
  """

  @behaviour Spectre.Input.Plug

  alias Spectre.Portable

  @defaults %{trim: true, collapse_whitespace: true, case: nil, unicode: :nfc}

  @impl true
  def init(opts) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(opts, Map.keys(@defaults), :normalize_text),
         config = Map.merge(@defaults, attrs),
         true <- valid_options?(config) do
      {:ok, config}
    else
      false -> {:error, :invalid_text_normalization_options}
      {:error, _} = error -> error
    end
  end

  @impl true
  def call(text, config) when is_binary(text) do
    if String.valid?(text) do
      text = if config.unicode == false, do: text, else: String.normalize(text, config.unicode)
      text = change_case(text, config.case)

      text =
        if config.collapse_whitespace, do: String.replace(text, ~r/\s+/u, " "), else: text

      {:cont, if(config.trim, do: String.trim(text), else: text)}
    else
      {:error, :invalid_input_text}
    end
  end

  def call(_input, _config), do: {:error, :invalid_input_text}

  defp valid_options?(config) do
    is_boolean(config.trim) and is_boolean(config.collapse_whitespace) and
      config.case in [nil, :downcase, :upcase] and
      config.unicode in [:nfc, :nfd, :nfkc, :nfkd, false]
  end

  defp change_case(text, nil), do: text
  defp change_case(text, :downcase), do: String.downcase(text)
  defp change_case(text, :upcase), do: String.upcase(text)
end
