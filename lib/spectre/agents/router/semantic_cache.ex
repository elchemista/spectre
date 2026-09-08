defmodule Spectre.Router.SemanticCache do
  @moduledoc """
  Reviewable routing memory behind a replaceable backend.

  Bind an explicitly supervised backend to a namespace, Definition, flow and
  encoder profile with bind/2. Every lookup and mutation carries that binding;
  restarting a server with another configuration cannot silently redirect it.

  Only lookup/3 and info/1 are mandatory backend callbacks. Review and snapshot
  capabilities are optional and checked before use. This module validates
  nominations before the Router sees them. A cache hit is not GAM Evidence,
  consent or authority: the selected request still crosses the kernel.

  Lookup never computes an embedding or loads a model. An exact miss may return
  :embedding_required; the host prepares a vector outside routing, using a
  governed Act when that preparation calls an external service.
  """

  import Kernel, except: [binding: 1]
  alias Spectre.{Adapter, Portable}
  alias Spectre.Router.SemanticCache.{Configuration, Example}

  @enforce_keys [:adapter, :options, :binding]
  defstruct @enforce_keys
  @opaque t :: %__MODULE__{adapter: module(), options: keyword(), binding: map()}

  @type binding :: %{
          namespace: String.t(),
          definition_ref: String.t(),
          flow: String.t(),
          profile_ref: String.t() | nil
        }
  @type query :: %{
          text: String.t(),
          vector: [float()] | nil,
          profile_ref: String.t() | nil,
          labels: [String.t()],
          limit: pos_integer()
        }
  @type nomination :: %{
          label: String.t(),
          score: number(),
          example_ref: String.t(),
          example_revision: pos_integer(),
          content_ref: String.t(),
          binding: binding()
        }

  @callback info(keyword()) :: {:ok, map()} | {:error, term()}
  @callback lookup(binding(), query(), keyword()) ::
              {:ok, [nomination()]} | :miss | {:error, term()}
  @callback put(binding(), map(), keyword()) :: {:ok, Example.t() | map()} | {:error, term()}
  @callback examples(binding(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback update(binding(), String.t(), map(), pos_integer(), keyword()) ::
              {:ok, Example.t() | map()} | {:error, term()}
  @callback verify(binding(), String.t(), pos_integer(), keyword()) ::
              {:ok, Example.t() | map()} | {:error, term()}
  @callback delete(binding(), String.t(), pos_integer(), keyword()) :: :ok | {:error, term()}
  @callback snapshot(binding(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback restore(binding(), map(), keyword()) :: :ok | {:error, term()}
  @optional_callbacks put: 3,
                      examples: 3,
                      update: 5,
                      verify: 4,
                      delete: 4,
                      snapshot: 2,
                      restore: 3

  @doc "Validates an address and binding against the backend; never starts a process."
  @spec bind({module(), keyword()}, map() | keyword()) :: {:ok, t()} | {:error, term()}
  def bind({module, options}, binding) do
    with true <- Portable.keyword?(options),
         false <- Keyword.has_key?(options, :embed),
         :ok <- Adapter.validate(module, lookup: 3, info: 1),
         {:ok, binding} <- Configuration.binding(binding),
         {:ok, %{binding: reported} = info} <-
           invoke(module, :info, [Keyword.put(options, :binding, binding)]),
         {:ok, reported} <- Configuration.binding(reported),
         true <- binding === reported,
         :ok <- configured_limits(info, options) do
      {:ok, %__MODULE__{adapter: module, options: options, binding: binding}}
    else
      false -> {:error, :cache_binding_mismatch}
      true -> {:error, :cache_embedding_callback_not_supported}
      {:ok, _invalid} -> {:error, :invalid_cache_info}
      {:error, _} = error -> error
    end
  end

  def bind(_adapter, _binding), do: {:error, :invalid_cache_adapter}

  defp configured_limits(info, options) do
    if Enum.all?([:max_entries, :max_text_bytes, :dimensions], fn key ->
         not Keyword.has_key?(options, key) or Map.get(info, key) === options[key]
       end), do: :ok, else: {:error, :cache_configuration_mismatch}
  end

  @doc "Checks optional capabilities at wiring, without executing the callbacks."
  @spec capabilities(t(), :lookup | :review | :studio | :snapshot) :: :ok | {:error, term()}
  def capabilities(%__MODULE__{adapter: module}, feature) do
    case feature do
      :lookup -> Adapter.validate(module, lookup: 3, info: 1)
      :review -> Adapter.validate(module, put: 3, verify: 4)
      :studio -> Adapter.validate(module, examples: 3, update: 5, verify: 4, delete: 4)
      :snapshot -> Adapter.validate(module, snapshot: 2, restore: 3)
      _invalid -> {:error, :unknown_cache_capability}
    end
  end

  def capabilities(_cache, _feature), do: {:error, :invalid_cache_handle}

  @doc "Returns the small immutable binding, without reading examples."
  @spec binding(t()) :: binding()
  def binding(%__MODULE__{binding: binding}), do: binding

  @doc "Reads backend metadata without copying its examples."
  @spec info(t()) :: {:ok, map()} | {:error, term()}
  def info(%__MODULE__{adapter: module, options: opts, binding: binding}),
    do: invoke(module, :info, [Keyword.put(opts, :binding, binding)])

  def info(_cache), do: {:error, :invalid_cache_handle}

  @doc "Looks up only allowed labels and verifies all returned nominations before routing."
  @spec lookup(t(), map() | keyword()) :: {:ok, [nomination()]} | :miss | {:error, term()}
  def lookup(%__MODULE__{} = cache, value) do
    with {:ok, query} <- Configuration.query(value),
         :ok <-
           Spectre.Router.SemanticCache.Example.profile(
             query.vector,
             query.profile_ref,
             cache.binding.profile_ref
           ),
         {:ok, hits} <- call(cache, :lookup, [query]) do
      nominations(hits, query, cache.binding)
    end
  end

  def lookup(_cache, _query), do: {:error, :invalid_cache_handle}

  @doc "Adds an example in quarantine; this never approves it or generates its vector."
  @spec put(t(), map()) :: {:ok, Example.t()} | {:error, term()}
  def put(cache, example) do
    with {:ok, reply} <- call(cache, :put, [example]),
         do: example_reply(reply, nil, 0, false)
  end

  @doc "Lists a bounded page. The backend applies filters before the page limit."
  def examples(cache, opts \\ []) do
    with {:ok, page} <- Configuration.page(opts),
         {:ok, %{examples: examples, next: cursor}} <- call(cache, :examples, [opts]),
         true <- is_list(examples) and length(examples) <= page.limit,
         true <- is_nil(cursor) or (is_binary(cursor) and byte_size(cursor) in 1..256),
         {:ok, examples} <- page_examples(examples, page) do
      {:ok, %{examples: examples, next: cursor}}
    else
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_cache_page_reply}
    end
  end

  @doc "Edits one exact revision and withdraws its prior approval."
  def update(cache, id, changes, expected_revision) do
    with {:ok, reply} <-
           reviewed_call(cache, :update, id, expected_revision, [id, changes, expected_revision]),
         do: example_reply(reply, id, expected_revision, false)
  end

  @doc "Approves the revision inspected by the host's authorized reviewer."
  def verify(cache, id, expected_revision) do
    with {:ok, reply} <-
           reviewed_call(cache, :verify, id, expected_revision, [id, expected_revision]),
         do: example_reply(reply, id, expected_revision, true)
  end

  @doc "Deletes one exact revision. Host snapshots remain a separate retention responsibility."
  def delete(cache, id, expected_revision),
    do: reviewed_call(cache, :delete, id, expected_revision, [id, expected_revision])

  @doc "Exports revisioned examples and their binding without embedding or promoting anything."
  def snapshot(cache), do: call(cache, :snapshot, [])

  @doc "Restores a matching snapshot; the backend must reject a non-fresh destination."
  def restore(cache, snapshot), do: call(cache, :restore, [snapshot])

  defp reviewed_call(cache, operation, id, revision, args) do
    with :ok <- Portable.validate_ref(id, :example_ref),
         true <- is_integer(revision) and revision > 0 do
      call(cache, operation, args)
    else
      false -> {:error, :invalid_cache_revision}
      {:error, _} = error -> error
    end
  end

  defp example_reply(value, id, previous_revision, verified) do
    with {:ok, example} <- Example.from_backend(value),
         true <- is_nil(id) or example.id === id,
         true <- example.revision > previous_revision and example.verified === verified do
      {:ok, example}
    else
      _invalid -> {:error, :invalid_cache_mutation_reply}
    end
  end

  defp page_examples(values, page) do
    Enum.reduce_while(values, {:ok, [], MapSet.new()}, fn value, {:ok, found, seen} ->
      with {:ok, example} <- Example.from_backend(value),
           false <- MapSet.member?(seen, example.id),
           true <- is_nil(page.verified) or example.verified === page.verified do
        {:cont, {:ok, [example | found], MapSet.put(seen, example.id)}}
      else
        _invalid -> {:halt, {:error, :invalid_cache_page_reply}}
      end
    end)
    |> case do
      {:ok, found, _seen} -> {:ok, Enum.reverse(found)}
      error -> error
    end
  end

  defp call(%__MODULE__{adapter: module, options: opts, binding: binding}, operation, args),
    do: invoke(module, operation, [binding | args] ++ [opts])

  defp call(_cache, _operation, _args), do: {:error, :invalid_cache_handle}

  defp invoke(module, operation, args) do
    with :ok <- Adapter.validate(module, [{operation, length(args)}]),
         {:ok, reply} <- Adapter.invoke(module, operation, args) do
      case {operation, reply} do
        {:lookup, :miss} -> :miss
        {operation, :ok} when operation in [:delete, :restore] -> :ok
        {_operation, {:ok, _}} -> reply
        {_operation, {:error, _}} -> reply
        _invalid -> {:error, {:invalid_cache_backend_reply, operation}}
      end
    end
  end

  defp nominations(hits, query, binding) when is_list(hits) and length(hits) <= query.limit do
    hits
    |> Enum.reduce_while({:ok, [], %{}}, fn hit, {:ok, found, seen} ->
      with {:ok, hit} <- nomination(hit, query.labels, binding),
           false <- Map.has_key?(seen, hit.label) do
        {:cont, {:ok, [hit | found], Map.put(seen, hit.label, true)}}
      else
        _invalid -> {:halt, {:error, :invalid_cache_nomination}}
      end
    end)
    |> case do
      {:ok, found, _seen} -> {:ok, Enum.reverse(found)}
      error -> error
    end
  end

  defp nominations(_hits, _query, _binding), do: {:error, :invalid_cache_nominations}

  defp nomination(value, labels, binding) do
    fields = [:label, :score, :example_ref, :example_revision, :content_ref, :binding]

    with {:ok, hit} <- Portable.normalize_attrs(value, fields, :cache_nomination),
         true <- map_size(hit) == length(fields) and hit.label in labels,
         true <- is_number(hit.score) and hit.score >= 0 and hit.score <= 1,
         true <- is_integer(hit.example_revision) and hit.example_revision > 0,
         :ok <- Portable.validate_ref(hit.example_ref, :example_ref),
         :ok <- Portable.validate_ref(hit.content_ref, :content_ref),
         {:ok, reported} <- Configuration.binding(hit.binding),
         true <- reported === binding do
      {:ok, %{hit | binding: reported}}
    else
      _invalid -> {:error, :invalid_cache_nomination}
    end
  end
end
