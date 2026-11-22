defmodule Spectre.GAM.Id.Source do
  @moduledoc "A replaceable source of operational UUIDv7 identifiers."

  @doc "Returns a new operational UUIDv7 identifier."
  @callback generate() :: Spectre.GAM.Id.t()
end
