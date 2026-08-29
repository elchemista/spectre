defmodule Spectre.Router.Adapter do
  @moduledoc """
  Native extension point for router evidence providers.

  An Adapter receives a projected, read-only routing request and returns scored
  references to rules that were visible to it. Spectre resolves those
  references against the compiled Definition, builds authoritative candidates,
  and leaves the final decision to the configured arbitrator.

      defmodule MyApp.BinaryRouter do
        use Spectre.Router.Adapter,
          id: :binary,
          accept: 0.86,
          margin: 0.04,
          strength: :medium

        @impl Spectre.Router.Adapter
        def evaluate(%Spectre.Router.Adapter.Request{text: text, rules: rules}) do
          results =
            rules
            |> Enum.map(&result(&1, score(text, &1)))
            |> Enum.sort_by(& &1.score, :desc)
            |> Enum.take(32)

          {:ok, results}
        end
      end

  Adapters return evidence only. They cannot provide handlers, owners, terminal
  routes, acceptance decisions, or executable callbacks. They must rank or
  filter evidence to at most 32 distinct rule references; the core rejects an
  oversized response rather than silently choosing evidence for the Adapter.
  """

  alias Spectre.Router.Adapter.Compiler
  alias Spectre.Router.Adapter.RuleView
  alias Spectre.Router.Adapter.Runner

  defmodule Request do
    @moduledoc """
    Privacy-scoped input delivered to a router Adapter.

    The request deliberately excludes handlers, runtime host context, raw
    input, mutable candidates, traces, and errors.
    """

    defstruct [
      :text,
      :meta,
      :current_flow,
      :current_scope,
      :recent_chat,
      rules: []
    ]

    @type t :: %__MODULE__{
            text: String.t(),
            meta: map(),
            current_flow: atom() | nil,
            current_scope: Spectre.Definition.scope() | nil,
            recent_chat: String.t(),
            rules: [Spectre.Router.Adapter.RuleView.t()]
          }
  end

  defmodule RuleView do
    @moduledoc """
    Read-only projection of one rule visible to a router Adapter.

    `ref` is the only accepted result reference. It combines scope and label so
    rules mounted from different Skills cannot become ambiguous.
    """

    defstruct [
      :ref,
      :label,
      :scope,
      :flow,
      :data,
      flow_path: [],
      global?: false,
      opts: []
    ]

    @type ref :: {Spectre.Definition.scope(), atom()}

    @type t :: %__MODULE__{
            ref: ref(),
            label: atom(),
            scope: Spectre.Definition.scope(),
            flow: atom() | nil,
            flow_path: [atom()],
            global?: boolean(),
            data: term(),
            opts: keyword()
          }
  end

  @type strength :: :hard | :strong | :medium | :weak

  @type result :: %{
          required(:rule) => RuleView.ref(),
          required(:score) => number(),
          optional(:margin) => number() | nil,
          optional(:matched) => term()
        }

  @type reply ::
          {:ok, result() | [result()]}
          | :skip
          | {:skip, term()}
          | {:error, term()}

  @callback evaluate(Request.t()) :: reply()

  @doc """
  Declares a native router Adapter.

  Supported options are `:id`, `:accept`, `:margin`, and `:strength`. The
  generated descriptor is static and is snapshotted into every Agent that
  declares the module in its router `via`.
  """
  defmacro __using__(opts) do
    descriptor = Compiler.descriptor_from_use!(opts, __CALLER__)

    quote do
      @behaviour Spectre.Router.Adapter
      @before_compile Spectre.Router.Adapter
      @spectre_router_adapter_descriptor unquote(Macro.escape(descriptor))

      import Spectre.Router.Adapter, only: [examples: 1, result: 2, result: 3]

      @doc false
      def __spectre_router_adapter__, do: @spectre_router_adapter_descriptor
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    unless Module.defines?(env.module, {:evaluate, 1}, :def) do
      raise ArgumentError,
            "#{inspect(env.module)} uses Spectre.Router.Adapter but does not define evaluate/1"
    end

    quote do
    end
  end

  @doc """
  Builds one Adapter result from a visible RuleView or its `{scope, label}` ref.
  """
  @spec result(RuleView.t() | RuleView.ref(), number()) :: result()
  def result(rule, score), do: result(rule, score, [])

  @doc """
  Builds one Adapter result with optional `:margin` and `:matched` evidence.
  """
  @spec result(RuleView.t() | RuleView.ref(), number(), keyword()) :: result()
  def result(rule, score, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      ref = rule_ref!(rule)
      unknown = Keyword.keys(opts) -- [:margin, :matched]

      if unknown != [] do
        raise ArgumentError, "unknown router Adapter result options: #{inspect(unknown)}"
      end

      opts
      |> Map.new()
      |> Map.take([:margin, :matched])
      |> Map.merge(%{rule: ref, score: score})
    else
      raise ArgumentError,
            "router Adapter result options must be a keyword list, got: #{inspect(opts)}"
    end
  end

  def result(_rule, _score, opts) do
    raise ArgumentError,
          "router Adapter result options must be a keyword list, got: #{inspect(opts)}"
  end

  @doc """
  Normalizes Adapter rule data into an examples list.

  Scalars, ordinary lists, and `[examples: [...]]` use the same ergonomic
  shapes as Spectre's built-in similarity providers.
  """
  @spec examples(RuleView.t() | term()) :: [term()]
  def examples(%RuleView{data: data}), do: examples(data)
  def examples(nil), do: []

  def examples(data) when is_list(data) do
    examples = if Keyword.keyword?(data), do: Keyword.get(data, :examples, data), else: data
    examples |> List.wrap() |> Enum.reject(&is_nil/1)
  end

  def examples(data), do: [data]

  @doc """
  Executes one compiled Adapter by id inside a custom router pipeline.
  """
  @spec run(Spectre.Router.Context.t(), atom()) ::
          {:cont, Spectre.Router.Context.t()} | {:error, term()}
  def run(%Spectre.Router.Context{} = context, adapter_id) when is_atom(adapter_id) do
    Runner.run(context, adapter_id)
  end

  @spec rule_ref!(RuleView.t() | RuleView.ref()) :: RuleView.ref()
  defp rule_ref!(%RuleView{ref: ref}), do: rule_ref!(ref)

  defp rule_ref!({scope, label} = ref) when is_atom(label) and not is_nil(label) do
    if valid_scope?(scope),
      do: ref,
      else: raise(ArgumentError, "invalid router Adapter rule scope: #{inspect(scope)}")
  end

  defp rule_ref!(ref),
    do: raise(ArgumentError, "invalid router Adapter rule reference: #{inspect(ref)}")

  @spec valid_scope?(term()) :: boolean()
  defp valid_scope?(:agent), do: true
  defp valid_scope?({:skill, id}), do: not is_nil(id)
  defp valid_scope?(_scope), do: false
end
