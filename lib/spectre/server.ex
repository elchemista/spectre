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
  options. Consequences are submitted exclusively to the host's `:gam` bridge.
  """
  alias Spectre.Server.{Command, Context, Runtime}
  alias Spectre.Server.Registry, as: ServerRegistry

  @callback init(term(), Context.t()) ::
              {:ok, Context.t()} | {:ok, Context.t(), term()} | :ignore | {:stop, term()}
  @callback handle_flow(term(), Spectre.Input.t(), Context.t()) :: Context.t()
  @callback handle_pending(map(), Spectre.Input.t(), Context.t()) :: Context.t()
  @callback handle_result(term(), term(), Context.t()) :: Context.t()
  @callback handle_call(term(), GenServer.from(), Context.t()) :: tuple()
  @callback handle_cast(term(), Context.t()) :: tuple()
  @callback handle_info(term(), Context.t()) :: tuple()
  @callback handle_continue(term(), Context.t()) :: tuple()
  @callback terminate(term(), Context.t()) :: term()
  @callback code_change(term(), Context.t(), term()) :: {:ok, Context.t()} | {:error, term()}
  @callback format_status(map()) :: map()

  defmacro __using__(opts) do
    tools = Spectre.Server.ToolCompiler.snapshot!(opts, __CALLER__)

    quote bind_quoted: [opts: opts, tools: Macro.escape(tools)] do
      @behaviour Spectre.Server
      @spectre_server_options opts
      @spectre_server_tools tools
      @before_compile Spectre.Server.ToolCompiler
      import Spectre.Server,
        except: [start_link: 1, child_spec: 1, input: 2, input: 3, cancel: 1, status: 1]

      def __spectre_server_options__, do: @spectre_server_options
      def init(_arg, ctx), do: {:ok, ctx}

      def handle_flow(:unmatched, _input, ctx),
        do: respond(ctx, "I could not understand the request.")

      def handle_flow(route, _input, _ctx),
        do: raise(ArgumentError, "missing handle_flow for #{inspect(route)}")

      def handle_pending(%{kind: :reply, id: id}, input, ctx),
        do: resolve_await(ctx, id, {:ok, input})

      def handle_pending(pending, _input, ctx), do: explain_pending(ctx, pending.id)

      def handle_result(_tag, {:generated, %{text: text} = response}, ctx) do
        case Map.get(response, :proposals, []) do
          [] -> respond(ctx, text)
          proposals -> Spectre.Server.Plan.start(ctx, proposals)
        end
      end

      def handle_result({Spectre.Server.Plan, remaining}, result, ctx),
        do: Spectre.Server.Plan.continue(ctx, remaining, result)

      def handle_result(_tag, {:error, _failure}, ctx),
        do: respond(ctx, "The request could not be completed.")

      def handle_result(_tag, {:governed_unknown, _details}, ctx),
        do: respond(ctx, "The operation is still under verification.")

      def handle_result(_tag, {:tool_unknown, _details}, ctx),
        do: respond(ctx, "The operation is still under verification.")

      def handle_result(_tag, _result, ctx), do: no_response(ctx)

      def handle_call(request, _from, ctx),
        do: {:reply, {:error, {:unsupported_call, request}}, ctx}

      def handle_cast(_request, ctx), do: {:noreply, ctx}
      def handle_info(_message, ctx), do: {:noreply, ctx}
      def handle_continue(_value, ctx), do: {:noreply, ctx}
      def terminate(_reason, _ctx), do: :ok
      def code_change(_old_vsn, ctx, _extra), do: {:ok, ctx}
      def format_status(status), do: status

      defoverridable init: 2,
                     handle_flow: 3,
                     handle_pending: 3,
                     handle_result: 3,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     handle_continue: 2,
                     terminate: 2,
                     code_change: 3,
                     format_status: 1
    end
  end

  def start_link(opts) do
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

  def child_spec(opts),
    do: %{id: Keyword.get(opts, :id, Runtime), start: {__MODULE__, :start_link, [opts]}}

  def input(server, input, opts \\ []), do: GenServer.call(server, {Runtime, :input, input, opts})
  def cancel(server), do: GenServer.call(server, {Runtime, :cancel})
  @doc "Acquires a durable result once per event id; requires a configured checkpoint store."
  def deliver(server, event_id, tag, result),
    do: GenServer.call(server, {Runtime, :deliver, event_id, tag, result}, :infinity)

  def status(server), do: GenServer.call(server, {Runtime, :status})

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

  def call_actor(ctx, actor, request, opts \\ []),
    do: command(ctx, :call_actor, [actor, request], opts)

  def await_reply(ctx, id, opts \\ []), do: command(ctx, :await_reply, [id], opts)
  @doc "Waits for a user answer in the foreground; actor replies use await_reply/3."
  def await_input(ctx, id, opts \\ []),
    do: await_reply(ctx, id, Keyword.put(opts, :foreground, true))

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
