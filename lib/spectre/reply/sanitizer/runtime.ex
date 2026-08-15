defmodule Spectre.Reply.Sanitizer.Runtime do
  @moduledoc false

  # Resolves and invokes the optional host sanitizer without leaking callback
  # state into durable inference values. Terminal failures retain the safe
  # core result; streaming failures stay explicit because continuing would
  # join two different sanitization histories.

  @terminal_callbacks [sanitize: 2]
  @stream_callbacks [init_stream: 1, sanitize_chunk: 2, finish_stream: 1]

  defstruct [:module, :state]

  @type stream_state :: %__MODULE__{module: module(), state: term()} | nil

  @spec validate(keyword(), :terminal | :stream) :: :ok | {:error, term()}
  def validate(opts, mode) when is_list(opts) and mode in [:terminal, :stream] do
    with :ok <- validate_enabled_flag(opts) do
      validate_active_extension(opts, mode)
    end
  end

  @spec sanitize(binary(), keyword()) :: binary()
  def sanitize(text, opts) when is_binary(text) and is_list(opts) do
    case active_extension(opts) do
      {:ok, extension} -> sanitize_extension(text, extension)
      {:error, _reason} -> text
    end
  end

  @spec init_stream(keyword()) :: {:ok, stream_state()} | {:error, term()}
  def init_stream(opts) when is_list(opts) do
    with :ok <- validate(opts, :stream),
         {:ok, extension} <- active_extension(opts) do
      init_extension_stream(extension)
    end
  end

  @spec sanitize_chunk(stream_state(), binary()) ::
          {:ok, binary(), stream_state()} | {:error, term()}
  def sanitize_chunk(nil, text) when is_binary(text), do: {:ok, text, nil}
  def sanitize_chunk(%__MODULE__{} = stream, ""), do: {:ok, "", stream}

  def sanitize_chunk(%__MODULE__{module: module, state: state} = stream, text)
      when is_binary(text) do
    case invoke(module, :sanitize_chunk, [text, state]) do
      {:ok, {:ok, clean, next_state}} when is_binary(clean) ->
        if String.valid?(clean),
          do: {:ok, clean, %{stream | state: next_state}},
          else: callback_error(module, :sanitize_chunk, :invalid_utf8)

      {:ok, {:error, reason}} ->
        callback_error(module, :sanitize_chunk, reason)

      {:ok, _invalid} ->
        callback_error(module, :sanitize_chunk, :invalid_reply)

      {:error, reason} ->
        callback_error(module, :sanitize_chunk, reason)
    end
  end

  @spec finish_stream(stream_state()) :: {:ok, binary()} | {:error, term()}
  def finish_stream(nil), do: {:ok, ""}

  def finish_stream(%__MODULE__{module: module, state: state}) do
    case invoke(module, :finish_stream, [state]) do
      {:ok, {:ok, trailing}} when is_binary(trailing) ->
        if String.valid?(trailing),
          do: {:ok, trailing},
          else: callback_error(module, :finish_stream, :invalid_utf8)

      {:ok, {:error, reason}} ->
        callback_error(module, :finish_stream, reason)

      {:ok, _invalid} ->
        callback_error(module, :finish_stream, :invalid_reply)

      {:error, reason} ->
        callback_error(module, :finish_stream, reason)
    end
  end

  defp init_extension_stream(nil), do: {:ok, nil}

  defp init_extension_stream({module, extension_opts}) do
    case invoke(module, :init_stream, [extension_opts]) do
      {:ok, {:ok, state}} -> {:ok, %__MODULE__{module: module, state: state}}
      {:ok, {:error, reason}} -> callback_error(module, :init_stream, reason)
      {:ok, _invalid} -> callback_error(module, :init_stream, :invalid_reply)
      {:error, reason} -> callback_error(module, :init_stream, reason)
    end
  end

  defp active_extension(opts) do
    if Keyword.get(opts, :sanitize_reply, true) do
      normalize_extension(Keyword.get(opts, :reply_sanitizer))
    else
      {:ok, nil}
    end
  end

  defp sanitize_extension(text, nil), do: text

  defp sanitize_extension(text, {module, extension_opts}) do
    case invoke(module, :sanitize, [text, extension_opts]) do
      {:ok, clean} when is_binary(clean) -> if(String.valid?(clean), do: clean, else: text)
      _invalid_or_failed -> text
    end
  end

  defp normalize_extension(nil), do: {:ok, nil}

  defp normalize_extension(module) when is_atom(module) and not is_nil(module),
    do: {:ok, {module, []}}

  defp normalize_extension({module, opts})
       when is_atom(module) and not is_nil(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, {module, opts}},
      else: {:error, :invalid_reply_sanitizer_configuration}
  end

  defp normalize_extension(_invalid), do: {:error, :invalid_reply_sanitizer_configuration}

  defp validate_extension(nil, _mode), do: :ok

  defp validate_extension({module, _opts}, mode) do
    callbacks =
      case mode do
        :terminal -> @terminal_callbacks
        :stream -> @terminal_callbacks ++ @stream_callbacks
      end

    if Code.ensure_loaded?(module) do
      validate_callbacks(module, callbacks)
    else
      {:error, {:reply_sanitizer_not_loaded, module}}
    end
  end

  defp validate_active_extension(opts, mode) do
    if Keyword.get(opts, :sanitize_reply, true) do
      with {:ok, extension} <- normalize_extension(Keyword.get(opts, :reply_sanitizer)),
           do: validate_extension(extension, mode)
    else
      :ok
    end
  end

  defp validate_callbacks(module, callbacks) do
    case Enum.find(callbacks, fn {function, arity} ->
           not function_exported?(module, function, arity)
         end) do
      nil ->
        :ok

      {function, arity} ->
        {:error, {:reply_sanitizer_callback_missing, module, function, arity}}
    end
  end

  defp validate_enabled_flag(opts) do
    if Keyword.get(opts, :sanitize_reply, true) in [true, false],
      do: :ok,
      else: {:error, :invalid_sanitizer_configuration}
  end

  defp invoke(module, callback, args) do
    {:ok, apply(module, callback, args)}
  rescue
    exception -> {:error, {:exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {kind, error_class(reason)}}
  end

  defp callback_error(module, callback, reason) do
    {:error, {:reply_sanitizer_failed, module, callback, error_class(reason)}}
  end

  defp error_class(reason) when is_atom(reason), do: reason
  defp error_class(%{__struct__: module}), do: module
  defp error_class(reason) when is_tuple(reason) and tuple_size(reason) > 0, do: elem(reason, 0)
  defp error_class(reason) when is_map(reason), do: :map
  defp error_class(reason) when is_list(reason), do: :list
  defp error_class(reason) when is_binary(reason), do: :binary
  defp error_class(_reason), do: :other
end
