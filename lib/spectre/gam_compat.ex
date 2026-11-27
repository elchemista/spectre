# The released Stack packages still call these adapter entry points. Keep them
# as delegates while those packages migrate to ExGAM.
defmodule Spectre.GAM.Canonical.Value do
  @moduledoc false

  defdelegate encode(value, opts \\ []), to: ExGAM.Canonical.Value
  defdelegate encode!(value, opts \\ []), to: ExGAM.Canonical.Value
  defdelegate decode(bytes, opts \\ []), to: ExGAM.Canonical.Value
  defdelegate digest(value, opts \\ []), to: ExGAM.Canonical.Value
  defdelegate digest!(value, opts \\ []), to: ExGAM.Canonical.Value
  defdelegate validate(value, opts \\ []), to: ExGAM.Canonical.Value
end

defmodule Spectre.GAM.Portable do
  @moduledoc false

  defdelegate sha256_digest?(value), to: ExGAM.Portable
end

defmodule Spectre.GAM.Ledger.Entry do
  @moduledoc false

  defdelegate genesis_digest(), to: ExGAM.Ledger.Entry
end

defmodule Spectre.GAM.Ledger.Reader do
  @moduledoc false

  defdelegate reduce(store, domain, cursor, initial, reducer, opts \\ []), to: ExGAM.Ledger.Reader
end

defmodule Spectre.GAM.Ledger.Store do
  @moduledoc false

  defdelegate head(store, domain, opts \\ []), to: ExGAM.Ledger.Store
end

defmodule Spectre.GAM.Ledger.Store.Postgres do
  @moduledoc false
  @behaviour ExGAM.Ledger.Store

  alias ExGAM.Ledger.Store.Postgres

  defdelegate namespace(opts \\ []), to: Postgres
  defdelegate migration_sql(opts \\ []), to: Postgres
  @impl true
  defdelegate append(domain, batch, payloads, revision, opts), to: Postgres
  @impl true
  defdelegate load(domain, opts), to: Postgres
  @impl true
  defdelegate load_from(domain, revision, opts), to: Postgres
  @impl true
  defdelegate head(domain, opts), to: Postgres
  @impl true
  defdelegate read_batch(domain, revision, opts), to: Postgres
  @impl true
  defdelegate lookup_batch(domain, batch, opts), to: Postgres
  @impl true
  defdelegate export(domain, opts), to: Postgres
end

defmodule Spectre.GAM.Domain.Projection.Rows do
  @moduledoc false

  defdelegate collections(), to: ExGAM.Domain.Projection.Rows
  defdelegate encode(value), to: ExGAM.Domain.Projection.Rows
  defdelegate decode(bytes), to: ExGAM.Domain.Projection.Rows
end

defmodule Spectre.GAM.Domain.Projection.IndexRows do
  @moduledoc false

  defdelegate group(collection, key), to: ExGAM.Domain.Projection.IndexRows
  defdelegate position(collection, key), to: ExGAM.Domain.Projection.IndexRows
end

defmodule Spectre.GAM.Domain.Projection.Store do
  @moduledoc false

  alias ExGAM.Domain.Projection.Store

  @callback open(String.t(), keyword()) :: {:ok, Store.handle()} | {:error, term()}
  @callback head(String.t(), keyword()) :: {:ok, Store.head()} | :not_found | {:error, term()}
  @callback commit(Store.handle(), Store.cursor(), Store.cursor(), Enumerable.t(), keyword()) ::
              :ok | {:error, term()}
  @callback fetch(Store.handle(), Store.cursor(), [Store.key()], keyword()) ::
              {:ok, %{optional(Store.key()) => binary()}} | {:error, term()}
  @callback page(Store.handle(), Store.cursor(), atom(), keyword()) :: Store.page()
  @callback select(Store.handle(), Store.cursor(), atom(), keyword(), keyword()) :: Store.page()

  defdelegate head(config, domain), to: Store
  defdelegate fetch(config, handle, cursor, keys), to: Store
  defdelegate page(config, handle, cursor, collection, opts \\ []), to: Store
end
