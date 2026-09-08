defmodule Spectre.Agent do
  @moduledoc """
  Handler-oriented agent authoring above the governed-act core.

      defmodule MyApp.Orders do
        use Spectre.Agent, namespace: "shop", name: "orders"

        flow :orders do
          router via: [:regex]
          route :lookup, match: [regex: ~r/^order (?<id>[0-9]+)$/u]
        end

        @impl true
        def handle_turn({:orders, :lookup, %{"id" => id}}, _turn, state),
          do: {:request, "orders.lookup", %{"order_id" => id}, state}
      end

  Handlers prepare requests; only Instance.advance/3 submits the selected one.
  The host supplies Surface/executor bindings, authentication and supervision.
  Routing does not authorize an effect; generating text does not deliver it.
  Missing handlers are explicit errors, not successful empty responses.

  One Instance owns state. Skills have namespaced local state in that same
  owner; Router and Stack are process-free plans. Slow work uses the Instance's
  existing temporary worker, so state/info reads remain responsive.

  definition/1 requires explicit revision/time and resolved Skill Definitions.
  It neither activates a Definition nor opens a Scope. The generated child
  specification and start_link/1 delegate to Instance, not a second runtime.
  """

  alias Spectre.Agent.{Declaration, Flow, Publication}
  alias Spectre.{Definition, Mind}
  alias Spectre.Candidate.Template

  @behaviour Spectre.Mind
  @impl Spectre.Mind
  def ref, do: "spectre:agent:handler-authoring:v1"
  @impl Spectre.Mind
  def deliberate(_turn, _opts), do: {:error, :handler_authoring_requires_instance}

  @type callback_result ::
          {:ok, term()}
          | {:request, term(), term()}
          | {:request, atom() | String.t(), term(), term()}
          | {:ask, atom(), map(), term()}
          | {:classify, atom(), term(), term()}
          | {:error, term(), term()}
  @callback init(term()) :: {:ok, term()} | {:error, term()}
  @callback handle_turn(tuple(), Spectre.Agent.Turn.t(), term()) :: callback_result()
  @callback handle_work(term(), Spectre.Agent.Turn.t(), term()) :: callback_result()
  @callback handle_vigil(term(), Spectre.Agent.Turn.t(), term()) :: callback_result()
  @callback handle_result(tuple(), map(), Spectre.Agent.Turn.t(), term()) :: callback_result()
  @optional_callbacks handle_turn: 3, handle_work: 3, handle_vigil: 3, handle_result: 4

  defmacro __using__(opts) do
    quote do
      @behaviour Spectre.Agent
      use Spectre.Agent.Compiler, Keyword.put_new(unquote(opts), :kind, :agent)
      import Spectre.Agent, only: [route_result: 2]

      @impl Spectre.Agent
      def init(state), do: {:ok, state}
      defoverridable init: 1

      @doc "Starts the sole state owner with an explicit governed Definition and authenticated Scope."
      def start_link(opts), do: Spectre.Instance.start_link(Keyword.put(opts, :agent, __MODULE__))

      @doc "Returns an ordinary OTP child specification; does not start dependencies."
      def child_spec(opts) do
        Spectre.Instance.child_spec(Keyword.put(opts, :agent, __MODULE__))
        |> Map.put(:start, {__MODULE__, :start_link, [opts]})
      end

      @doc "Routes authenticated input to one handler and returns unsubmitted requests."
      def turn(instance, input, opts \\ []), do: Spectre.Instance.turn(instance, input, opts)

      @doc "Starts a declared Worker only after its explicit governed Scope opening."
      def start_worker(instance, name, opts),
        do: Spectre.Agent.start_component(instance, :worker, name, opts)

      @doc "Starts a declared Vigil without installing a timer or subscription."
      def start_vigil(instance, name, opts),
        do: Spectre.Agent.start_component(instance, :vigil, name, opts)
    end
  end

  @doc "Prepares a published flow using the same Router and Pipeline as the low-level API."
  def flow(%Definition{} = definition, name, opts \\ []) do
    with {:ok, declaration} <- Declaration.read(definition),
         {:ok, data} <- Map.fetch(declaration.flows, to_string(name)) do
      Flow.new(definition.ref, to_string(name), data, opts)
    else
      :error -> {:error, {:unknown_agent_flow, name}}
      {:error, _} = error -> error
    end
  end

  @doc "Binds a low-level named Candidate template to a sealed Turn, without submission."
  def candidate(%Definition{} = definition, name, turn, attrs) do
    with {:ok, declaration} <- Declaration.read(definition),
         {:ok, template} <- Map.fetch(declaration.templates, to_string(name)),
         {:ok, attrs} <- Template.bind(Map.drop(template, ["disclosure_to", "meter"]), attrs) do
      Mind.candidate(turn, attrs)
    else
      :error -> {:error, {:unknown_candidate_template, name}}
      {:error, _} = error -> error
    end
  end

  @doc "Routes a confirmed classifier result using the originating flow's allowed labels."
  defdelegate route_result(turn, result), to: Spectre.Agent.Classification, as: :route_result

  @doc "Opens a declared component through the existing Scope/Instance lifecycle."
  defdelegate start_component(instance, kind, name, opts), to: Spectre.Agent.Component, as: :start

  @doc false
  def declarations(definition) do
    with {:ok, declaration} <- Declaration.read(definition),
         do: {:ok, declaration.templates, declaration.components}
  end

  @doc "Checks code, plans and components against their published Definition without executing handlers."
  defdelegate verify_definition(module, definition), to: Publication, as: :verify
end
