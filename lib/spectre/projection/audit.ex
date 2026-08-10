defmodule Spectre.Projection.Audit do
  @moduledoc """
  Exact structural projection of a canonical Definition.

  Audit does not summarize, infer, render with an LLM, or add fields. Its
  content is byte-for-byte derivable from `Definition.Canonical.to_data/1`.
  """

  @behaviour Spectre.Projection

  alias Spectre.Definition.Canonical

  @generator_id "spectre.projection.audit"
  @generator_version 1

  @impl true
  @spec id() :: String.t()
  def id, do: @generator_id

  @impl true
  @spec version() :: pos_integer()
  def version, do: @generator_version

  @impl true
  @spec project(Canonical.t(), keyword()) :: {:ok, map()}
  def project(%Canonical{} = canonical, _opts), do: {:ok, Canonical.to_data(canonical)}
end
