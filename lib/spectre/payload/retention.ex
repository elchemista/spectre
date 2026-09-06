defmodule Spectre.Payload.Retention do
  @moduledoc """
  Host-controlled retention planning for external payloads, not ledger entries.

  `request/4` turns a retention threshold into request attributes accepted by
  `Spectre.request_erasure/4`. It does not delete bytes, append events, grant
  authority or claim that a payload has become irrelevant to governance.
  The normal erasure path derives the current causal impact, checks authority
  and records the Attempt/Outcome and any loss of verifiability.

  The application owns scheduling, indexed enumeration and usage metadata.
  Supply the last use of the *payload*, including all its consumers, not the
  observation time of an arbitrary Evidence referencing it. A shared payload
  must not age independently for each reference. A retention hold wins over
  both thresholds; do not use this planner as a substitute for host policy.

  Options are `:after_ms`, `:after_events` and `:reason`. At least one threshold
  is required. When both are supplied, both must elapse. Events count ledger
  revision distance, not the number of Evidence. Future usage is retained.

      case Spectre.Payload.Retention.request(ref, last_use, head,
             after_ms: 30 * 86_400_000, after_events: 10_000) do
        {:ok, request} -> Spectre.request_erasure(scope, request, executor_attrs)
        :retain -> :ok
        {:error, reason} -> {:error, reason}
      end

  `last_use` is `%{recorded_at: integer, revision: integer}` with optional
  `hold?: boolean`; `head` supplies the current trusted recording time and
  revision. These are planning inputs, not authority claims accepted by GAM.
  """

  alias Spectre.Portable

  @options [:after_ms, :after_events, :reason]
  @default_reason "External payload retention period elapsed"

  @type position :: %{recorded_at: non_neg_integer(), revision: non_neg_integer()}
  @type usage :: %{
          required(:recorded_at) => non_neg_integer(),
          required(:revision) => non_neg_integer(),
          optional(:hold?) => boolean()
        }

  @spec request(String.t(), usage(), position(), keyword()) ::
          :retain | {:ok, map()} | {:error, term()}
  def request(payload_ref, last_use, head, opts) do
    with :ok <- Portable.validate_content_ref(payload_ref, :payload, :payload_ref),
         :ok <- validate_position(last_use),
         :ok <- validate_position(head),
         :ok <- validate_options(opts) do
      plan(payload_ref, last_use, head, opts)
    end
  end

  defp plan(payload_ref, last_use, head, opts) do
    if Map.get(last_use, :hold?, false) or
         not elapsed?(head.recorded_at - last_use.recorded_at, opts[:after_ms]) or
         not elapsed?(head.revision - last_use.revision, opts[:after_events]) do
      :retain
    else
      {:ok,
       %{
         target_ref: payload_ref,
         requested_at: head.recorded_at,
         reason: Keyword.get(opts, :reason, @default_reason)
       }}
    end
  end

  defp elapsed?(distance, nil), do: distance >= 0
  defp elapsed?(distance, threshold), do: distance >= threshold

  defp validate_position(%{recorded_at: at, revision: revision} = position)
       when is_integer(at) and at >= 0 and is_integer(revision) and revision >= 0 do
    if is_boolean(Map.get(position, :hold?, false)),
      do: :ok,
      else: {:error, :invalid_payload_retention_position}
  end

  defp validate_position(_), do: {:error, :invalid_payload_retention_position}

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Keyword.keys(opts) -- @options == [] and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))) and
         valid_thresholds?(opts) and valid_reason?(Keyword.get(opts, :reason, @default_reason)),
       do: :ok,
       else: {:error, :invalid_payload_retention_options}
  end

  defp validate_options(_), do: {:error, :invalid_payload_retention_options}

  defp valid_thresholds?(opts) do
    thresholds = Keyword.take(opts, [:after_ms, :after_events])
    thresholds != [] and Enum.all?(thresholds, fn {_key, n} -> is_integer(n) and n >= 0 end)
  end

  defp valid_reason?(value), do: is_binary(value) and byte_size(value) > 0
end
