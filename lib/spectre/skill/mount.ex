defmodule Spectre.Skill.Mount do
  @moduledoc """
  Compile-time mount of a reusable `Spectre.Skill` inside an Agent.

  A mount assigns a local identifier and binds logical Skill action names to
  concrete actions owned by the outer Agent.
  """

  defstruct [:id, :module, :definition_id, :definition_version, bindings: %{}, opts: []]

  @type t :: %__MODULE__{
          id: term(),
          module: module(),
          definition_id: term(),
          definition_version: pos_integer(),
          bindings: map(),
          opts: keyword()
        }

  @doc """
  Builds and validates a Skill mount from a compiled definition.
  """
  @spec new(module(), Spectre.Definition.t(), keyword()) :: t()
  def new(module, %Spectre.Definition{kind: :skill} = definition, opts)
      when is_atom(module) and is_list(opts) do
    case Keyword.fetch(opts, :governed) do
      :error ->
        :ok

      {:ok, operations} when is_list(operations) ->
        unless Enum.all?(operations, &(is_atom(&1) or is_binary(&1) or is_tuple(&1))),
          do: raise(ArgumentError, "Skill governed: expects host operation references")

      _ ->
        raise ArgumentError, "Skill governed: expects a list of host operation references"
    end

    id = Keyword.get(opts, :as, definition.id)
    bindings = opts |> Keyword.get(:bind, []) |> normalize_bindings()

    %__MODULE__{
      id: id,
      module: module,
      definition_id: definition.id,
      definition_version: definition.version,
      bindings: bindings,
      opts: Keyword.drop(opts, [:as, :bind])
    }
  end

  @doc """
  Returns the runtime scope represented by a mount.
  """
  @spec scope(t()) :: {:skill, term()}
  def scope(%__MODULE__{id: id}), do: {:skill, id}

  @spec normalize_bindings(keyword() | map()) :: map()
  defp normalize_bindings(bindings) when is_list(bindings), do: Map.new(bindings)
  defp normalize_bindings(bindings) when is_map(bindings), do: bindings

  defp normalize_bindings(bindings) do
    raise ArgumentError, "Skill bind: must be a keyword list or map, got: #{inspect(bindings)}"
  end
end
