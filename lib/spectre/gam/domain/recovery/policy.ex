defmodule Spectre.GAM.Domain.Recovery.Policy do
  @moduledoc """
  Optional host checks and incident handling around verified Domain recovery.

  Configure `recovery_policy: {MyPolicy, options}` when starting a Domain.
  `check/2` receives only its identity and the recovered head, after canonical,
  semantic, Genesis and payload checks. A nil head means no ledger was found:
  the host can reject bootstrap of a Domain which must already exist.

  The host may compare this information against an independently retained
  witness. A hash chain alone cannot detect a coherently rewritten history or
  rollback. Checking an older witness against a newer head requires verifying
  their relationship; merely comparing revision numbers is not sufficient.
  This callback does not make the host or database tamper-proof.

  Optional `failed/2` receives startup failures and fatal runtime incidents.
  Enqueue application-owned quarantine, backup recovery or operator review
  there. Its result cannot authorize work, replace a projection or suppress the
  original error. After repair, restart the Domain and run verification again.
  Never blindly retry an external effect whose Outcome remains ambiguous.

  Callbacks run in isolated, monitored processes with `recovery_timeout`
  (default 5 seconds). Do not perform a long repair in the callback: arrange it
  in the application's supervision tree. Notifications are best effort, may be
  repeated on restart, and are not a durable incident log. Callback failure or
  timeout cannot turn a failed verification into success.

  This is a recovery boundary, not continuous storage monitoring. A running
  Domain uses its verified prefix and checks new suffixes; it does not reread
  all historical bytes before every decision. Independent audits and external
  witness publication remain host responsibilities.
  """

  alias Spectre.GAM.Adapter

  @type config :: {module(), keyword()} | nil
  @type head :: %{revision: non_neg_integer(), head_digest: String.t()}
  @type context :: %{domain_ref: String.t(), head: head() | nil}
  @type incident :: %{
          domain_ref: String.t(),
          phase: :startup | :runtime,
          reason: term(),
          last_verified: head() | nil
        }

  @callback check(context(), keyword()) :: :ok | {:error, term()}
  @callback failed(incident(), keyword()) :: term()
  @optional_callbacks failed: 2

  @doc false
  @spec normalize(term()) :: {:ok, config()} | {:error, term()}
  def normalize(nil), do: {:ok, nil}
  def normalize(module) when is_atom(module), do: normalize({module, []})

  def normalize({module, opts}) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- Adapter.validate(module, check: 2) do
      {:ok, {module, opts}}
    else
      false -> {:error, :invalid_recovery_policy_options}
      {:error, _} = error -> error
    end
  end

  def normalize(_config), do: {:error, :invalid_recovery_policy}

  @doc false
  @spec check(config(), String.t(), head() | nil, pos_integer()) :: :ok | {:error, term()}
  def check(nil, _domain, _head, _timeout), do: :ok

  def check(policy, domain, head, timeout) do
    case invoke(policy, :check, %{domain_ref: domain, head: head}, timeout) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, {:recovery_policy_rejected, reason}}
      {:ok, _invalid} -> {:error, :invalid_recovery_policy_result}
      {:error, reason} -> {:error, {:recovery_policy_failed, reason}}
    end
  end

  @doc false
  @spec failed(config(), incident(), pos_integer()) :: :ok
  def failed(nil, _incident, _timeout), do: :ok

  def failed({module, _opts} = policy, incident, timeout) do
    if function_exported?(module, :failed, 2), do: invoke(policy, :failed, incident, timeout)
    :ok
  end

  @doc "Dispatches a bounded incident notification without delaying a failing Domain."
  @spec notify_failed(config(), incident(), pos_integer()) :: :ok
  def notify_failed(nil, _incident, _timeout), do: :ok

  def notify_failed(policy, incident, timeout) do
    # The short-lived guardian owns the callback monitor and timeout. It is
    # intentionally not linked to the Domain that is about to stop; only this
    # small incident crosses the process boundary, never the projection.
    spawn(fn -> failed(policy, incident, timeout) end)
    :ok
  end

  defp invoke({module, opts}, callback, context, timeout) do
    {pid, monitor} =
      spawn_monitor(fn ->
        result = Adapter.invoke(module, callback, [context, opts])
        # A notification's return value is never state or a recovery decision.
        result = if callback == :failed, do: {:ok, :ok}, else: result
        exit({:recovery_policy_result, result})
      end)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:recovery_policy_result, result}} -> result
      {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, :callback_stopped}
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> {:error, :callback_timeout}
        end
    end
  end
end
