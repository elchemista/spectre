defmodule Spectre.Agent do
  @moduledoc """
  Small, declarative authoring layer over the governed-act core.

      defmodule MyApp.Support do
        use Spectre.Agent,
          namespace: "my_app", name: "support", revision: 1, declared_at: 0

        candidate "lookup",
          class: "orders.lookup", row: %{read: true},
          executor_ref: "orders-reader", executor_contract_ref: "orders-v1"
      end

  `definition/0` returns an immutable `Spectre.Definition`. Metadata is explicit:
  compilation never inserts a clock value, generated identifier or module name
  into the digest. `candidate/3` supplies the remaining occurrence fields through
  `Spectre.Mind.candidate/2`; it does not submit or execute the proposal.

  Reusable Skills use the same declarations and may be installed under an alias.
  Their templates are expanded and pinned in the parent's Definition at compile
  time, not loaded from a mutable registry during a turn.

  `route/2` and `router/1` declare proposal routing through `Spectre.Router`.
  `extend/2` installs package contributions and exposes named host ports.
  Prompting and planning run in `Spectre.Mind`. This module creates no process, authority, default Mandate or
  executor. A Definition is not activated by compiling it: use the existing
  governed revision API when activation is required. These templates are not a
  second policy boundary; every resulting Candidate still needs normal admission.

  This DSL deliberately does not preserve the 0.3 flow/policy/effect runtime.
  As with all same-BEAM Elixir modules, compilation is not a sandbox for host code.
  """

  alias Spectre.Agent.{Compiler, Declaration}
  alias Spectre.Candidate
  alias Spectre.Candidate.Template
  alias Spectre.Definition
  alias Spectre.Mind
  alias Spectre.Mind.Turn
  alias Spectre.Portable
  alias Spectre.Router

  @callback definition() :: Definition.t()

  defmacro __using__(opts) do
    quote do
      @behaviour Spectre.Agent
      import Spectre.Agent,
        only: [candidate: 2, install: 2, route: 2, router: 1, extend: 2, asset: 2]

      Module.register_attribute(__MODULE__, :spectre_definition_attrs, [])
      Module.register_attribute(__MODULE__, :spectre_templates, [])
      Module.register_attribute(__MODULE__, :spectre_components, [])
      @spectre_definition_attrs unquote(opts)
      @spectre_templates %{}
      @spectre_components %{}
      @spectre_routes %{}
      @spectre_router nil
      @spectre_assets %{}
      @spectre_ports %{}
      @before_compile Spectre.Agent.Compiler
    end
  end

  @doc "Declares fixed Candidate request fields under a local name."
  defmacro candidate(name, attrs) do
    quote do
      Compiler.candidate!(__MODULE__, unquote(name), unquote(attrs), __ENV__)
    end
  end

  @doc "Installs another declaration's templates under an explicit namespace."
  defmacro install(module, opts) do
    quote do
      Compiler.install!(__MODULE__, unquote(module), unquote(opts), __ENV__)
    end
  end

  @doc "Declares a named proposal route to a Candidate template."
  defmacro route(name, attrs) do
    quote do: Compiler.route!(__MODULE__, unquote(name), unquote(attrs), __ENV__)
  end

  @doc "Declares the ordered routing methods and their acceptance thresholds."
  defmacro router(opts) do
    quote do: Compiler.router!(__MODULE__, unquote(opts), __ENV__)
  end

  @doc "Installs an extension's pinned data and separately namespaced host ports."
  defmacro extend(module, opts) do
    quote do: Compiler.extend!(__MODULE__, unquote(module), unquote(opts), __ENV__)
  end

  @doc "Declares portable package data, such as a prompt, model profile or input schema."
  defmacro asset(name, value) do
    quote do: Compiler.asset!(__MODULE__, unquote(name), unquote(value), __ENV__)
  end

  @doc "Compiles routing for an exact Definition; only the adapter registry is host-supplied."
  @spec router(Definition.t(), keyword() | map()) :: {:ok, Router.t()} | {:error, term()}
  def router(%Definition{} = definition, opts) do
    with {:ok, definition} <- Definition.new(definition),
         {:ok, declarations} <- Declaration.read(definition),
         {:ok, opts} <- Portable.normalize_attrs(opts, [:adapters], :agent_router) do
      Router.new(
        declarations.routes,
        Map.put(declarations.router, "adapters", Map.get(opts, :adapters, []))
      )
    end
  end

  @doc "Builds a Turn-bound proposal from an exact, portable Agent/Skill Definition."
  @spec candidate(Definition.t(), String.t(), Turn.t(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def candidate(%Definition{} = definition, name, %Turn{} = turn, attrs) when is_binary(name) do
    with {:ok, definition} <- Definition.new(definition),
         {:ok, templates, _components} <- declarations(definition),
         {:ok, template} <- Map.fetch(templates, name),
         {:ok, attrs} <- Template.bind(template, attrs) do
      Mind.candidate(turn, attrs)
    else
      :error -> {:error, {:unknown_candidate_template, name}}
      {:error, _reason} = error -> error
    end
  end

  def candidate(_definition, _name, _turn, _attrs), do: {:error, :invalid_agent_candidate}

  @doc false
  @spec declarations(Definition.t()) :: {:ok, map(), map()} | {:error, term()}
  def declarations(definition) do
    with {:ok, declaration} <- Declaration.read(definition) do
      {:ok, declaration.templates, declaration.components}
    end
  end
end
