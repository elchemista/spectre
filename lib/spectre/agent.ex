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

  Routing, prompting and planning remain ordinary application code implementing
  `Spectre.Mind`. This module creates no process, authority, default Mandate or
  executor. A Definition is not activated by compiling it: use the existing
  governed revision API when activation is required. These templates are not a
  second policy boundary; every resulting Candidate still needs normal admission.

  This DSL deliberately does not preserve the 0.3 flow/policy/effect runtime.
  As with all same-BEAM Elixir modules, compilation is not a sandbox for host code.
  """

  alias Spectre.Agent.Compiler
  alias Spectre.Candidate
  alias Spectre.Candidate.Template
  alias Spectre.Definition
  alias Spectre.Mind
  alias Spectre.Mind.Turn
  alias Spectre.Portable

  @callback definition() :: Definition.t()

  defmacro __using__(opts) do
    quote do
      @behaviour Spectre.Agent
      import Spectre.Agent, only: [candidate: 2, install: 2]
      Module.register_attribute(__MODULE__, :spectre_definition_attrs, [])
      Module.register_attribute(__MODULE__, :spectre_templates, [])
      Module.register_attribute(__MODULE__, :spectre_components, [])
      @spectre_definition_attrs unquote(opts)
      @spectre_templates %{}
      @spectre_components %{}
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
  def declarations(%Definition{
        body:
          %{
            "format" => "spectre-agent-declaration-v1",
            "candidates" => templates,
            "components" => components
          } = body
      })
      when map_size(body) == 3 and is_map(templates) and is_map(components) do
    # Definition validates portable content, not the schema of this particular
    # authoring format. Validate it here for both compilation and data ingress;
    # a valid digest alone does not make a component or template well-formed.
    with :ok <- validate_entries(templates, &validate_template/1),
         :ok <- validate_entries(components, &Portable.validate_ref(&1, :component_ref)) do
      {:ok, templates, components}
    end
  end

  def declarations(_definition), do: {:error, :not_an_agent_declaration}

  defp validate_entries(entries, validate) do
    Enum.reduce_while(entries, :ok, fn {name, value}, :ok ->
      with :ok <- validate_path(name), :ok <- validate.(value) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_path(name) when is_binary(name) and name != "" do
    if Enum.all?(:binary.split(name, "/", [:global]), &(&1 != "")),
      do: :ok,
      else: {:error, {:invalid_declaration_path, name}}
  end

  defp validate_path(name), do: {:error, {:invalid_declaration_path, name}}

  defp validate_template(template) do
    with {:ok, canonical} <- Template.new(template) do
      if canonical === template, do: :ok, else: {:error, :noncanonical_candidate_template}
    end
  end
end
