defmodule Spectre.Vigil do
  @moduledoc """
  Versioned durable observation loop built on the shared operational runtime.

  A Vigil waits without retaining a Runner. Timers or declared events wake it,
  one observation runs, the reducer commits, and the controller schedules its
  next wait boundary.
  """

  alias Spectre.Operation.Request
  alias Spectre.Operation.Wait

  @doc false
  defmacro __using__(opts) do
    opts = evaluate(opts, __CALLER__)

    quote do
      @behaviour Spectre.Operation.Controller
      import Spectre.Vigil,
        only: [
          operation: 2,
          operation: 3,
          uses_operation: 1,
          observe: 2,
          observe: 3,
          wait: 1,
          wait: 2,
          wait_for: 2,
          complete: 1,
          fail: 1
        ]

      Module.register_attribute(__MODULE__, :spectre_vigil_operations,
        accumulate: true,
        persist: false
      )

      Module.register_attribute(__MODULE__, :spectre_vigil_imports,
        accumulate: true,
        persist: false
      )

      @spectre_vigil_options unquote(Macro.escape(opts))
      @before_compile Spectre.Vigil

      @impl true
      def complete(_state, _context), do: :continue

      @impl true
      def checkpoint_compatible?(stored, current), do: stored == current

      @impl true
      def apply_update(_state, _input, _update, _context),
        do: {:error, :vigil_updates_not_supported}

      @impl true
      def handle_trigger(state, _trigger, _context), do: {:ok, state}

      defoverridable complete: 2,
                     checkpoint_compatible?: 2,
                     apply_update: 4,
                     handle_trigger: 3
    end
  end

  @doc "Registers one observation or cognitive operation."
  defmacro operation(id, opts) do
    id = evaluate(id, __CALLER__)
    opts = evaluate(opts, __CALLER__)
    executor = Keyword.get(opts, :executor)
    register_operation(id, executor, Keyword.delete(opts, :executor), __CALLER__)
  end

  defmacro operation(id, executor, opts) do
    id = evaluate(id, __CALLER__)
    executor = evaluate(executor, __CALLER__)
    opts = evaluate(opts, __CALLER__)
    register_operation(id, executor, opts, __CALLER__)
  end

  @doc "Allows one observation operation from the Agent application registry."
  defmacro uses_operation(id) do
    id = evaluate(id, __CALLER__)

    unless (is_atom(id) and not is_nil(id)) or (is_binary(id) and id != "") do
      raise ArgumentError, "uses_operation requires a stable operation id"
    end

    quote do
      @spectre_vigil_imports unquote(Macro.escape(id))
    end
  end

  @doc "Builds one observation request."
  @spec observe(atom() | String.t(), term(), keyword()) :: {:run, Request.t()}
  def observe(operation, input, opts \\ []), do: {:run, Request.new(operation, input, opts)}

  @doc "Builds an arbitrary declared wait boundary."
  @spec wait(atom(), keyword()) :: {:wait, Wait.t()}
  def wait(kind, opts \\ []), do: {:wait, Wait.new(kind, opts)}

  @doc "Schedules a timer relative to the controller context's committed clock."
  @spec wait_for(non_neg_integer(), map()) :: {:wait, Wait.t()}
  def wait_for(milliseconds, %{now: now})
      when is_integer(milliseconds) and milliseconds >= 0 and is_integer(now) do
    wait(:timer, due_at: now + milliseconds)
  end

  @doc "Builds a declared terminal Vigil outcome."
  @spec complete(term()) :: {:complete, term()}
  def complete(value), do: {:complete, value}

  @doc "Builds a declared terminal Vigil failure."
  @spec fail(term()) :: {:error, term()}
  def fail(reason), do: {:error, reason}

  @doc false
  defmacro __before_compile__(env) do
    opts = Module.get_attribute(env.module, :spectre_vigil_options)

    operations =
      env.module
      |> Module.get_attribute(:spectre_vigil_operations)
      |> Enum.reverse()

    imports =
      env.module
      |> Module.get_attribute(:spectre_vigil_imports)
      |> Enum.reverse()
      |> Kernel.++(List.wrap(Keyword.get(opts, :imports, [])))

    definition =
      Spectre.Operation.Definition.new(%{
        id: Keyword.get(opts, :id, env.module),
        version: Keyword.get(opts, :version, 1),
        kind: :vigil,
        input: Keyword.get(opts, :input),
        state: Keyword.get(opts, :state),
        update: Keyword.get(opts, :update),
        checkpoint: Keyword.get(opts, :checkpoint),
        on_budget_exhausted: Keyword.get(opts, :on_budget_exhausted, :terminate),
        branches: Keyword.get(opts, :branches, %{}),
        blockers: Keyword.get(opts, :blockers, []),
        waits: Keyword.get(opts, :waits, Keyword.get(opts, :triggers, [])),
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
      @spectre_vigil_operations unquote(Macro.escape(spec))
    end
  end

  defp evaluate(quoted, caller) do
    quoted = Macro.prewalk(quoted, &Macro.expand(&1, caller))
    {value, _binding} = Code.eval_quoted(quoted, [], caller)
    value
  end
end
