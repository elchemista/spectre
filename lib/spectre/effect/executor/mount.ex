defmodule Spectre.Effect.Executor.Mount do
  @moduledoc """
  Immutable registration of one executor for a non-action effect kind.
  """

  @enforce_keys [:kind, :module]
  defstruct [:kind, :module, opts: []]

  @type t :: %__MODULE__{
          kind: atom(),
          module: module(),
          opts: keyword()
        }

  @spec new(atom(), module(), keyword()) :: t()
  def new(kind, module, opts \\ [])

  def new(kind, module, opts)
      when is_atom(kind) and not is_nil(kind) and is_atom(module) and not is_nil(module) and
             is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "effect executor options must be a keyword list")

    if kind == :action,
      do: raise(ArgumentError, ":action is owned by Spectre.ActionDispatcher")

    %__MODULE__{kind: kind, module: module, opts: opts}
  end

  def new(kind, module, opts) do
    raise ArgumentError,
          "invalid effect executor: #{inspect({kind, module, opts})}"
  end
end
