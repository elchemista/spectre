defmodule Spectre.Server.GAM.Managed.Recovery do
  @moduledoc false
  @behaviour ExGAM.Domain.Recovery.Policy
  alias ExGAM.Domain.Recovery.Policy

  @impl true
  def check(context, opts),
    do: Policy.check(opts[:policy], context.domain_ref, context.head, opts[:timeout])

  @impl true
  def failed(incident, opts) do
    Policy.failed(opts[:policy], incident, opts[:timeout])
    decision = Policy.recover(opts[:policy], incident, opts[:timeout])
    send(opts[:owner], {__MODULE__, opts[:token], decision})
  end

  def memory_options(opts) do
    domain = Keyword.get(opts, :domain, "managed") <> ":reset:" <> Spectre.Identity.uuid7()

    opts
    |> Keyword.put(:domain, domain)
    |> Keyword.put(:storage, :ephemeral)
    |> Keyword.put(:store, nil)
    |> Keyword.update(:options, [checkpoint: nil], &Keyword.put(&1, :checkpoint, nil))
  end
end
