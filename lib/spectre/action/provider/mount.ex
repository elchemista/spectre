defmodule Spectre.Action.Provider.Mount do
  @moduledoc """
  Trusted binding between a provider identifier and its implementation module.
  """

  defstruct [:id, :module, opts: []]

  @type t :: %__MODULE__{
          id: Spectre.Action.provider_ref(),
          module: module(),
          opts: keyword()
        }

  @spec new(Spectre.Action.provider_ref(), module(), keyword()) :: t()
  def new(id, module, opts \\ [])
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "action provider options must be a keyword list")

    # Reuse Action's reference validation without admitting a nil/empty id.
    _action = Spectre.Action.new(:__provider_validation__, via: id)
    %__MODULE__{id: id, module: module, opts: opts}
  end
end
