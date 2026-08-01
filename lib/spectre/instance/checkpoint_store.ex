defmodule Spectre.Instance.CheckpointStore do
  @moduledoc """
  Durable adapter boundary for the complete canonical Agent checkpoint.

  Stores should implement `compare_and_swap/5`. The expected revision is the
  last checkpoint acknowledged by the adapter and the new revision is embedded
  in the encoded checkpoint as well. An adapter that cannot determine whether
  a write committed must return `{:error, {:ambiguous, reason}}`; Spectre will
  not retry that write automatically.
  """

  alias Spectre.Instance.Ref

  @type config :: module() | {module(), keyword()} | false | nil

  @callback load(Ref.t(), keyword()) ::
              :not_found | {:ok, String.t() | map()} | {:error, term()}

  @callback compare_and_swap(
              Ref.t(),
              String.t(),
              non_neg_integer(),
              non_neg_integer(),
              keyword()
            ) :: :ok | {:ok, term()} | {:error, term()}

  @optional_callbacks load: 2, compare_and_swap: 5

  @spec normalize(config()) :: {:ok, nil | {module(), keyword()}} | {:error, term()}
  def normalize(value) when value in [nil, false], do: {:ok, nil}

  def normalize(module) when is_atom(module) and not is_nil(module),
    do: {:ok, {module, []}}

  def normalize({module, opts})
      when is_atom(module) and not is_nil(module) and is_list(opts),
      do: {:ok, {module, opts}}

  def normalize(value), do: {:error, {:invalid_checkpoint_store, value}}

  @spec load(nil | {module(), keyword()}, Ref.t(), keyword()) ::
          :not_found | {:ok, String.t() | map()} | {:error, term()}
  def load(nil, _ref, _opts), do: :not_found

  def load({module, store_opts}, %Ref{} = ref, opts) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:checkpoint_store_not_loaded, module}}

      not function_exported?(module, :load, 2) ->
        :not_found

      true ->
        module.load(ref, Keyword.merge(store_opts, opts))
        |> normalize_load(module)
    end
  rescue
    exception -> {:error, {:checkpoint_load_exception, module, exception.__struct__}}
  catch
    kind, reason -> {:error, {:checkpoint_load_failure, module, kind, reason}}
  end

  @spec persist(
          {module(), keyword()},
          Ref.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          keyword()
        ) :: :ok | {:error, term()}
  def persist({module, store_opts}, %Ref{} = ref, checkpoint, expected, revision, opts)
      when is_binary(checkpoint) and is_integer(expected) and expected >= 0 and
             is_integer(revision) and revision >= 0 do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:checkpoint_store_not_loaded, module}}

      not function_exported?(module, :compare_and_swap, 5) ->
        {:error, {:checkpoint_store_callback_missing, module, :compare_and_swap, 5}}

      true ->
        module.compare_and_swap(
          ref,
          checkpoint,
          expected,
          revision,
          Keyword.merge(store_opts, opts)
        )
        |> normalize_persist(module)
    end
  rescue
    exception ->
      {:error, {:ambiguous, {:checkpoint_persist_exception, module, exception.__struct__}}}
  catch
    kind, reason -> {:error, {:ambiguous, {:checkpoint_persist_failure, module, kind, reason}}}
  end

  defp normalize_load(:not_found, _module), do: :not_found

  defp normalize_load({:ok, value}, _module) when is_binary(value) or is_map(value),
    do: {:ok, value}

  defp normalize_load({:error, _reason} = error, _module), do: error

  defp normalize_load(value, module),
    do: {:error, {:invalid_checkpoint_load_reply, module, value}}

  defp normalize_persist(:ok, _module), do: :ok
  defp normalize_persist({:ok, _receipt}, _module), do: :ok
  defp normalize_persist({:error, _reason} = error, _module), do: error

  defp normalize_persist(value, module),
    do: {:error, {:ambiguous, {:invalid_checkpoint_persist_reply, module, value}}}
end
