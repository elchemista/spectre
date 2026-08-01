defmodule Spectre.Router.SemanticCache.Learned.Online do
  @moduledoc """
  ETS-backed store for online learned semantic-cache examples.

  Owns the public named tables holding mutable online rows and their per-agent
  monotonic revisions. Table names are part of the operational contract: this
  module's own name is the online table and `Learned.Revisions` holds the
  counters, both created through the supervised semantic-cache owner.
  """

  import Spectre.Router.SemanticCache.Learned.Rows

  alias Spectre.Router.SemanticCache.Learned
  alias Spectre.Router.SemanticCache.Owner

  @online_table __MODULE__
  @revision_table Spectre.Router.SemanticCache.Learned.Revisions

  @doc "Stores or replaces one online row under its agent and id."
  @spec put_row(Learned.row()) :: :ok
  def put_row(%{agent: agent, id: id} = row) do
    :ets.insert(online_table(), {{agent, id}, row})
    :ok
  end

  @doc "Deletes one online row."
  @spec delete_row(module(), String.t()) :: :ok
  def delete_row(agent, id) do
    :ets.delete(online_table(), {agent, id})
    :ok
  end

  @doc "Fetches one online row, or nil."
  @spec fetch(module(), String.t()) :: Learned.row() | nil
  def fetch(agent, id) do
    case :ets.lookup(online_table(), {agent, id}) do
      [{{^agent, ^id}, row}] -> row
      [] -> nil
    end
  end

  @doc "Returns the agent's online rows visible under the cacheable rules."
  @spec rows(module(), keyword()) :: [Learned.row()]
  def rows(agent, opts) do
    labels = opts |> cacheable_rules() |> Map.new(&{&1.label, true})

    online_table()
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{^agent, _id}, %{label: label} = row} ->
        if Map.has_key?(labels, label) and usable_row?(row, opts), do: [row], else: []

      _other ->
        []
    end)
  end

  @doc "Finds the agent's online row with the given normalized text, or nil."
  @spec find_by_normalized(module(), String.t()) :: Learned.row() | nil
  def find_by_normalized(agent, normalized) do
    online_table()
    |> :ets.tab2list()
    |> Enum.find_value(fn
      {{^agent, _id}, %{normalized_text: ^normalized} = row} -> row
      _other -> nil
    end)
  end

  @doc "Fetches an editable online row, distinguishing read-only and missing ids."
  @spec mutable_row(module(), String.t(), keyword()) ::
          {:ok, Learned.row()} | {:error, term()}
  def mutable_row(agent, id, opts) do
    case fetch(agent, id) do
      %{editable?: true} = row ->
        if cacheable_label?(row.label, opts),
          do: {:ok, row},
          else: {:error, {:unknown_label, row.label}}

      %{} ->
        {:error, :read_only_example}

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Deletes every online row of one agent."
  @spec clear_rows(module()) :: :ok
  def clear_rows(agent) do
    online_table()
    |> :ets.tab2list()
    |> Enum.each(fn
      {{^agent, id}, _row} -> :ets.delete(@online_table, {agent, id})
      _other -> :ok
    end)

    :ok
  end

  @doc "Returns the monotonic in-memory revision of an agent's online examples."
  @spec revision(module()) :: non_neg_integer()
  def revision(agent) do
    case :ets.lookup(revision_table(), agent) do
      [{^agent, revision}] -> revision
      [] -> 0
    end
  end

  @doc "Advances the agent's online revision counter."
  @spec bump_revision(module()) :: non_neg_integer()
  def bump_revision(agent) do
    :ets.update_counter(revision_table(), agent, {2, 1}, {agent, 0})
  end

  defp online_table do
    ensure_table(@online_table, [
      :named_table,
      :public,
      :set,
      :compressed,
      read_concurrency: true
    ])
  end

  defp revision_table do
    ensure_table(@revision_table, [:named_table, :public, :set, write_concurrency: true])
  end

  defp ensure_table(name, options) do
    case Owner.ensure_table(name, options) do
      {:ok, ^name} -> name
      {:error, reason} -> raise "semantic cache table unavailable: #{inspect(reason)}"
    end
  end

  defp usable_row?(row, opts) do
    row.verified? or Keyword.get(opts, :semantic_cache_include_unverified?, false)
  end
end
