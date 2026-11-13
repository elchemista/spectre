defmodule Spectre.Server.Plan do
  @moduledoc false
  alias Spectre.Server

  # A consolidated plan is serial. Its generated prose is not a reliable
  # account of external effects, so only actual outcomes produce completion.
  def start(ctx, [%{operation: operation, args: args} = proposal | rest]) do
    Enum.each([proposal | rest], fn
      %{operation: _operation, args: args} when is_map(args) -> :ok
      _ -> raise ArgumentError, "invalid consolidated plan proposal"
    end)

    Server.propose(ctx, operation, args,
      on_result: {__MODULE__, rest},
      proposal_metadata: Map.get(proposal, :metadata, %{})
    )
  end

  def continue(ctx, remaining, {:governed, %{outcome: %{status: :succeeded}}}) do
    case remaining do
      [] -> Server.respond(ctx, "The operation completed.")
      proposals -> start(ctx, proposals)
    end
  end

  def continue(ctx, _remaining, {:governed, %{outcome: %{status: :ambiguous}}}),
    do: Server.respond(ctx, "The operation is still under verification.")

  def continue(ctx, _remaining, {:governed, %{act: act, outcome: nil}}) when not is_nil(act),
    do: Server.respond(ctx, "The operation is still under verification.")

  def continue(ctx, _remaining, {:governed_unknown, _details}),
    do: Server.respond(ctx, "The operation is still under verification.")

  def continue(ctx, _remaining, _result),
    do: Server.respond(ctx, "The operation could not be confirmed.")
end
