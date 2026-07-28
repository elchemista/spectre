defmodule Spectre.Extension.Mount do
  @moduledoc """
  Compile-time registration of one optional Spectre extension.

  The extension module contributes ports such as action providers or a planner;
  it does not own a second Agent compiler or runtime.
  """

  defstruct [:id, :module, api_version: 0, opts: [], compiled: nil]

  @type t :: %__MODULE__{
          id: term(),
          module: module(),
          api_version: non_neg_integer(),
          opts: keyword(),
          compiled: term()
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

    api_version =
      if function_exported?(module, :api_version, 0),
        do: module.api_version(),
        else: 0

    unless is_integer(api_version) and api_version >= 0,
      do: raise(ArgumentError, "invalid Spectre extension API version: #{inspect(api_version)}")

    %__MODULE__{
      id: id,
      module: module,
      api_version: api_version,
      opts: Keyword.delete(opts, :as)
    }
  end
end
