defmodule Spectre.Inference.StreamSanitizer do
  @moduledoc false

  # The structural core pass always runs first. A configured host extension
  # sees only complete UTF-8 accepted by that pass, so provider transport and
  # model-specific presentation policy remain separate concerns.

  alias Spectre.Inference.IncrementalSanitizer
  alias Spectre.Reply.Sanitizer.Runtime

  defstruct [:core, :extension, sanitize?: true]

  @type t :: %__MODULE__{
          core: IncrementalSanitizer.t(),
          extension: Runtime.stream_state(),
          sanitize?: boolean()
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) when is_list(opts) do
    with {:ok, extension} <- Runtime.init_stream(opts) do
      {:ok,
       %__MODULE__{
         core: IncrementalSanitizer.new(opts),
         extension: extension,
         sanitize?: Keyword.get(opts, :sanitize_reply, true)
       }}
    end
  end

  @spec push(t(), binary()) :: {:ok, binary(), t()} | {:error, term()}
  def push(%__MODULE__{} = sanitizer, chunk) when is_binary(chunk) do
    with {:ok, core_output, core} <- IncrementalSanitizer.push(sanitizer.core, chunk),
         {:ok, output, extension} <-
           Runtime.sanitize_chunk(sanitizer.extension, core_output) do
      {:ok, output, %{sanitizer | core: core, extension: extension}}
    end
  end

  @spec finish(t()) :: {:ok, binary(), t()} | {:error, term()}
  def finish(%__MODULE__{} = sanitizer) do
    with {:ok, core_output, core} <- IncrementalSanitizer.finish(sanitizer.core),
         {:ok, output, extension} <-
           Runtime.sanitize_chunk(sanitizer.extension, core_output),
         {:ok, trailing} <- Runtime.finish_stream(extension) do
      {:ok, output <> trailing, %{sanitizer | core: core, extension: extension}}
    end
  end
end
