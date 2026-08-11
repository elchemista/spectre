defmodule Spectre.Governance.Checker.Declarative.Shape do
  @moduledoc """
  Provides one stable shape vocabulary for declarative-checker errors.
  """

  @type t :: :binary | :list | :map | :tuple | :other

  @doc false
  @spec of(term()) :: t()
  def of(value) when is_binary(value), do: :binary
  def of(value) when is_list(value), do: :list
  def of(value) when is_map(value), do: :map
  def of(value) when is_tuple(value), do: :tuple
  def of(_value), do: :other
end
