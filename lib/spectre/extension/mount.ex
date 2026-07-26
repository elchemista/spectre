defmodule Spectre.Extension.Mount do
  @moduledoc """
  Compile-time registration of one optional Spectre extension.

  The extension module contributes ports such as action providers or a planner;
  it does not own a second Agent compiler or runtime.
  """

  defstruct [:id, :module, opts: []]

  @type t :: %__MODULE__{
          id: term(),
          module: module(),
          opts: keyword()
        }

  @spec new(module(), keyword()) :: t()
  def new(module, opts) when is_atom(module) and not is_nil(module) and is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "Spectre extension options must be a keyword list")

    unless Code.ensure_loaded?(module) do
      raise ArgumentError, "unknown Spectre extension module: #{inspect(module)}"
    end

    id =
      cond do
        Keyword.has_key?(opts, :as) -> Keyword.fetch!(opts, :as)
        function_exported?(module, :id, 0) -> module.id()
        true -> module
      end

    %__MODULE__{id: id, module: module, opts: Keyword.delete(opts, :as)}
  end
end
