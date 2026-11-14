defmodule Spectre.Skill do
  @moduledoc """
  Reusable scoped routes with an optional supervised Server runtime.

  Bind `server: MyApp.BillingServer` to execute callbacks in a dedicated
  `Spectre.Server.Runtime`, sharing the mounting Agent's Stack and GAM Domain.
  The Server uses ordinary `Spectre.Server` callbacks, including native OTP
  callbacks. The Agent's `skill` mount limits governed operations explicitly.

  The root automatically passes its existing GAM connection to the child; a
  separate Skill process creates no additional Domain, ledger or authority.
  Assigns, workers, streams, pending intentions and checkpoints stay local.
  Concurrent proposals retain their mount provenance in the shared ledger;
  consent is bound to the originating mount and exact presentation. Lifecycle
  timers use the same recorded ingress and cannot erase unresolved Duties.

      use Spectre.Skill, id: :billing, server: MyApp.BillingServer

      flow :billing do
        on :refund, regex: ~r/^refund$/i, protected: true
      end

  Mounts without a Server retain declarative scoped routing to the Agent Server.
  See the Skills guide for consent, parallelism, ingress attribution and recovery.
  """

  @doc """
  Initializes a Skill definition using the shared Spectre DSL compiler.
  """
  defmacro __using__(opts) when is_list(opts) do
    opts = Keyword.put(opts, :__spectre_kind__, :skill)

    quote do
      use Spectre.Agent, unquote(opts)
    end
  end
end
