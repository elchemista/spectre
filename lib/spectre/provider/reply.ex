defmodule Spectre.Provider.Reply do
  @moduledoc false

  alias Spectre.Provider.Failure

  @numeric_fields [:confidence, :score, :margin]
  @boolean_fields [:accepted?, :terminal?]

  @doc false
  @spec route(atom(), term(), keyword()) :: {:ok, map()} | {:error, Failure.t()}
  def route(provider, reply, opts \\ [])

  def route(provider, reply, opts)
      when is_atom(provider) and is_map(reply) and is_list(opts) do
    with :ok <- validate_accepted(provider, reply),
         :ok <- validate_label(provider, reply, Keyword.get(opts, :label, :required)),
         :ok <- validate_fields(provider, reply, @numeric_fields, &valid_number?/1),
         :ok <- validate_fields(provider, reply, @boolean_fields, &is_boolean/1),
         :ok <- validate_optional(provider, reply, :strategy, &valid_identifier?/1),
         :ok <- validate_optional(provider, reply, :metadata, &is_map/1),
         :ok <- validate_scores(provider, reply) do
      {:ok, reply}
    end
  end

  def route(provider, reply, _opts) when is_atom(provider) do
    {:error, Failure.invalid_reply(provider, reply)}
  end

  @spec validate_accepted(atom(), map()) :: :ok | {:error, Failure.t()}
  defp validate_accepted(provider, reply) do
    case Map.fetch(reply, :accepted?) do
      {:ok, accepted?} when is_boolean(accepted?) -> :ok
      {:ok, value} -> invalid_field(provider, :accepted?, value)
      :error -> {:error, Failure.missing_reply_field(provider, :accepted?)}
    end
  end

  @spec validate_label(atom(), map(), :required | :accepted) ::
          :ok | {:error, Failure.t()}
  defp validate_label(provider, reply, requirement) do
    validate_label_value(provider, raw_label(reply), requirement, Map.get(reply, :accepted?))
  end

  @spec validate_label_value(atom(), term(), :required | :accepted, term()) ::
          :ok | {:error, Failure.t()}
  defp validate_label_value(_provider, label, _requirement, _accepted?)
       when is_atom(label) and label not in [nil, true, false],
       do: :ok

  defp validate_label_value(provider, label, _requirement, _accepted?)
       when is_binary(label) do
    if String.valid?(label) and String.trim(label) != "",
      do: :ok,
      else: invalid_field(provider, :label, label)
  end

  defp validate_label_value(_provider, nil, :accepted, false), do: :ok

  defp validate_label_value(provider, nil, _requirement, _accepted?),
    do: {:error, Failure.missing_reply_field(provider, :label)}

  defp validate_label_value(provider, label, _requirement, _accepted?),
    do: invalid_field(provider, :label, label)

  @spec raw_label(map()) :: term()
  defp raw_label(reply) do
    Map.get(reply, :label) || Map.get(reply, :intent) || Map.get(reply, "label") ||
      Map.get(reply, "intent")
  end

  @spec validate_fields(atom(), map(), [atom()], (term() -> boolean())) ::
          :ok | {:error, Failure.t()}
  defp validate_fields(provider, reply, fields, validator) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      case validate_optional(provider, reply, field, validator) do
        :ok -> {:cont, :ok}
        {:error, _failure} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_optional(atom(), map(), atom(), (term() -> boolean())) ::
          :ok | {:error, Failure.t()}
  defp validate_optional(provider, reply, field, validator) do
    case Map.fetch(reply, field) do
      :error -> :ok
      {:ok, nil} when field in @numeric_fields -> :ok
      {:ok, value} -> if validator.(value), do: :ok, else: invalid_field(provider, field, value)
    end
  end

  @spec validate_scores(atom(), map()) :: :ok | {:error, Failure.t()}
  defp validate_scores(provider, reply) do
    case Map.fetch(reply, :scores) do
      :error ->
        :ok

      {:ok, scores} when is_map(scores) ->
        validate_score_map(provider, scores)

      {:ok, scores} ->
        invalid_field(provider, :scores, scores)
    end
  end

  @spec validate_score_map(atom(), map()) :: :ok | {:error, Failure.t()}
  defp validate_score_map(provider, scores) do
    if Enum.all?(scores, &valid_score?/1),
      do: :ok,
      else: invalid_field(provider, :scores, scores)
  end

  @spec valid_score?({term(), term()}) :: boolean()
  defp valid_score?({label, score}), do: valid_label?(label) and valid_number?(score)

  @spec valid_number?(term()) :: boolean()
  defp valid_number?(value), do: is_integer(value) or is_float(value)

  @spec valid_label?(term()) :: boolean()
  defp valid_label?(label) when is_atom(label), do: valid_identifier?(label)

  defp valid_label?(label) when is_binary(label),
    do: String.valid?(label) and String.trim(label) != ""

  defp valid_label?(_label), do: false

  @spec valid_identifier?(term()) :: boolean()
  defp valid_identifier?(value), do: is_atom(value) and value not in [nil, true, false]

  @spec invalid_field(atom(), atom(), term()) :: {:error, Failure.t()}
  defp invalid_field(provider, field, value) do
    {:error, Failure.invalid_reply_field(provider, field, value)}
  end
end
