defmodule Spectre.Worker do
  @moduledoc """
  Reusable handler authoring for a finite, explicitly promised unit of work.

  Implements handle_work/3 and handle_result/4 using the Agent return contract.
  The host opens a governed work Scope before starting its Instance. No timer,
  callback return or process exit fulfills or disposes that durable promise.
  """
  defmacro __using__(opts) do
    quote do: use(Spectre.Agent, Keyword.put(unquote(opts), :kind, :worker))
  end
end
