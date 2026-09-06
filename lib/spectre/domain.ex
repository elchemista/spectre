defmodule Spectre.Domain do
  @moduledoc """
  Runtime handle for one governed Domain.

  The handle is deliberately not a durable record. Authority lives in the
  Domain ledger; the pid merely serializes commands against that ledger. Each
  running Domain is wired to one validated `Spectre.Ingress` adapter, whose
  stable reference fences every authenticated submission context.

  Public workflows enter through `Spectre`; `Domain.Sequencer` is the ordered
  mailbox, and the modules below `Domain.Command` own the individual I/O
  workflows. Governed semantics do not live in this handle or in callbacks:
  they are evaluated by `Spectre.Kernel` and replayed by
  `Spectre.GovernedAct.Fold`.

  For a static application topology, put `{Spectre.Domain, opts}` after its
  store in the host supervisor. `opts` includes `:domain_ref`, `:store` and the
  same foundation/boundary options accepted by `Spectre.start_domain/3`.
  `:rest_for_one` restarts the Domain after an earlier store child fails; the
  store's own durability determines what survives. Resolve the registered
  handle with `Spectre.lookup_domain/1` after startup. The default Registry is
  provided by the Spectre application.

  Use `Spectre.start_domain/3` for dynamically provisioned Domains under
  Spectre's supervisor instead. Do not start the same Domain in both trees.
  Neither form authenticates a Scope or creates an Instance automatically.
  """

  alias Spectre.Domain.Sequencer

  @enforce_keys [:ref, :server]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{ref: String.t(), server: GenServer.server()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         domain_ref when is_binary(domain_ref) and domain_ref != "" <-
           Keyword.get(opts, :domain_ref),
         registry when is_atom(registry) and not is_nil(registry) <-
           Keyword.get(opts, :registry, Spectre.Domain.Registry) do
      opts
      |> Keyword.put(:name, via(registry, domain_ref))
      |> Sequencer.start_link()
    else
      _invalid -> {:error, :invalid_domain_options}
    end
  end

  def start_link(_opts), do: {:error, :invalid_domain_options}

  @doc "Declares one Domain as a permanent, uniquely identified child of a host supervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    domain_ref = Keyword.fetch!(opts, :domain_ref)

    %{
      id: {__MODULE__, domain_ref},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @spec handle(GenServer.server(), String.t()) :: t()
  def handle(server, ref) when is_binary(ref) and ref != "",
    do: %__MODULE__{ref: ref, server: server}

  @doc "Returns the locally supervised process for a Domain reference."
  @spec whereis(String.t(), atom()) :: pid() | nil
  def whereis(ref, registry \\ Spectre.Domain.Registry)

  def whereis(ref, registry)
      when is_binary(ref) and ref != "" and is_atom(registry) and not is_nil(registry) do
    case Registry.lookup(registry, ref) do
      [{pid, nil}] -> pid
      [] -> nil
    end
  end

  def whereis(_ref, _registry), do: nil
  defp via(registry, domain_ref), do: {:via, Registry, {registry, domain_ref}}
end
