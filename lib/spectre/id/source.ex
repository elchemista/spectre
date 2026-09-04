defmodule Spectre.Id.Source do
  @moduledoc "A replaceable source of operational UUIDv7 identifiers."

  @callback generate() :: Spectre.Id.t()
end
