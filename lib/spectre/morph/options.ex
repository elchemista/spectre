defmodule Spectre.Morph.Options do
  @moduledoc """
  Validates the closed keyword contracts exposed by the Morph facade.

  Keeping option shape and required-text validation here gives every Morph
  stage the same duplicate, unknown-key, and missing-value semantics.
  """

  @doc false
  @spec validate(term(), [atom()]) :: :ok | {:error, term()}
  def validate(opts, allowed) when is_list(allowed) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, {:invalid_morph_options, opts}}

      duplicate_keys?(opts) ->
        {:error, :duplicate_morph_options}

      true ->
        reject_unknown(opts, allowed)
    end
  end

  @doc false
  @spec require_nonempty(term(), atom()) :: :ok | {:error, term()}
  def require_nonempty(value, _field) when is_binary(value) and value != "", do: :ok
  def require_nonempty(value, field), do: {:error, {:morph_requires, field, value}}

  @doc false
  @spec optional_nonempty(term(), atom()) :: :ok | {:error, term()}
  def optional_nonempty(nil, _field), do: :ok
  def optional_nonempty(value, field), do: require_nonempty(value, field)

  @spec reject_unknown(keyword(), [atom()]) :: :ok | {:error, term()}
  defp reject_unknown(opts, allowed) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_morph_options, unknown}}
    end
  end

  @spec duplicate_keys?(keyword()) :: boolean()
  defp duplicate_keys?(opts) do
    keys = Keyword.keys(opts)
    MapSet.size(MapSet.new(keys)) != length(keys)
  end
end
