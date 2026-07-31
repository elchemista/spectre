defmodule Spectre.Work do
  @moduledoc """
  Versioned definition for a precise, asynchronous operational procedure.

  A Work owns no process and receives no open goal. Its callbacks are short,
  deterministic reducers; registered operations run separately through the
  shared operational runtime.

      defmodule MyApp.ReadPages do
        use Spectre.Work,
          id: :read_pages,
          version: 1,
          input: :map,
          state: :map,
          update: :map,
          budget: [steps: 500, attempts: 750]

        operation :fetch_page, {MyApp.Pages, :fetch},
          input: :map,
          output: :map,
          side_effect: :idempotent,
          retry: [max_attempts: 3]

        @impl true
        def init(input, _context), do: {:ok, %{queue: input.urls, pages: []}}

        @impl true
        def next(%{queue: [url | _]}, _context),
          do: run(:fetch_page, %{url: url}, phase: :reading)

        @impl true
        def apply_result(state, _request, result, _context) do
          [_url | rest] = state.queue
          {:ok, %{state | queue: rest, pages: [result.value | state.pages]}}
        end

        @impl true
        def complete(%{queue: []} = state, _context), do: complete(Enum.reverse(state.pages))
        def complete(_state, _context), do: :continue
      end
  """

  alias Spectre.Operation.Request
  alias Spectre.Operation.Wait

  @doc false
  defmacro __using__(opts) do
    opts = evaluate(opts, __CALLER__)

    quote do
      @behaviour Spectre.Operation.Controller
      import Spectre.Work,
        only: [
          operation: 2,
          operation: 3,
          uses_operation: 1,
          run: 2,
          run: 3,
          wait: 1,
          wait: 2,
          blocked: 1,
          complete: 1,
          fail: 1
        ]

      Module.register_attribute(__MODULE__, :spectre_work_operations,
        accumulate: true,
        persist: false
      )

      Module.register_attribute(__MODULE__, :spectre_work_imports,
        accumulate: true,
        persist: false
      )

      @spectre_work_options unquote(Macro.escape(opts))
      @before_compile Spectre.Work

      @impl true
      def checkpoint_compatible?(stored, current), do: stored == current

      @impl true
      def apply_update(_state, _input, _update, _context),
        do: {:error, :work_updates_not_supported}

      defoverridable checkpoint_compatible?: 2, apply_update: 4
    end
  end

  @doc "Registers a stable operation in this Work's closed catalog."
  defmacro operation(id, opts) do
    id = evaluate(id, __CALLER__)
    opts = evaluate(opts, __CALLER__)
    executor = Keyword.get(opts, :executor)
    register_operation(id, executor, Keyword.delete(opts, :executor), __CALLER__)
  end

  @doc "Registers a stable executor and its validation/lifecycle contract."
  defmacro operation(id, executor, opts) do
    id = evaluate(id, __CALLER__)
    executor = evaluate(executor, __CALLER__)
    opts = evaluate(opts, __CALLER__)
    register_operation(id, executor, opts, __CALLER__)
  end

  @doc "Allows one operation from the Agent's immutable application registry."
  defmacro uses_operation(id) do
    id = evaluate(id, __CALLER__)

    unless (is_atom(id) and not is_nil(id)) or (is_binary(id) and id != "") do
      raise ArgumentError, "uses_operation requires a stable operation id"
    end

    quote do
      @spectre_work_imports unquote(Macro.escape(id))
    end
  end

  @doc "Builds the next operation request."
  @spec run(atom() | String.t(), term(), keyword()) :: {:run, Request.t()}
  def run(operation, input, opts \\ []), do: {:run, Request.new(operation, input, opts)}

  @doc "Builds a wait boundary."
  @spec wait(atom(), keyword()) :: {:wait, Wait.t()}
  def wait(kind, opts \\ []), do: {:wait, Wait.new(kind, opts)}

  @doc "Builds a declared human blocker."
  @spec blocked(term()) :: {:blocked, term()}
  def blocked(blocker), do: {:blocked, blocker}

  @doc "Builds successful deterministic completion."
  @spec complete(term()) :: {:complete, term()}
  def complete(value), do: {:complete, value}

  @doc "Builds a terminal failure decision."
  @spec fail(term()) :: {:error, term()}
  def fail(reason), do: {:error, reason}

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :spectre_work_options)

    operations =
      env.module
      |> Module.get_attribute(:spectre_work_operations)
      |> Enum.reverse()

    imports =
      env.module
      |> Module.get_attribute(:spectre_work_imports)
      |> Enum.reverse()
      |> Kernel.++(List.wrap(Keyword.get(opts, :imports, [])))

    definition =
      Spectre.Operation.Definition.new(%{
        id: Keyword.get(opts, :id, env.module),
        version: Keyword.get(opts, :version, 1),
        kind: :work,
        input: Keyword.get(opts, :input),
        state: Keyword.get(opts, :state),
        update: Keyword.get(opts, :update),
        checkpoint: Keyword.get(opts, :checkpoint),
        on_budget_exhausted: Keyword.get(opts, :on_budget_exhausted, :terminate),
        branches: Keyword.get(opts, :branches, %{}),
        blockers: Keyword.get(opts, :blockers, []),
        waits: Keyword.get(opts, :waits, []),
        triggers: Keyword.get(opts, :triggers, []),
        update_fields: Keyword.get(opts, :update_fields, []),
        security: Keyword.get(opts, :security, %{}),
        artifact_policy: Keyword.get(opts, :artifact_policy, %{}),
        budget: Keyword.get(opts, :budget),
        operations: operations,
        imports: imports,
        metadata: Keyword.get(opts, :metadata, %{})
      })

    quote do
      @doc false
      @impl true
      def __spectre_loop_definition__, do: unquote(Macro.escape(definition))
    end
  end

  defp register_operation(id, executor, opts, _caller) do
    spec =
      opts
      |> Map.new()
      |> Map.put(:id, id)
      |> Map.put_new(:kind, :function)
      |> Map.put(:executor, executor)
      |> Spectre.Operation.Spec.new()

    quote do
      @spectre_work_operations unquote(Macro.escape(spec))
    end
  end

  defp evaluate(quoted, caller) do
    quoted = Macro.prewalk(quoted, &Macro.expand(&1, caller))
    {value, _binding} = Code.eval_quoted(quoted, [], caller)
    value
  end
end
