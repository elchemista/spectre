defmodule Spectre.Inference.Response do
  @moduledoc """
  Normalized inference response with optional usage and provider metadata.
  """

  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Selection
  alias Spectre.Inference.Usage

  defstruct [
    :text,
    :selection,
    :latency_ms,
    :provider_request_id,
    usage: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          text: String.t(),
          selection:
            Spectre.Inference.Selection.t() | Spectre.Inference.FrozenSelection.t() | nil,
          usage: map(),
          latency_ms: non_neg_integer() | nil,
          provider_request_id: term(),
          metadata: map()
        }

  @spec new(t() | String.t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = response), do: validate!(response)
  def new(text) when is_binary(text), do: validate!(%__MODULE__{text: text})
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    response = struct(__MODULE__, Map.take(attrs, fields()))

    validate!(response)
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = response) do
    cond do
      not is_binary(response.text) or not String.valid?(response.text) ->
        {:error, :invalid_inference_response_text}

      not is_map(response.metadata) or is_struct(response.metadata) ->
        {:error, :invalid_inference_response_metadata}

      not is_nil(response.latency_ms) and
          (not is_integer(response.latency_ms) or response.latency_ms < 0) ->
        {:error, :invalid_inference_response_latency}

      true ->
        with :ok <- validate_usage(response.usage) do
          validate_selection(response.selection)
        end
    end
  end

  def validate(_response), do: {:error, :invalid_inference_response}

  defp validate!(response) do
    case validate(response) do
      :ok -> response
      {:error, reason} -> raise ArgumentError, "invalid inference response: #{inspect(reason)}"
    end
  end

  defp validate_selection(nil), do: :ok
  defp validate_selection(%FrozenSelection{} = selection), do: FrozenSelection.validate(selection)

  # Provider selections are accepted from legacy and current adapters; the
  # compatibility shape is deliberately kept in one validation clause.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp validate_selection(%Selection{} = selection) do
    cond do
      not is_binary(selection.request_id) or selection.request_id == "" ->
        {:error, :invalid_inference_response_selection}

      is_nil(selection.model) or not is_integer(selection.attempt) or selection.attempt < 1 ->
        {:error, :invalid_inference_response_selection}

      not is_list(selection.fallback_chain) or not is_map(selection.metadata) or
          is_struct(selection.metadata) ->
        {:error, :invalid_inference_response_selection}

      true ->
        :ok
    end
  end

  defp validate_selection(_selection), do: {:error, :invalid_inference_response_selection}

  defp validate_usage(usage) when is_map(usage) and not is_struct(usage) do
    _normalized = Usage.new(usage)
    :ok
  rescue
    ArgumentError -> {:error, :invalid_inference_response_usage}
  end

  defp validate_usage(_usage), do: {:error, :invalid_inference_response_usage}

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
