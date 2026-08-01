defmodule Spectre.Operation.Runtime.StartLoops do
  @moduledoc false

  alias Spectre.Operation.Definition
  alias Spectre.Operation.Loop
  alias Spectre.Run.Value

  @limit 32
  @option_keys [
    :intent_id,
    :id,
    :correlation_id,
    :expires_at,
    :budget,
    :cognitive,
    :metadata
  ]

  @spec normalize(Definition.t(), Loop.t(), term()) :: {:ok, [map()]} | {:error, term()}
  def normalize(_definition, _loop, []), do: {:ok, []}
  def normalize(_definition, _loop, nil), do: {:ok, []}

  def normalize(%Definition{} = definition, %Loop{} = loop, intents) when is_list(intents) do
    cond do
      length(intents) > @limit ->
        {:error, {:operation_start_loop_limit_exceeded, @limit}}

      :work not in definition.can_start ->
        {:error, {:operation_loop_start_not_authorized, loop.kind, :work}}

      true ->
        with {:ok, normalized} <- normalize_intents(intents, loop),
             :ok <- validate_unique(normalized) do
          {:ok, normalized}
        end
    end
  end

  def normalize(_definition, _loop, intents),
    do: {:error, {:invalid_operation_start_loops, intents}}

  defp normalize_intents(intents, loop) do
    intents
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {intent, index}, {:ok, acc} ->
      case normalize_intent(intent, loop, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_intent({:work, controller, input, opts}, loop, index)
       when is_atom(controller) and not is_nil(controller) and is_list(opts) do
    if Keyword.keyword?(opts) do
      normalize_keyword_intent(controller, input, opts, loop, index)
    else
      {:error, {:invalid_operation_start_loop_options, index}}
    end
  end

  defp normalize_intent(intent, _loop, index),
    do: {:error, {:invalid_operation_start_loop_intent, index, intent}}

  defp normalize_keyword_intent(controller, input, opts, loop, index) do
    option_keys = Keyword.keys(opts)
    unknown_options = option_keys -- @option_keys

    cond do
      Enum.uniq(option_keys) != option_keys ->
        {:error, {:duplicate_operation_start_loop_option, index}}

      unknown_options != [] ->
        {:error, {:unsupported_operation_start_loop_options, index, unknown_options}}

      true ->
        intent_id = Keyword.get(opts, :intent_id)

        with :ok <- validate_intent_id(intent_id, index),
             child_id <-
               Keyword.get(opts, :id, Value.token("operation-loop", {loop.id, intent_id})),
             correlation_id <-
               Keyword.get(
                 opts,
                 :correlation_id,
                 Value.token("operation-correlation", {loop.id, intent_id})
               ),
             :ok <- validate_identity(child_id, :id, index),
             :ok <- validate_identity(correlation_id, :correlation_id, index),
             normalized_opts <-
               opts
               |> Keyword.delete(:intent_id)
               |> Keyword.put(:id, child_id)
               |> Keyword.put(:correlation_id, correlation_id),
             intent <- %{
               intent_id: intent_id,
               kind: :work,
               controller: controller,
               input: input,
               opts: normalized_opts
             },
             :ok <- portable(intent, [:loop, loop.id, :start_loop, intent_id]) do
          {:ok, intent}
        end
    end
  end

  defp validate_intent_id(value, _index)
       when (is_atom(value) and not is_nil(value)) or (is_binary(value) and value != ""),
       do: :ok

  defp validate_intent_id(_value, index),
    do: {:error, {:operation_start_loop_intent_id_required, index}}

  defp validate_identity(value, _field, _index) when is_binary(value) and value != "", do: :ok

  defp validate_identity(_value, field, index),
    do: {:error, {:invalid_operation_start_loop_identity, index, field}}

  defp validate_unique(intents) do
    intent_ids = Enum.map(intents, & &1.intent_id)
    loop_ids = Enum.map(intents, &Keyword.fetch!(&1.opts, :id))

    cond do
      Enum.uniq(intent_ids) != intent_ids ->
        {:error, :duplicate_operation_start_loop_intent_id}

      Enum.uniq(loop_ids) != loop_ids ->
        {:error, :duplicate_operation_start_loop_id}

      true ->
        :ok
    end
  end

  defp portable(value, path) do
    case Value.validate(value, path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_operational_value, reason}}
    end
  end
end
