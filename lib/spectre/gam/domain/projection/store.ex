defmodule Spectre.GAM.Domain.Projection.Store do
  @moduledoc """
  Durable, disposable Domain read model beside the canonical ledger.

  A generation is rebuilt by a trusted Domain from verified ledger batches.
  `commit/5` atomically applies row changes and advances its exact predecessor
  cursor. Readers specify that cursor: stale pages are errors, never mixed
  revisions. A persisted projection is not authenticated by its head digest;
  cold recovery must rebuild it from the ledger before using it for authority.

  Keys are `{collection, identity}`. Writes receive typed values; adapters encode
  them through `Rows`. Reads return canonical bytes, not a serialized process or
  a full-state snapshot. No PID, timer,
  capability, execution secret or callback belongs here. Implementations must
  distinguish absence from storage failure and support indexed bounded reads.
  """

  alias Spectre.GAM.Adapter
  alias Spectre.GAM.Ledger

  @type config :: {module(), keyword()}
  @type cursor :: Ledger.cursor()
  @type key :: {atom(), term()}
  @type change :: {:put, key(), term()} | {:delete, key()}
  @type handle :: %{domain: String.t(), generation: String.t()}
  @type head :: %{handle: handle(), cursor: cursor()}
  @type page :: {:ok, [{key(), binary()}], term() | nil} | {:error, term()}

  @doc "Opens a fresh projection generation for a Domain and fences its earlier generation."
  @callback open(String.t(), keyword()) :: {:ok, handle()} | {:error, term()}

  @doc "Reads the active generation and its committed cursor, or returns `:not_found`."
  @callback head(String.t(), keyword()) :: {:ok, head()} | :not_found | {:error, term()}

  @doc "Applies all changes atomically at the expected generation and cursor, then advances the cursor."
  @callback commit(handle(), cursor(), cursor(), Enumerable.t(), keyword()) ::
              :ok | {:error, term()}

  @doc "Reads the canonical bytes of existing keys at one exact generation and cursor."
  @callback fetch(handle(), cursor(), [key()], keyword()) ::
              {:ok, %{optional(key()) => binary()}} | {:error, term()}

  @doc "Reads a count- and byte-bounded page of one collection at an exact cursor."
  @callback page(handle(), cursor(), atom(), keyword()) :: page()

  @doc "Reads an indexed selection using query options followed by the original adapter options."
  @callback select(handle(), cursor(), atom(), keyword(), keyword()) :: page()

  @doc false
  def normalize(nil), do: {:ok, nil}

  def normalize({module, opts} = config) when is_atom(module) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <-
           Adapter.validate(module, open: 2, head: 2, commit: 5, fetch: 4, page: 4, select: 5) do
      {:ok, config}
    else
      _ -> {:error, :invalid_domain_projection_store}
    end
  end

  def normalize(_), do: {:error, :invalid_domain_projection_store}

  @doc "Creates a fresh generation through the configured projection adapter."
  @spec open(config(), String.t()) :: {:ok, handle()} | {:error, term()}
  def open(config, domain), do: invoke(config, :open, [domain])

  @doc "Reads the projection head for a Domain through its configured adapter."
  @spec head(config(), String.t()) :: {:ok, head()} | :not_found | {:error, term()}
  def head(config, domain), do: invoke(config, :head, [domain])

  @doc "Commits row changes from the supplied predecessor cursor to the new cursor."
  @spec commit(config(), handle(), cursor(), cursor(), Enumerable.t()) :: :ok | {:error, term()}
  def commit(config, handle, before, after_cursor, changes),
    do: invoke(config, :commit, [handle, before, after_cursor, changes])

  @doc "Fetches selected rows as canonical bytes at the requested projection cursor."
  @spec fetch(config(), handle(), cursor(), [key()]) ::
          {:ok, %{optional(key()) => binary()}} | {:error, term()}
  def fetch(config, handle, cursor, keys), do: invoke(config, :fetch, [handle, cursor, keys])

  @doc """
  Pages over a collection using `:limit`, `:max_bytes` and an opaque `:after` cursor.

  `:group`, `:from`, `:through` and `:nearest` select indexed queries via the
  adapter's `c:select/5` callback. A `nil` cursor in the reply marks the last page.
  """
  @spec page(config(), handle(), cursor(), atom(), keyword()) :: page()
  def page(config, handle, cursor, collection, page_opts \\ [])

  def page({module, opts}, handle, cursor, collection, page_opts) when is_list(page_opts) do
    if Keyword.keyword?(page_opts) and
         Keyword.keys(page_opts) --
           [:limit, :max_bytes, :after, :group, :from, :through, :nearest] == [] do
      if Enum.any?([:group, :from, :through, :nearest], &Keyword.has_key?(page_opts, &1)),
        do: invoke({module, opts}, :select, [handle, cursor, collection, page_opts]),
        else:
          invoke({module, Keyword.merge(opts, page_opts)}, :page, [handle, cursor, collection])
    else
      {:error, :invalid_projection_page}
    end
  end

  def page(_, _, _, _, _), do: {:error, :invalid_projection_page}

  defp invoke({module, opts}, callback, args) do
    case Adapter.invoke(module, callback, args ++ [opts]) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
