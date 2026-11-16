defmodule Spectre.GAM.Id.Source do
  @moduledoc "A replaceable source of operational UUIDv7 identifiers."

  @callback generate() :: Spectre.GAM.Id.t()
end
