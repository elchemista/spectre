defmodule Spectre.Journal.Store do
  @moduledoc """
  Storage boundary for structured Spectre journal records.

  A store only needs to append records. Querying, retention, indexing, and
  transactional outboxes remain application concerns.
  """

  @callback append(Spectre.Journal.Record.t(), keyword()) ::
              :ok | {:ok, term()} | {:error, term()}
end
