defmodule Spectre.Adapter.Options do
  @moduledoc """
  Optional, side-effect-free validation of an authoring adapter's configuration.

  Opt in with `@behaviour Spectre.Adapter.Options` and implement
  `validate_options/1`. Wiring calls it after merging static and host options,
  on backend options only: not tenant/conversation/cache bindings, History's
  observer, or the request declaration injected at execution time. A coincidental
  function of the same name does not opt in. Existing adapters need not change.

  Return `:ok` or `{:error, reason}`. Reasons are `:invalid_options`,
  `{:missing_option, key}`, `{:invalid_option, key}`, or
  `{:unknown_options, keys}`, with atom option names. Other reasons are replaced
  with `:invalid_options`; malformed replies with `:invalid_validator_reply`.
  Do not put payloads, secrets or option values in reasons (including key names).
  The framework checks the shape, not the meaning of application-defined names.

  Validate shape only; do not normalize, add defaults, start processes, query
  servers or call providers. Those remain the adapter's explicit runtime work.
  This callback executes host code, not a sandbox. Ordinary use-time validation
  remains necessary, including when the caller does not use Agent Wiring.
  """

  alias Spectre.{Adapter, Portable}

  @type reason ::
          :invalid_options
          | {:missing_option | :invalid_option, atom()}
          | {:unknown_options, [atom()]}
  @callback validate_options(keyword()) :: :ok | {:error, reason()}

  @doc false
  def validate(module, opts) do
    with true <- Portable.keyword?(opts),
         :ok <- Adapter.validate(module, []) do
      behaviours =
        module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

      if __MODULE__ in behaviours do
        invoke(module, opts)
      else
        :ok
      end
    else
      false -> {:error, :invalid_options}
      error -> error
    end
  end

  defp invoke(module, opts) do
    with :ok <- Adapter.validate(module, validate_options: 1),
         {:ok, reply} <- Adapter.invoke(module, :validate_options, [opts]) do
      case reply do
        :ok -> :ok
        {:error, reason} -> {:error, safe_reason(reason)}
        _invalid -> {:error, :invalid_validator_reply}
      end
    end
  end

  defp safe_reason({kind, key} = reason)
       when kind in [:missing_option, :invalid_option] and is_atom(key), do: reason

  defp safe_reason({:unknown_options, keys} = reason) when is_list(keys) do
    if length(keys) <= 64 and Enum.all?(keys, &is_atom/1), do: reason, else: :invalid_options
  end

  defp safe_reason(_other), do: :invalid_options
end
