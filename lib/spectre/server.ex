defmodule Spectre.Server do
  @moduledoc """
  Application callbacks for Spectre's OTP agent server.

  `Spectre.Server.Runtime` is the actual GenServer callback module. It owns its
  internal messages and delegates application callbacks in the same process.
  Helpers build commands on a context; they perform no I/O before return.

      use Spectre.Server, prompt_root: "priv/support/prompts"

      def handle_flow({:support, :pricing}, _input, ctx) do
        generate(ctx, :pricing, on_result: :pricing)
      end

  Start with `start_link/1`; the Agent supplies its `server:` binding. Services
  can be modules or `{module, function}` bindings receiving request, context and
  options. Consequences pass through the automatically owned GAM domain. The
  application's `:gam` options declare permitted operations and persistence;
  they cannot replace the kernel or its execution protocol.

  Mounted Skill Servers run in independent GenServers with local state,
  workers, streams, pending intentions and checkpoint keys. They automatically
  reuse the root's same GAM integration, Domain and authority ledger. Mount
  operation restrictions can only narrow the configured authority; provenance
  identifies each Skill proposal, and consent cannot cross mounts or exact
  presentations. See the Skills guide for concurrency and lifecycle behavior.
  """
  alias Spectre.Server.{Command, Context, Runtime}
  alias Spectre.Server.Registry, as: ServerRegistry

  @type installation_id :: atom() | binary() | integer() | tuple()
  @type activity_type :: atom() | {installation_id(), atom()}
  @type activity_target :: atom() | String.t()
  @type activity_status :: :reserved | :starting | :running | :completed | :failed | :cancelled
  @type activity_identity :: %{
          ref: String.t(),
          key: atom() | nil,
          parent: String.t() | nil,
          status: activity_status(),
          revision: non_neg_integer()
        }

  @callback init(term(), Context.t()) ::
              {:ok, Context.t()} | {:ok, Context.t(), term()} | :ignore | {:stop, term()}
  @callback handle_flow(term(), Spectre.Input.t(), Context.t()) :: Context.t()
  @callback handle_pending(map(), Spectre.Input.t(), Context.t()) :: Context.t()
  @callback handle_result(term(), term(), Context.t()) :: Context.t()
  @callback handle_action(map(), Context.t()) ::
              :default | :confirm | {:confirm, map()} | {:reject, term()}
  @callback handle_skill(term(), term(), Context.t()) :: Context.t()
  @callback handle_activity(activity_identity(), term(), Context.t()) :: Context.t()
  @callback handle_approval_inbox(map(), Context.t()) :: :default | Context.t()
  @callback handle_call(term(), GenServer.from(), Context.t()) :: tuple()
  @callback handle_cast(term(), Context.t()) :: tuple()
  @callback handle_info(term(), Context.t()) :: tuple()
  @callback handle_continue(term(), Context.t()) :: tuple()
  @callback terminate(term(), Context.t()) :: term()
  @callback code_change(term(), Context.t(), term()) :: {:ok, Context.t()} | {:error, term()}
  @callback format_status(map()) :: map()
  @callback assigns_schema() :: nil | %{optional(atom()) => Spectre.Server.Contracts.schema()}
  @callback continuation_contracts() ::
              nil | %{optional(atom()) => Spectre.Server.Contracts.schema()}

  @optional_callbacks assigns_schema: 0,
                      continuation_contracts: 0,
                      handle_activity: 3,
                      handle_approval_inbox: 2

  defmacro __using__(opts) do
    tools = Spectre.Server.ToolCompiler.snapshot!(opts, __CALLER__)

    quote bind_quoted: [opts: opts, tools: Macro.escape(tools)] do
      @behaviour Spectre.Server
      @spectre_server_options opts
      @spectre_server_tools tools
      @before_compile Spectre.Server.ToolCompiler
      import Spectre.Server,
        except: [
          start_link: 1,
          child_spec: 1,
          input: 2,
          input: 3,
          cancel: 1,
          reset: 1,
          reset: 2,
          status: 1,
          skill_server: 2,
          inspect: 1,
          inspect: 2,
          trace: 2,
          trace: 3,
          gam_inspect: 1,
          gam_inspect: 2,
          subscribe: 1,
          activities: 1,
          activities: 2,
          activity: 2,
          activity: 3,
          complete_activity: 2,
          fail_activity: 2
        ]

      def __spectre_server_options__, do: @spectre_server_options
      def assigns_schema, do: nil
      def continuation_contracts, do: nil
      def init(_arg, ctx), do: {:ok, ctx}

      def handle_flow(:unmatched, _input, ctx),
        do: respond(ctx, "I could not understand the request.")

      def handle_flow(route, _input, _ctx),
        do: raise(ArgumentError, "missing handle_flow for #{inspect(route)}")

      def handle_pending(%{kind: :reply, id: id}, input, ctx),
        do: resolve_await(ctx, id, {:ok, input})

      def handle_pending(%{kind: :consent} = pending, input, ctx) do
        case String.downcase(String.trim(input.text)) do
          answer when answer in ["yes", "confirm", "confermo", "si", "sì"] ->
            confirm_pending(ctx, pending.id)

          answer when answer in ["no", "cancel", "annulla"] ->
            reject_pending(ctx, pending.id)

          _ ->
            explain_pending(ctx, pending.id)
        end
      end

      def handle_pending(pending, _input, ctx), do: explain_pending(ctx, pending.id)

      def handle_action(_action, _ctx), do: :default
      def handle_approval_inbox(_event, _ctx), do: :default

      def handle_result(tag, result, ctx), do: Spectre.Server.default_result(tag, result, ctx)

      def handle_skill(_skill, _event, ctx), do: no_response(ctx)
      def handle_activity(_identity, _event, ctx), do: ctx

      def handle_call(request, _from, ctx),
        do: {:reply, {:error, {:unsupported_call, request}}, ctx}

      def handle_cast(_request, ctx), do: {:noreply, ctx}
      def handle_info(_message, ctx), do: {:noreply, ctx}
      def handle_continue(_value, ctx), do: {:noreply, ctx}
      def terminate(_reason, _ctx), do: :ok
      def code_change(_old_vsn, ctx, _extra), do: {:ok, ctx}
      def format_status(status), do: status

      defoverridable assigns_schema: 0,
                     continuation_contracts: 0,
                     init: 2,
                     handle_action: 2,
                     handle_approval_inbox: 2,
                     handle_flow: 3,
                     handle_pending: 3,
                     handle_result: 3,
                     handle_skill: 3,
                     handle_activity: 3,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     handle_continue: 2,
                     terminate: 2,
                     code_change: 3,
                     format_status: 1
    end
  end

  @doc "Starts an AgentServer with its automatically managed GAM domain."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, opts} <- automatic_options(opts) do
      start_automatic_server(opts)
    end
  end

  @doc false
  @spec start_supervised(keyword(), {reference(), reference()}, map()) :: GenServer.on_start()
  def start_supervised(opts, {slot, proof}, default_identity) do
    with {:ok, opts} <- automatic_options(opts, default_identity) do
      opts
      |> Keyword.put(:managed_attachment, {slot, proof, self()})
      |> Keyword.put(:managed_attach_timeout, managed_shutdown_timeout(opts))
      |> start_automatic_server()
    end
  end

  @doc """
  Requests storage recovery through the configured consumer.

  `:retry` rebuilds the same Domain from its canonical store. `:memory` starts
  a fresh Domain and coordination store in RAM, preserving the running agent
  and session. Earlier governed requests require reconciliation; approvals and
  Grants from the previous Domain cannot authorize work in the new one.
  """
  @spec recover_storage(GenServer.server(), :retry | :memory) :: :ok | {:error, term()}
  def recover_storage(server, decision) when decision in [:retry, :memory],
    do: GenServer.call(server, {Runtime, :recover_storage, decision})

  @doc """
  Starts a fresh agent session, including mounted Skills and its GAM Domain.

  Keeps the root PID, name, identity and configuration. Application state is
  initialized from the original startup defaults: `terminate(:reset, context)`
  releases application-owned resources before `init/2` runs again. External
  memory, business data and previous governance history are retained.

  Only the configured consumer may reset the root. Unresolved governed work
  prevents reset. Storage defaults to its current mode; `storage: :ephemeral`
  explicitly selects fresh RAM. Durable resets survive restart using a new
  persisted generation. RAM sessions are temporary and never silently merged
  into the previous backend.

  Returns after initialization and activation. `timeout:` bounds reset work
  (30 seconds by default). After reset, uncorrelated `deliver/5` results must
  include `session:` from the Context, `status/1` or the service context.
  """
  @spec reset(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def reset(server, opts \\ []),
    do: GenServer.call(server, {Runtime, :reset, opts}, :infinity)

  @spec automatic_options(keyword(), map() | nil) :: {:ok, keyword()} | {:error, atom()}
  defp automatic_options(opts, default_identity \\ nil) do
    gam = Keyword.get(opts, :gam, [])
    identity = Keyword.get(opts, :identity, %{})
    submitters = Keyword.get(opts, :submitters, [])

    with :ok <- validate_gam_configuration(gam),
         {:ok, gam} <- normalize_storage(gam),
         :ok <- validate_automatic_options(opts, identity, submitters, gam) do
      identity =
        if map_size(identity) == 0,
          do: default_identity || %{conversation: Spectre.Identity.uuid7()},
          else: identity

      with {:ok, identity} <- Spectre.Server.GAM.Managed.Identity.normalize(identity),
           do: {:ok, opts |> Keyword.put(:gam, gam) |> Keyword.put(:identity, identity)}
    end
  end

  @spec normalize_storage(keyword()) :: {:ok, keyword()} | {:error, atom()}
  defp normalize_storage(gam) do
    case gam[:storage] do
      {module, reference} when is_atom(module) and module not in [:disk, :ledger] ->
        if Keyword.has_key?(gam, :store),
          do: {:error, :conflicting_managed_storage},
          else:
            {:ok,
             gam |> Keyword.put(:storage, :ledger) |> Keyword.put(:store, {module, reference})}

      _ ->
        {:ok, gam}
    end
  end

  defp validate_gam_configuration(gam) do
    cond do
      not is_list(gam) or not Keyword.keyword?(gam) ->
        {:error, :gam_requires_configuration_not_bridge}

      not valid_gam_options?(gam) ->
        {:error, :invalid_gam_options}

      true ->
        :ok
    end
  end

  defp validate_automatic_options(opts, identity, submitters, gam) do
    cond do
      Enum.any?(
        [
          :skill,
          :skill_parent,
          :runtime_scope,
          :activity,
          :managed_attachment,
          :managed_attach_timeout
        ],
        &Keyword.has_key?(opts, &1)
      ) ->
        {:error, :reserved_server_options}

      not is_map(identity) ->
        {:error, :invalid_server_identity}

      Spectre.Server.Checkpoint.validate_value(identity) != :ok ->
        {:error, :invalid_server_identity}

      not is_list(submitters) or not Enum.all?(submitters, &is_pid/1) ->
        {:error, :invalid_server_submitters}

      map_size(identity) == 0 and Keyword.get(gam, :storage, :ephemeral) != :ephemeral ->
        {:error, :managed_identity_required_for_durable_storage}

      true ->
        :ok
    end
  end

  @spec valid_gam_options?(keyword()) :: boolean()
  defp valid_gam_options?(options) do
    allowed = [
      :operations,
      :storage,
      :expires_at,
      :domain,
      :purpose,
      :bindings,
      :consent_ttl_ms,
      :show_timeout,
      :shutdown_timeout,
      :store,
      :reviewer,
      :approvals,
      :recovery_policy,
      :recovery_timeout,
      :authority
    ]

    keys = Keyword.keys(options)
    keys -- allowed == [] and length(keys) == length(Enum.uniq(keys))
  end

  @spec start_automatic_server(keyword()) :: GenServer.on_start()
  defp start_automatic_server(opts) do
    case Keyword.fetch(opts, :subject) do
      :error -> Runtime.start_link(opts)
      {:ok, subject} -> start_subject_owner(opts, subject)
    end
  end

  defp start_subject_owner(opts, subject) do
    name =
      ServerRegistry.via(
        Keyword.fetch!(opts, :agent),
        subject,
        Keyword.get(opts, :server_registry, ServerRegistry)
      )

    case Keyword.get(opts, :name, name) do
      ^name -> Runtime.start_link(Keyword.put(opts, :name, name))
      _ -> {:error, :subject_server_name_conflict}
    end
  end

  def child_spec(opts) do
    attachment = {make_ref(), make_ref()}
    identity = %{conversation: Spectre.Identity.uuid7()}

    %{
      id: Keyword.get(opts, :id, Runtime),
      start: {__MODULE__, :start_supervised, [opts, attachment, identity]},
      shutdown: managed_shutdown_timeout(opts)
    }
  end

  @spec managed_shutdown_timeout(keyword()) :: pos_integer()
  defp managed_shutdown_timeout(opts) do
    gam = Keyword.get(opts, :gam, [])
    timeout = if is_list(gam), do: Keyword.get(gam, :shutdown_timeout, 30_000), else: 30_000

    # Leave time for the drained owner to close its ledger and release storage.
    if is_integer(timeout) and timeout > 0,
      do: min(timeout + 5_000, 4_294_967_295),
      else: 35_000
  end

  @doc """
  Submits an input to the AgentServer.

  To answer an owned wait explicitly, pass `pending: {id, revision}` from its
  `:waiting_input` event. Add `activity: ref` for a wait opened by an Activity.
  The configured consumer or submitter can send an Activity reply. GAM consent
  continues to use `decide/4` with its presentation reference.
  """
  def input(server, input, opts \\ [])

  def input(server, input, skill: id) do
    GenServer.call(server, {Runtime, :transport_input, id, input, []})
  catch
    :exit, reason -> {:error, {:skill_unavailable, reason}}
  end

  def input(server, input, skill: id, pending: pending),
    do: targeted_pending_input(server, id, input, pending)

  def input(server, input, pending: pending, skill: id),
    do: targeted_pending_input(server, id, input, pending)

  def input(server, input, opts), do: GenServer.call(server, {Runtime, :input, input, opts})

  @spec targeted_pending_input(GenServer.server(), term(), term(), {term(), pos_integer()}) ::
          {:ok, binary()} | {:error, term()}
  defp targeted_pending_input(server, id, input, pending) do
    GenServer.call(server, {Runtime, :transport_input, id, input, [pending: pending]})
  catch
    :exit, reason -> {:error, {:skill_unavailable, reason}}
  end

  def cancel(server), do: GenServer.call(server, {Runtime, :cancel})

  @doc """
  Acquires a durable result once per event ID through the configured checkpoint.

  `session:` fences results from external work to the session that requested it.
  After a reset it is required for callback and pending tags, whose IDs may be
  reused by the application. Command tags carry runtime-generated unique IDs.
  """
  @spec deliver(GenServer.server(), binary(), term(), term(), keyword()) :: :ok | {:error, term()}
  def deliver(server, event_id, tag, result, opts \\ []),
    do: GenServer.call(server, {Runtime, :deliver, event_id, tag, result, opts}, :infinity)

  @doc "Returns a mounted Skill's supervised runtime for native OTP calls or inspection."
  @spec skill_server(GenServer.server(), term()) :: {:ok, pid()} | {:error, term()}
  def skill_server(server, id), do: GenServer.call(server, {Runtime, :skill_server, id})

  @doc "Delegates input to a mounted Skill; acceptance returns through on_result, output through handle_skill/3."
  @spec delegate(Context.t(), term(), term(), keyword()) :: Context.t()
  def delegate(ctx, skill, input, opts \\ []),
    do: command(ctx, :delegate, [skill, input], opts)

  @doc "Returns coordination status, the current session ID and whether a reset is in progress."
  @spec status(GenServer.server()) :: map()
  def status(server), do: GenServer.call(server, {Runtime, :status})

  @doc "Lists Activities owned by this Server for an authenticated caller."
  @spec activities(GenServer.server(), keyword()) ::
          {:ok, [activity_identity()]} | {:error, term()}
  def activities(server, opts \\ []),
    do: GenServer.call(server, {Runtime, :activities, opts})

  @doc "Reads one owned Activity by its execution reference or logical key."
  @spec activity(GenServer.server(), activity_target(), keyword()) ::
          {:ok, activity_identity()} | {:error, term()}
  def activity(server, target, opts \\ []),
    do: GenServer.call(server, {Runtime, :activity, target, opts})

  @doc "Acknowledges rendering of one managed presentation from its authenticated consumer."
  @spec presented(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def presented(server, presentation_ref),
    do: GenServer.call(server, {Runtime, :presented, presentation_ref})

  @doc "Receives an external approval protocol message through the trusted transport host. Decisions require configured signatures."
  @spec receive_approval(GenServer.server(), map()) :: :ok | {:ok, binary()} | {:error, term()}
  def receive_approval(server, message),
    do: GenServer.call(server, {Runtime, :approval_message, message}, :infinity)

  @doc "Reads one page of approval history through the authenticated root consumer."
  def approval_inbox(server, opts \\ []),
    do: GenServer.call(server, {Runtime, :approval_query, {:list, opts}}, :infinity)

  @doc "Retrieves an approval by its scoped reference, or by an unambiguous request id."
  def approval(server, reference),
    do: GenServer.call(server, {Runtime, :approval_query, {:fetch, reference}}, :infinity)

  @doc "Records the authenticated consumer's rendering acknowledgement and queues its signed delivery."
  @spec approval_presented(GenServer.server(), binary() | %{id: binary(), from: binary()}) ::
          :ok | {:error, term()}
  def approval_presented(server, request_id),
    do: GenServer.call(server, {Runtime, :approval_reply, request_id, :presented}, :infinity)

  @doc "Records the authenticated human consumer's exact decision and queues its signed delivery."
  @spec approval_decide(
          GenServer.server(),
          binary() | %{id: binary(), from: binary()},
          :confirm | :reject
        ) ::
          :ok | {:error, term()}
  def approval_decide(server, request_id, decision),
    do: GenServer.call(server, {Runtime, :approval_reply, request_id, decision}, :infinity)

  @doc "Submits an authenticated consumer decision for one exact presentation and mounted Skill."
  @spec decide(GenServer.server(), atom() | nil, String.t(), :confirm | :reject) ::
          {:ok, String.t()} | {:error, term()}
  def decide(server, skill, presentation_ref, decision),
    do: GenServer.call(server, {Runtime, :decide, skill, presentation_ref, decision})

  @doc "Returns the authoritative managed GAM projection, without exposing its Scope."
  @spec gam_view(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def gam_view(server), do: GenServer.call(server, {Runtime, :gam_view})

  @doc "Returns a redacted durable operational snapshot to the configured consumer. Use skill: id for a mounted Skill."
  @spec inspect(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(server, opts \\ []),
    do: GenServer.call(server, {Runtime, :diagnostics, :operational, opts})

  @doc "Returns retained coordination facts and a bounded page of correlated GAM records; coverage is explicit."
  @spec trace(GenServer.server(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def trace(server, interaction, opts \\ []),
    do: GenServer.call(server, {Runtime, :diagnostics, {:trace, interaction}, opts})

  @doc "Returns a redacted GAM page to the configured consumer. Cursors expire when the Domain revision changes."
  @spec gam_inspect(GenServer.server(), keyword()) :: {:ok, map()} | {:error, term()}
  def gam_inspect(server, opts \\ []), do: GenServer.call(server, {Runtime, :gam_inspect, opts})

  @doc "Subscribes the configured consumer to post-commit diagnostic invalidations. Read a snapshot after subscribing."
  @spec subscribe(GenServer.server()) :: :ok | {:error, term()}
  def subscribe(server), do: GenServer.call(server, {Runtime, :diagnostics_subscribe})

  def assign(%Context{} = ctx, key, value), do: %{ctx | assigns: Map.put(ctx.assigns, key, value)}

  def assign(%Context{} = ctx, values) when is_map(values),
    do: %{ctx | assigns: Map.merge(ctx.assigns, values)}

  @doc "Stores process-local application data without including it in checkpoints or service requests."
  def put_private(%Context{} = ctx, key, value),
    do: %{ctx | private: Map.put(ctx.private, key, value)}

  def put_private(%Context{} = ctx, values) when is_map(values),
    do: %{ctx | private: Map.merge(ctx.private, values)}

  def get_private(%Context{} = ctx, key, default \\ nil),
    do: Map.get(ctx.private, key, default)

  def delete_private(%Context{} = ctx, key),
    do: %{ctx | private: Map.delete(ctx.private, key)}

  @doc "Returns the current read-only view of a foreground or suspended wait by identity."
  def get_pending(%Context{} = ctx, id), do: Map.get(ctx.pending_by_id, id)

  def respond(ctx, content, opts \\ []), do: command(ctx, :respond, [content], opts)
  def generate(ctx, prompt, opts \\ []), do: command(ctx, :generate, [prompt], opts)
  def classify(ctx, input, opts \\ []), do: command(ctx, :classify, [input], opts)
  def propose(ctx, name, args, opts \\ []), do: command(ctx, :propose, [name, args], opts)

  @doc """
  Calls an operation from the Agent's compiled Stack through its registered tool binding.

  Use `{installation, operation}` to select the binding. The operation is the
  default result tag, and `on_result:` selects another tag. Governed bindings
  use the registered GAM operation and its admission policy.
  """
  @spec call_tool(Context.t(), {installation_id(), atom()}, term(), keyword()) :: Context.t()
  def call_tool(ctx, ref, args, opts \\ []), do: command(ctx, :call_tool, [ref, args], opts)

  @doc """
  Schedules an Activity start through the Server command path.

  The type is a Stack-local atom or `{installation, type}`. Each new start gets a
  new execution reference. Use `as:` for a logical key and `scope:` to narrow
  the allowed tools. With `on_result:`, readiness reaches `handle_result/3`
  as `{:ok, %{ref: ref, key: key}}`.
  """
  @spec start_activity(Context.t(), activity_type(), term(), keyword()) :: Context.t()
  def start_activity(ctx, type, args, opts \\ []),
    do: command(ctx, :start_activity, [type, args], opts)

  @doc """
  Signals an Activity by its reference or logical key.

  A callback passes its Context and schedules the request with its commands.
  An authenticated host passes the Server and receives a request identifier
  on acceptance. Lifecycle events report the outcome. Use `if_revision:` to
  require a specific current revision.
  """
  @spec signal_activity(Context.t(), activity_target(), term(), keyword()) :: Context.t()
  @spec signal_activity(GenServer.server(), activity_target(), term(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def signal_activity(ctx_or_server, target, signal, opts \\ [])

  def signal_activity(%Context{} = ctx, target, signal, opts),
    do: command(ctx, :signal_activity, [target, signal], opts)

  def signal_activity(server, target, signal, opts),
    do: GenServer.call(server, {Runtime, :signal_activity, target, signal, opts})

  @doc """
  Requests cancellation of an owned Activity.

  A callback passes its Context. An authenticated host passes the Server.
  Cancellation settles pending work while preserving reconciliation of admitted
  effects.
  """
  @spec cancel_activity(Context.t(), activity_target(), keyword()) :: Context.t()
  @spec cancel_activity(GenServer.server(), activity_target(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def cancel_activity(ctx_or_server, target, opts \\ [])

  def cancel_activity(%Context{} = ctx, target, opts),
    do: command(ctx, :cancel_activity, [target], opts)

  def cancel_activity(server, target, opts),
    do: GenServer.call(server, {Runtime, :cancel_activity, target, opts})

  @doc false
  @spec complete_activity(Context.t(), term()) :: Context.t()
  def complete_activity(ctx, value), do: command(ctx, :complete_activity, [value], [])

  @doc false
  @spec fail_activity(Context.t(), term()) :: Context.t()
  def fail_activity(ctx, reason), do: command(ctx, :fail_activity, [reason], [])

  def call_actor(ctx, actor, request, opts \\ []),
    do: command(ctx, :call_actor, [actor, request], opts)

  def await_reply(ctx, id, opts \\ []), do: command(ctx, :await_reply, [id], opts)

  @doc "Waits for a user answer. Use `accept:` for matching ordinary input and `prompt:` for the question delivered with a targeted wait."
  def await_input(ctx, id, opts \\ []),
    do: await_reply(ctx, id, Spectre.Server.InputWait.options(opts))

  @doc false
  @spec default_result(term(), term(), Context.t()) :: Context.t()
  def default_result(_tag, {:generated, %{text: text} = response}, ctx) do
    case Map.get(response, :proposals, []) do
      [] -> respond(ctx, text)
      proposals -> Spectre.Server.Plan.start(ctx, proposals)
    end
  end

  def default_result({Spectre.Server.Plan, remaining}, result, ctx),
    do: Spectre.Server.Plan.continue(ctx, remaining, result)

  def default_result(_tag, {:error, _}, ctx),
    do: respond(ctx, "The request could not be completed.")

  def default_result(_tag, {kind, _}, ctx) when kind in [:governed_unknown, :tool_unknown],
    do: respond(ctx, "The operation is still under verification.")

  def default_result(_tag, _result, ctx), do: no_response(ctx)

  def resolve_await(ctx, id, result), do: command(ctx, :resolve_await, [id, result], [])
  def confirm_pending(ctx, id), do: command(ctx, :confirm_pending, [id], [])
  def reject_pending(ctx, id), do: command(ctx, :reject_pending, [id], [])
  def explain_pending(ctx, id), do: command(ctx, :explain_pending, [id], [])
  def resume_pending(ctx, id), do: command(ctx, :resume_pending, [id], [])

  @doc "Requests closure of one wait through the audited lifecycle; this is not user rejection or effect cancellation."
  def close_pending(ctx, id, opts \\ []), do: command(ctx, :close_pending, [id], opts)

  @doc """
  Schedules an audited, revision-bound closure with a durable absolute deadline.

  The Runtime owns the timer by default. With `timer: :application` it records
  the same deadline while the application owns its native OTP wakeup. The
  recorded schedule identity can guard `close_pending/3` through `:if_schedule`.
  """
  def close_pending_after(ctx, id, delay_ms, opts \\ []),
    do: command(ctx, :close_pending_after, [id, delay_ms], opts)

  @doc "Cancels the scheduled intention closure while preserving the GAM consent deadline."
  def cancel_pending_close(ctx, id, opts \\ []),
    do: command(ctx, :cancel_pending_close, [id], opts)

  def route_current_input(ctx, opts \\ []), do: command(ctx, :route_current_input, [], opts)
  def no_response(ctx), do: command(ctx, :no_response, [], [])

  defp command(%Context{} = ctx, kind, args, opts) do
    %{ctx | commands: ctx.commands ++ [%Command{kind: kind, args: args, opts: opts}]}
  end
end
