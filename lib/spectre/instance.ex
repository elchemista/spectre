defmodule Spectre.Instance do
  @moduledoc """
  Minimal OTP owner for one live agent Scope.

  An Instance associates an authenticated Scope with one exact immutable
  `Spectre.Definition` revision and serializes application deliberation. The
  Definition reference is application configuration made available to the
  Mind; it neither grants authority nor asserts that resulting Candidates
  belong to that Definition, and it need not remain the current Definition
  head. Every Candidate is still evaluated independently by the kernel.

  An Instance may retain an opaque application value, but it owns no authority,
  Grant, credential or durable execution fact. Those remain exclusively in the
  Domain ledger.

  Stateful minds may additionally implement `Spectre.Mind.deliberate/3`. The
  callback receives the current application value and may return its successor
  together with capability-free Candidates. A stateless Mind continues to use
  `deliberate/2`, in which case the Instance value is left unchanged.

  Instances are ordinary OTP children supervised by the host application. Each
  one monitors the Domain process that authenticated its Scope and shuts down
  when that process or the Scope fence becomes invalid, allowing the host to
  re-authenticate and create a fresh Instance. No global Instance registry or
  second persistence system is created here.
  """

  use GenServer

  alias Spectre.{Candidate, Definition, Domain, Portable, Scope}
  alias Spectre.Instance.State

  @options [:scope, :definition_ref, :state, :name]
  @reserved_mind_options [:definition_ref, :state_revision]
  @scope_fence_errors [
    :context_domain_mismatch,
    :definition_lookup_failed,
    :domain_not_found,
    :domain_registry_unavailable,
    :invalid_domain_registration,
    :invalid_scope_context,
    :scope_validation_failed,
    :submission_context_authentication_failed,
    :submission_context_domain_mismatch,
    :submission_context_generation_mismatch,
    :submission_context_ingress_mismatch
  ]

  @type server :: GenServer.server()
  @type info :: %{
          required(:ref) => String.t(),
          required(:domain_ref) => String.t(),
          required(:definition_ref) => String.t(),
          required(:state_revision) => non_neg_integer()
        }

  @doc "Starts an Instance around an already authenticated and durable Scope."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    with {:ok, config} <- configuration(opts) do
      GenServer.start_link(__MODULE__, Map.delete(config, :name), server_options(config))
    end
  end

  def start_link(_opts), do: {:error, :invalid_instance_options}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: child_id(opts),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Runs one serialized, capability-free deliberation for this Instance."
  @spec turn(server(), term(), keyword()) ::
          {:ok,
           %{
             turn: Spectre.Mind.Turn.t(),
             evidence: [Spectre.Evidence.t()],
             candidates: [Candidate.t()]
           }}
          | {:error, term()}
  def turn(server, input, opts \\ [])

  def turn(server, input, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: GenServer.call(server, {:turn, input, opts}, :infinity),
      else: {:error, :invalid_instance_turn_options}
  end

  def turn(_server, _input, _opts), do: {:error, :invalid_instance_turn_options}

  @doc "Submits one Candidate through the bound Scope's normal governed path."
  @spec propose(server(), Candidate.t() | map() | keyword(), keyword()) ::
          {:ok, Spectre.Proposal.Result.t()} | {:error, term()}
  def propose(server, candidate, opts \\ [])

  def propose(server, candidate, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: GenServer.call(server, {:propose, candidate, opts}, :infinity),
      else: {:error, :invalid_instance_proposal_options}
  end

  def propose(_server, _candidate, _opts),
    do: {:error, :invalid_instance_proposal_options}

  @doc "Returns the exact immutable Definition revision selected by this Instance."
  @spec definition(server()) :: {:ok, Definition.t()} | {:error, term()}
  def definition(server), do: GenServer.call(server, :definition)

  @doc "Returns the authenticated Scope owned by this Instance."
  @spec scope(server()) :: Scope.t()
  def scope(server), do: GenServer.call(server, :scope)

  @doc "Returns non-authoritative Instance identity and local state revision."
  @spec info(server()) :: info()
  def info(server), do: GenServer.call(server, :info)

  @doc "Returns the opaque, process-local application state and its revision."
  @spec state(server()) :: %{required(:revision) => non_neg_integer(), required(:value) => term()}
  def state(server), do: GenServer.call(server, :state)

  @impl GenServer
  def init(config) do
    with {:ok, scope} <- current_scope(Map.fetch!(config, :scope)),
         definition_ref = Map.fetch!(config, :definition_ref),
         {:ok, domain_monitor} <- monitor_domain(scope),
         {:ok, %Definition{}} <- fetch_definition(scope, definition_ref) do
      {:ok, State.new(scope, definition_ref, Map.get(config, :state, %{}), domain_monitor)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:scope, _from, %State{} = state),
    do: {:reply, state.scope, state}

  def handle_call(:info, _from, %State{} = state),
    do: {:reply, State.info(state), state}

  def handle_call(:state, _from, %State{} = state),
    do: {:reply, %{revision: state.revision, value: state.value}, state}

  def handle_call(:definition, _from, %State{} = state) do
    state.scope
    |> fetch_definition(state.definition_ref)
    |> reply_or_stop(state)
  end

  def handle_call({:turn, input, opts}, _from, %State{} = state) do
    with {:ok, opts} <- bind_mind_options(opts, state),
         {:ok, result} <- Spectre.turn(state.scope, input, state.value, opts) do
      {next_value, result} = Map.pop!(result, :state)
      {:reply, {:ok, result}, State.advance(state, next_value)}
    else
      {:error, _reason} = error -> reply_or_stop(error, state)
    end
  end

  def handle_call({:propose, candidate, opts}, _from, %State{} = state) do
    state.scope
    |> Spectre.propose(candidate, opts)
    |> reply_or_stop(state)
  end

  @impl GenServer
  def handle_info(
        {:DOWN, monitor, :process, _domain, reason},
        %State{domain_monitor: monitor} = state
      ) do
    {:stop, {:shutdown, {:domain_down, reason}}, state}
  end

  def handle_info(_message, %State{} = state), do: {:noreply, state}

  defp configuration(opts) do
    with {:ok, config} <- Portable.normalize_attrs(opts, @options, :instance),
         {:ok, %Scope{}} <- Map.fetch(config, :scope),
         {:ok, definition_ref} <- Map.fetch(config, :definition_ref),
         :ok <- Portable.validate_ref(definition_ref, :definition_ref) do
      {:ok, config}
    else
      :error -> {:error, :missing_instance_options}
      {:ok, _invalid_scope} -> {:error, :invalid_instance_scope}
      {:error, _reason} = error -> error
    end
  end

  defp current_scope(%Scope{} = scope) do
    case Spectre.resume_scope(scope.domain, scope.context) do
      {:ok, %Scope{} = current} -> {:ok, current}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_instance_scope_response}
    end
  end

  defp fetch_definition(scope, definition_ref), do: Spectre.definition(scope, definition_ref)

  defp monitor_domain(%Scope{domain: %Domain{server: server}}) when is_pid(server),
    do: {:ok, Process.monitor(server)}

  defp monitor_domain(_scope), do: {:error, :invalid_instance_domain}

  defp bind_mind_options(opts, state) do
    mind_opts = Keyword.get(opts, :mind_opts, [])

    if Portable.keyword?(mind_opts) do
      case Enum.find(@reserved_mind_options, &Keyword.has_key?(mind_opts, &1)) do
        nil ->
          bound =
            Keyword.merge(mind_opts,
              definition_ref: state.definition_ref,
              state_revision: state.revision
            )

          {:ok, Keyword.put(opts, :mind_opts, bound)}

        option ->
          {:error, {:reserved_instance_mind_option, option}}
      end
    else
      {:error, :invalid_mind_options}
    end
  end

  defp reply_or_stop({:error, reason} = error, state) do
    if scope_fence_error?(reason) do
      {:stop, {:shutdown, {:scope_fenced, reason}}, error, state}
    else
      {:reply, error, state}
    end
  end

  defp reply_or_stop({:ok, _value} = result, state), do: {:reply, result, state}

  defp scope_fence_error?(reason) when reason in @scope_fence_errors, do: true
  defp scope_fence_error?({:scope_not_open, _scope_ref}), do: true
  defp scope_fence_error?({:scope_context_domain_mismatch, _scope_ref}), do: true
  defp scope_fence_error?({:scope_context_binding_mismatch, _scope_ref}), do: true
  defp scope_fence_error?(_reason), do: false

  defp server_options(config) do
    case Map.fetch(config, :name) do
      {:ok, name} -> [name: name]
      :error -> []
    end
  end

  defp child_id(opts) do
    case Keyword.get(opts, :scope) do
      %Scope{} = scope -> {__MODULE__, Scope.domain_ref(scope), Scope.ref(scope)}
      _invalid -> __MODULE__
    end
  end
end
