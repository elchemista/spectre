defmodule Spectre.GAM do
  @moduledoc """
  Host-facing governance operations for an AgentServer.

  Use `ExGAM` to work directly with Domains and governed records.
  """

  alias ExGAM.Proposal.Result, as: ProposalResult

  @doc """
  Submits an operation from a trusted application process to an AgentServer.

  This uses the same operation catalog, `handle_action/2`, GAM admission,
  confirmation and result callbacks as `Spectre.Server.propose/4`. The caller
  must be the Server's configured consumer or one of its startup `:submitters`
  PIDs. Submission never constitutes user consent.

  Returns `{:ok, command_id}` after acquisition, not after execution. The result
  is delivered to `handle_result/3` under `:on_result` (default `:submission`).
  `:on_result`, `:confirmation` and an optional `:key` are accepted. A busy Server
  returns `{:error, :busy}` without acquiring an operation; callers may retry
  that rejected submission. An acquired operation must not be blindly retried.
  Mounted Skills receive work through their parent rather than this API.

  A `:key` is a nonempty string of at most 256 bytes. Retrying the same key and
  request returns the original command ID; changing the request returns a
  conflict. Keys are acquired atomically with the command checkpoint and are
  retained across recovery. Each Server retains up to 4096 keys and refuses new
  keyed submissions when full; it never evicts keys and silently reexecutes.
  The guarantee follows the configured storage lifetime, not external delivery.
  """
  @spec submit(GenServer.server(), atom() | binary() | tuple(), map(), keyword()) ::
          {:ok, binary()} | {:error, term()}
  def submit(server, operation, arguments, opts \\ []) do
    GenServer.call(server, {Spectre.Server.Runtime, :submit, operation, arguments, opts})
  end

  @doc """
  Revokes an AgentServer's application mandate through the existing GAM kernel.

  Only the root Server's configured consumer may request revocation. This is
  forward-only: existing Acts, Outcomes and Duties remain in the ledger. A
  restart does not restore the revoked authority.
  """
  @spec revoke(GenServer.server()) :: {:ok, ProposalResult.t()} | {:error, term()}
  def revoke(server), do: GenServer.call(server, {Spectre.Server.Runtime, :revoke})

  @doc """
  Proposes disposition of an AgentServer Duty through its independent reviewer.

  Only the process configured in `gam: [reviewer: [identity: ..., consumer: pid]]`
  may call this function. The normal agent consumer and external submitters do
  not gain reviewer authority. Spectre builds the proposal against the exact
  current Duty opening; the kernel checks its authority, supporting records and
  independence before recording any disposition.

  `:supporting_refs` must name nonempty existing Evidence, Outcome or Act refs.
  `:meter_resolution` defaults to `:none`. Disposition retains the original
  cause and history; it does not turn an uncertain effect into a successful one.
  """
  @spec resolve_duty(GenServer.server(), binary(), ExGAM.Duty.Disposition.kind(), keyword()) ::
          {:ok, ProposalResult.t()} | {:error, term()}
  def resolve_duty(server, duty_ref, kind, opts \\ []) do
    GenServer.call(server, {Spectre.Server.Runtime, :resolve_duty, duty_ref, kind, opts})
  end
end
