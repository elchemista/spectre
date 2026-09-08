defmodule Spectre.History do
  @moduledoc """
  Host-owned conversation persistence, separate from the GAM ledger.

  A backend applies count/byte limits before returning a window, inserts a
  stable message ref idempotently, and records delivery separately from a
  generated draft. Summary updates compare an expected revision. Erasure and
  retention act on this store, not on the Domain ledger or other host copies.

  Loading history does not authenticate its content or make it a system
  instruction. The host decides whether this operational persistence is outside
  its governed Surface. Protected agent reads/writes must use ordinary Acts.
  Pass relevant durable Evidence refs when opening a Turn; never use a chat
  window to discard authority facts, uncertainty or outstanding Duty.
  """

  alias Spectre.{Adapter, Portable}
  alias Spectre.Agent.Observer
  alias Spectre.Canonical.Value
  @enforce_keys [:module, :binding, :options]
  defstruct @enforce_keys
  @type t :: %__MODULE__{module: module(), binding: map(), options: keyword()}
  @type message :: %{
          ref: String.t(),
          revision: non_neg_integer(),
          role: :user | :assistant | :tool,
          status: :received | :draft | :delivered | :failed | :unclear,
          content: String.t(),
          evidence_refs: [String.t()]
        }

  @callback load(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback append(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback record_delivery(map(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback load_summary(map(), keyword()) :: {:ok, map()} | :not_found | {:error, term()}
  @callback save_summary(map(), map(), non_neg_integer(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback erase(map(), map(), keyword()) :: :ok | {:error, term()}
  @optional_callbacks load_summary: 2, save_summary: 4, erase: 3

  @doc "Binds a backend to one explicit tenant/conversation without starting resources."
  @spec bind({module(), keyword()}, map() | keyword()) :: {:ok, t()} | {:error, term()}
  def bind({module, opts}, binding) do
    with true <- Portable.keyword?(opts),
         {:ok, binding} <-
           Portable.normalize_attrs(binding, [:tenant_id, :conversation_id], :history_binding),
         true <- map_size(binding) == 2,
         :ok <- Portable.validate_ref(binding.tenant_id, :tenant_id),
         :ok <- Portable.validate_ref(binding.conversation_id, :conversation_id),
         :ok <- Adapter.validate(module, load: 3, append: 3, record_delivery: 3) do
      {:ok, %__MODULE__{module: module, binding: binding, options: opts}}
    else
      false -> {:error, :invalid_history_binding}
      {:error, _} = error -> error
    end
  end

  def bind(_adapter, _binding), do: {:error, :invalid_history_adapter}

  @doc "Returns the tenant/conversation identity without exposing backend options."
  @spec binding(t()) :: map()
  def binding(%__MODULE__{binding: binding}), do: binding

  @doc "Loads a backend-limited page; overflow is an error, not silent client-side truncation."
  @spec load(t(), keyword() | map()) :: {:ok, map()} | {:error, term()}
  def load(history, opts \\ []) do
    with {:ok, window} <- window(opts),
         {:ok, page} <- call(history, :load, [window]),
         {:ok, page} <-
           Portable.normalize_attrs(
             page,
             [:binding, :messages, :cursor, :truncated?],
             :history_page
           ),
         true <- Map.get(page, :binding) === history.binding,
         messages when is_list(messages) <- Map.get(page, :messages),
         true <- length(messages) <= window.keep,
         true <- is_boolean(page[:truncated?]),
         :ok <- Portable.validate_optional_ref(page[:cursor], :history_cursor),
         :ok <- Value.validate(messages, max_bytes: window.max_bytes),
         {:ok, messages} <- messages(messages) do
      {:ok, %{page | messages: messages}}
    else
      {:error, _} = error -> error
      _invalid -> {:error, :invalid_history_page}
    end
  end

  @doc "Appends one stable message identity; a backend must reject conflicting reuse of that ref."
  @spec append(t(), message() | keyword()) :: {:ok, message()} | {:error, term()}
  def append(history, value) do
    with {:ok, message} <- message(value),
         {:ok, saved} <- call(history, :append, [message]),
         {:ok, saved} <- message(saved),
         true <- saved === message do
      {:ok, saved}
    else
      false -> {:error, :history_append_receipt_mismatch}
      error -> error
    end
  end

  @doc """
  Records an idempotent delivery transition, distinct from appending a draft.

  The backend returns the updated message at expected_revision + 1, including
  the receipt's Evidence refs. Replaying the same receipt returns that same
  revision; conflicting reuse or a stale expected revision must fail in storage.
  """
  @spec record_delivery(t(), map() | keyword()) :: {:ok, message()} | {:error, term()}
  def record_delivery(history, value) do
    with {:ok, receipt} <-
           Portable.normalize_attrs(
             value,
             [:ref, :message_ref, :expected_revision, :status, :evidence_refs],
             :history_delivery
           ),
         :ok <- Portable.validate_ref(receipt[:ref], :delivery_ref),
         :ok <- Portable.validate_ref(receipt[:message_ref], :message_ref),
         true <- is_integer(receipt[:expected_revision]) and receipt.expected_revision >= 0,
         true <- receipt[:status] in [:delivered, :failed, :unclear],
         {:ok, refs} <- Portable.normalize_refs(receipt[:evidence_refs], :delivery_evidence_refs),
         true <- refs != [],
         {:ok, saved} <- call(history, :record_delivery, [%{receipt | evidence_refs: refs}]),
         {:ok, saved} <- message(saved),
         true <- saved.ref === receipt.message_ref and saved.status === receipt.status,
         true <- saved.revision === receipt.expected_revision + 1,
         true <- Enum.all?(refs, &(&1 in saved.evidence_refs)) do
      {:ok, saved}
    else
      false -> {:error, :invalid_history_delivery}
      error -> error
    end
  end

  @doc "Loads a summary only when the backend implements that optional capability."
  @spec load_summary(t()) :: {:ok, map()} | :not_found | {:error, term()}
  def load_summary(history) do
    with {:ok, %{binding: binding, summary: value}} <- call(history, :load_summary, []),
         true <- binding === history.binding do
      summary(value)
    else
      false -> {:error, :history_summary_binding_mismatch}
      {:ok, _invalid} -> {:error, :invalid_history_summary_reply}
      other -> other
    end
  end

  @doc "Stores an explicit summary at expected_revision + 1; never invokes a model."
  @spec save_summary(t(), map() | keyword(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def save_summary(history, value, expected_revision)
      when is_integer(expected_revision) and expected_revision >= 0 do
    with {:ok, summary} <- summary(value),
         true <- summary.revision === expected_revision + 1,
         {:ok, %{binding: binding, summary: saved}} <-
           call(history, :save_summary, [summary, expected_revision]),
         true <- binding === history.binding and saved === summary do
      {:ok, saved}
    else
      false -> {:error, :history_summary_receipt_mismatch}
      {:ok, _invalid} -> {:error, :invalid_history_summary_reply}
      error -> error
    end
  end

  def save_summary(_history, _summary, _revision), do: {:error, :invalid_summary_revision}

  @doc "Erases an explicit host-owned selection; it neither edits nor claims to erase the GAM ledger."
  @spec erase(t(), map()) :: :ok | {:error, term()}
  def erase(history, selector) when is_map(selector) and map_size(selector) > 0 do
    with :ok <- Portable.validate(selector), do: call(history, :erase, [selector])
  end

  def erase(_history, _selector), do: {:error, :explicit_history_erasure_selector_required}

  defp call(%__MODULE__{module: module, binding: binding, options: opts}, operation, args) do
    {observer, opts} = Keyword.pop(opts, :observer)
    args = [binding | args] ++ [opts]

    with :ok <- Adapter.validate(module, [{operation, length(args)}]),
         {:ok, reply} <-
           Observer.span_with(observer, :history, %{operation: operation}, fn ->
             Adapter.invoke(module, operation, args)
           end) do
      case reply do
        {:ok, _} -> reply
        {:error, _} -> reply
        :not_found when operation == :load_summary -> :not_found
        :ok when operation == :erase -> :ok
        _invalid -> {:error, {:invalid_history_reply, operation}}
      end
    end
  end

  defp call(_history, _operation, _args), do: {:error, :invalid_history_handle}

  defp window(opts) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(opts, [:keep, :max_bytes, :before], :history_window),
         keep = Map.get(attrs, :keep, 30),
         max_bytes = Map.get(attrs, :max_bytes, 24_000),
         true <- is_integer(keep) and keep in 1..1000,
         true <- is_integer(max_bytes) and max_bytes in 1..1_048_576,
         :ok <- Portable.validate_optional_ref(attrs[:before], :history_cursor) do
      {:ok, %{keep: keep, max_bytes: max_bytes, before: attrs[:before]}}
    else
      false -> {:error, :invalid_history_window}
      error -> error
    end
  end

  defp messages(values) do
    Enum.reduce_while(values, {:ok, [], MapSet.new()}, fn value, {:ok, found, refs} ->
      with {:ok, message} <- message(value), false <- MapSet.member?(refs, message.ref) do
        {:cont, {:ok, [message | found], MapSet.put(refs, message.ref)}}
      else
        _invalid -> {:halt, {:error, :invalid_history_messages}}
      end
    end)
    |> case do
      {:ok, found, _refs} -> {:ok, Enum.reverse(found)}
      error -> error
    end
  end

  defp message(value) do
    with {:ok, m} <-
           Portable.normalize_attrs(
             value,
             [:ref, :revision, :role, :status, :content, :evidence_refs],
             :history_message
           ),
         :ok <- Portable.validate_ref(m[:ref], :message_ref),
         true <- is_integer(m[:revision]) and m.revision >= 0,
         true <- m[:role] in [:user, :assistant, :tool],
         true <- m[:status] in [:received, :draft, :delivered, :failed, :unclear],
         true <- is_binary(m[:content]) and String.valid?(m.content),
         :ok <- Value.validate(m, max_bytes: 65_536),
         {:ok, refs} <- Portable.normalize_refs(m[:evidence_refs], :history_evidence_refs) do
      {:ok, %{m | evidence_refs: refs}}
    else
      false -> {:error, :invalid_history_message}
      error -> error
    end
  end

  defp summary(value) do
    with {:ok, value} <-
           Portable.normalize_attrs(
             value,
             [:ref, :revision, :content, :evidence_refs],
             :history_summary
           ),
         :ok <- Portable.validate_ref(value[:ref], :summary_ref),
         true <- is_integer(value[:revision]) and value.revision > 0,
         true <- is_binary(value[:content]) and String.valid?(value.content),
         {:ok, refs} <- Portable.normalize_refs(value[:evidence_refs], :summary_evidence_refs),
         :ok <- Value.validate(value, max_bytes: 65_536) do
      {:ok, %{value | evidence_refs: refs}}
    else
      false -> {:error, :invalid_history_summary}
      error -> error
    end
  end
end
