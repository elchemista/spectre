defmodule Spectre.Provider.Failure do
  @moduledoc """
  Sanitized infrastructure failure returned by a provider call boundary.

  Adapter-declared `{:error, reason}` values remain unchanged. This struct is
  reserved for failures introduced by execution itself: timeouts, exceptions,
  exits, throws, crashes, invalid replies, and invalid timeout configuration.
  It intentionally excludes prompts, inputs, adapter return values, and stack
  traces.
  """

  defstruct [:provider, :kind, :reason, :timeout, retryable?: false]

  @type kind ::
          :timeout | :exception | :exit | :throw | :crash | :invalid_reply | :configuration

  @type t :: %__MODULE__{
          provider: atom(),
          kind: kind(),
          reason: term(),
          timeout: timeout() | nil,
          retryable?: boolean()
        }

  @doc false
  @spec timeout(atom(), timeout()) :: t()
  def timeout(provider, timeout) do
    new(provider, :timeout, :deadline_exceeded, timeout: timeout, retryable?: true)
  end

  @doc false
  @spec exception(atom(), Exception.t()) :: t()
  def exception(provider, exception) do
    new(provider, :exception, exception.__struct__)
  end

  @doc false
  @spec caught(atom(), :exit | :throw | term(), term()) :: t()
  def caught(provider, :exit, reason) do
    new(provider, :exit, reason_code(reason), retryable?: true)
  end

  def caught(provider, :throw, reason) do
    new(provider, :throw, reason_code(reason))
  end

  def caught(provider, _kind, reason) do
    new(provider, :crash, reason_code(reason), retryable?: true)
  end

  @doc false
  @spec crash(atom(), term()) :: t()
  def crash(provider, reason) do
    new(provider, :crash, reason_code(reason), retryable?: true)
  end

  @doc false
  @spec invalid_reply(atom(), term()) :: t()
  def invalid_reply(provider, reply) do
    new(provider, :invalid_reply, reply_shape(reply))
  end

  @doc false
  @spec invalid_reply_field(atom(), atom(), term()) :: t()
  def invalid_reply_field(provider, field, value) when is_atom(field) do
    new(provider, :invalid_reply, {:invalid_field, field, reply_shape(value)})
  end

  @doc false
  @spec missing_reply_field(atom(), atom()) :: t()
  def missing_reply_field(provider, field) when is_atom(field) do
    new(provider, :invalid_reply, {:missing_field, field})
  end

  @doc false
  @spec invalid_timeout(atom(), term()) :: t()
  def invalid_timeout(provider, timeout) do
    new(provider, :configuration, {:invalid_timeout, safe_scalar(timeout)})
  end

  @doc false
  @spec invalid_options(atom()) :: t()
  def invalid_options(provider) do
    new(provider, :configuration, :invalid_provider_options)
  end

  @spec new(atom(), kind(), term(), keyword()) :: t()
  defp new(provider, kind, reason, opts \\ []) do
    %__MODULE__{
      provider: provider,
      kind: kind,
      reason: reason,
      timeout: Keyword.get(opts, :timeout),
      retryable?: Keyword.get(opts, :retryable?, false)
    }
  end

  @spec reason_code(term()) :: atom()
  defp reason_code(reason) when is_atom(reason), do: reason

  defp reason_code(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      code when is_atom(code) -> code
      _other -> :provider_failure
    end
  end

  defp reason_code(%{reason: reason}), do: reason_code(reason)
  defp reason_code(_reason), do: :provider_failure

  @spec reply_shape(term()) :: term()
  defp reply_shape(value) when is_binary(value), do: :binary
  defp reply_shape(value) when is_atom(value), do: :atom
  defp reply_shape(value) when is_number(value), do: :number
  defp reply_shape(value) when is_list(value), do: :list
  defp reply_shape(%{__struct__: module}), do: {:struct, module}
  defp reply_shape(value) when is_map(value), do: :map
  defp reply_shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp reply_shape(value) when is_function(value), do: :function
  defp reply_shape(_value), do: :unknown

  @spec safe_scalar(term()) :: term()
  defp safe_scalar(value) when is_atom(value) or is_number(value), do: value
  defp safe_scalar(_value), do: :invalid
end
