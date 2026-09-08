defmodule Spectre.Vigil do
  @moduledoc """
  Reusable observation handlers on an explicitly opened vigil Scope.

  Implements handle_vigil/3 and handle_result/4. Event subscription, transport
  and timing belong to the host; the same Instance/advance path handles each
  request. Receiving an event does not authenticate it or fulfill the promise.
  """
  defmacro __using__(opts) do
    quote do: use(Spectre.Agent, Keyword.put(unquote(opts), :kind, :vigil))
  end
end
