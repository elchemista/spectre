defmodule Spectre.Inference.UsageAccounting do
  @moduledoc false

  alias Spectre.Inference.BudgetSnapshot
  alias Spectre.Inference.Response
  alias Spectre.Inference.Usage

  @qualities [:provider, :estimated, :unavailable]

  @type quality :: :provider | :estimated | :unavailable

  @doc false
  @spec initialize(Usage.t(), quality(), BudgetSnapshot.t() | nil) :: {Usage.t(), quality()}
  def initialize(%Usage{} = usage, quality, snapshot) when quality in @qualities do
    {accounted, estimated?} = apply_estimation_policy(usage, snapshot)
    {accounted, resulting_quality(quality, nil, estimated?)}
  end

  @doc false
  @spec merge_stream(
          Usage.t(),
          [Usage.t() | map() | keyword()],
          BudgetSnapshot.t() | nil,
          quality(),
          quality() | nil,
          keyword()
        ) :: {Usage.t(), quality()}
  def merge_stream(current, updates, snapshot, current_quality, provider_quality, opts \\ [])
      when is_list(updates) and current_quality in @qualities and
             provider_quality in [nil, :provider, :estimated, :unavailable] do
    merged = Enum.reduce(updates, current, &Usage.merge(&2, &1))
    merged = put_output_bytes(merged, Keyword.get(opts, :output_bytes))
    {accounted, estimated?} = apply_estimation_policy(merged, snapshot)

    {accounted, resulting_quality(current_quality, provider_quality, estimated?)}
  end

  @doc false
  @spec complete_response_outcome(term(), BudgetSnapshot.t() | nil) :: {map(), quality()}
  def complete_response_outcome({:ok, %Response{} = response}, snapshot),
    do: complete_response(response, snapshot)

  def complete_response_outcome(_outcome, _snapshot), do: {%{}, :unavailable}

  @doc false
  @spec complete_response(Response.t(), BudgetSnapshot.t() | nil) :: {map(), quality()}
  def complete_response(%Response{} = response, snapshot) do
    normalized = Usage.new(response.usage)

    measured =
      normalized
      |> put_output_bytes(byte_size(response.text))
      |> put_duration(response.latency_ms)

    {accounted, estimated?} = apply_estimation_policy(measured, snapshot)

    quality =
      cond do
        estimated? -> :estimated
        provider_usage?(response.usage) -> :provider
        true -> :unavailable
      end

    {Usage.to_map(accounted), quality}
  end

  defp put_output_bytes(usage, nil), do: usage

  defp put_output_bytes(%Usage{} = usage, bytes) when is_integer(bytes) and bytes >= 0,
    do: %{usage | output_bytes: max(usage.output_bytes, bytes)}

  defp put_duration(usage, nil), do: usage

  defp put_duration(%Usage{} = usage, duration) when is_integer(duration) and duration >= 0,
    do: %{usage | duration_ms: max(usage.duration_ms, duration)}

  defp apply_estimation_policy(
         %Usage{} = usage,
         %BudgetSnapshot{estimation_policy: :conservative, reserved: reserved}
       ) do
    input_tokens = max(usage.input_tokens, reserved.input_tokens)
    output_tokens = max(usage.output_tokens, div(usage.output_bytes + 3, 4))
    estimated? = input_tokens != usage.input_tokens or output_tokens != usage.output_tokens

    accounted = %{
      usage
      | input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: max(usage.total_tokens, input_tokens + output_tokens)
    }

    {accounted, estimated?}
  end

  defp apply_estimation_policy(%Usage{} = usage, _snapshot), do: {usage, false}

  # Once an estimate has contributed to cumulative counters, a later provider
  # update cannot prove that the retained maximum is token-exact. Keep the
  # weaker label for the remainder of the logical attempt.
  defp resulting_quality(:estimated, _provider_quality, _estimated?), do: :estimated
  defp resulting_quality(_current_quality, _provider_quality, true), do: :estimated

  defp resulting_quality(_current_quality, quality, false) when quality in @qualities,
    do: quality

  defp resulting_quality(current_quality, nil, false), do: current_quality

  defp provider_usage?(usage) do
    known = ~w(input_tokens output_tokens total_tokens cost)a
    string_known = Enum.map(known, &Atom.to_string/1)
    Enum.any?(Map.keys(usage), &(&1 in known or &1 in string_known))
  end
end
