defmodule Spectre.Policy.Resolution do
  @moduledoc """
  Validated policy matcher decision shared by user text and trusted hosts.

  `source` identifies who supplied the evidence; lifecycle semantics depend
  only on `kind` and `label`.
  """

  defstruct [:kind, :label, :source, metadata: %{}]

  @type kind :: :accept | :reject
  @type source :: :user | :host | atom()
  @type t :: %__MODULE__{
          kind: kind(),
          label: atom(),
          source: source(),
          metadata: map()
        }

  @spec new(kind(), atom(), source(), map()) :: {:ok, t()} | {:error, term()}
  def new(kind, label, source, metadata \\ %{})

  def new(kind, label, source, metadata)
      when kind in [:accept, :reject] and is_atom(label) and is_atom(source) and is_map(metadata) do
    {:ok, %__MODULE__{kind: kind, label: label, source: source, metadata: metadata}}
  end

  def new(kind, label, source, metadata),
    do: {:error, {:invalid_policy_resolution, kind, label, source, metadata}}

  @spec to_tuple(t()) :: {:accept | :reject, atom()}
  def to_tuple(%__MODULE__{kind: kind, label: label}), do: {kind, label}
end
