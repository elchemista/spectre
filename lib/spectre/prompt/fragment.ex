defmodule Spectre.Prompt.Fragment do
  @moduledoc """
  Resolved prompt content with its composition metadata.
  """

  defstruct [:id, :content, :scope, :target, :position, :source, metadata: %{}]

  @type t :: %__MODULE__{
          id: term(),
          content: String.t(),
          scope: term(),
          target: Spectre.Prompt.Operation.target(),
          position: Spectre.Prompt.Operation.position(),
          source: Spectre.Prompt.Operation.source() | :base,
          metadata: map()
        }

  @doc """
  Builds a resolved prompt fragment from an operation.
  """
  @spec new(Spectre.Prompt.Operation.t(), String.t(), map()) :: t()
  def new(%Spectre.Prompt.Operation{} = operation, content, metadata \\ %{})
      when is_binary(content) and is_map(metadata) do
    %__MODULE__{
      id: operation.id,
      content: content,
      scope: operation.scope,
      target: operation.target,
      position: operation.position,
      source: operation.source,
      metadata: metadata
    }
  end

  @doc """
  Builds the base task fragment selected by `ask`.
  """
  @spec base(String.t()) :: t()
  def base(content) when is_binary(content) do
    %__MODULE__{
      id: :base_task,
      content: content,
      scope: :base,
      target: :task,
      position: :end,
      source: :base
    }
  end
end
