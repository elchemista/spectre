defmodule Spectre.Journal.Store do
  @moduledoc """
  Storage boundary for structured Spectre journal records.

  A runtime store only needs to append records. Querying, retention, indexing,
  and transactional outboxes remain application concerns. Adapters used by
  configured Instance erasure additionally expose the optional, idempotent
  `erase_instance/2` callback.
  """

  alias Spectre.Instance.Ref

  @type config :: module() | {module(), keyword()} | keyword() | false | nil
  @type normalized :: nil | {module(), keyword()}

  @callback append(Spectre.Journal.Record.t(), keyword()) ::
              :ok | {:ok, term()} | {:error, term()}

  @callback erase_instance(Ref.t(), keyword()) ::
              {:ok, :erased | :already_erased} | {:error, term()}

  @optional_callbacks erase_instance: 2

  @doc "Normalizes the journal configurations accepted by the runtime."
  @spec normalize(config()) :: {:ok, normalized()} | {:error, term()}
  def normalize(value) when value in [nil, false], do: {:ok, nil}
  def normalize(module) when is_atom(module) and not is_boolean(module), do: {:ok, {module, []}}

  def normalize({module, opts})
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, {module, opts}},
      else: {:error, {:invalid_journal_store, :options}}
  end

  def normalize(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.pop(opts, :store) do
        {module, store_opts}
        when is_atom(module) and not is_nil(module) and not is_boolean(module) ->
          {:ok, {module, store_opts}}

        _invalid ->
          {:error, :invalid_journal_store}
      end
    else
      {:error, {:invalid_journal_store, :options}}
    end
  end

  def normalize(_value), do: {:error, :invalid_journal_store}

  @doc "Checks whether a configured journal supports idempotent Instance erasure."
  @spec erasure_capability(normalized()) :: :ok | {:error, term()}
  def erasure_capability(nil), do: :ok

  def erasure_capability({module, _opts}) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:journal_store_not_loaded, module}}

      not function_exported?(module, :erase_instance, 2) ->
        {:error, {:journal_store_erasure_unsupported, module}}

      true ->
        :ok
    end
  end

  @doc "Erases all journal records bound to one exact Instance Ref."
  @spec erase_instance(normalized(), Ref.t(), keyword()) ::
          {:ok, :erased | :already_erased | :not_configured} | {:error, term()}
  def erase_instance(nil, %Ref{}, _opts), do: {:ok, :not_configured}

  def erase_instance({module, store_opts} = store, %Ref{} = ref, opts) do
    with :ok <- erasure_capability(store) do
      module.erase_instance(ref, Keyword.merge(store_opts, opts))
      |> normalize_erasure(module)
    end
  rescue
    exception ->
      {:error, {:ambiguous, {:journal_erasure_exception, module, exception.__struct__}}}
  catch
    kind, reason ->
      {:error, {:ambiguous, {:journal_erasure_failure, module, kind, reason}}}
  end

  defp normalize_erasure({:ok, outcome}, _module)
       when outcome in [:erased, :already_erased],
       do: {:ok, outcome}

  defp normalize_erasure({:error, _reason} = error, _module), do: error

  defp normalize_erasure(_reply, module),
    do: {:error, {:ambiguous, {:invalid_journal_erasure_reply, module}}}
end
