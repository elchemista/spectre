defmodule Spectre.Integration do
  @moduledoc """
  Builds the immutable service, tool and Activity declarations of a Stack package.

  Return the builder from `c:Spectre.Stack.Installable.integration/1`. Tool
  and Activity names live under the installed package's local identifier.

      Spectre.Integration.new()
      |> Spectre.Integration.service(Spectre.Inference.Selector, MyApp.Selector)
      |> Spectre.Integration.tool(:read, MyApp.Documents, args: [id: :string])
      |> Spectre.Integration.activity(:research, MyApp.Research)
  """

  alias Spectre.Stack.{Tools, Value}

  defstruct version: 1, services: %{}, tools: %{}, activities: %{}

  @type service :: {module(), keyword()}
  @type activity :: %{module: module(), options: keyword()}
  @type tool :: %{descriptor: Tools.descriptor(), helper: atom() | nil, public: map()}
  @opaque t :: %__MODULE__{
            version: 1,
            services: %{optional(module()) => service()},
            tools: %{optional(atom()) => tool()},
            activities: %{optional(atom()) => activity()}
          }

  @tool_options [:args, :description, :access, :governed, :helper, :retry, :max_bytes]

  @doc "Creates an empty set of integration declarations."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Registers a provider for a behaviour. Its options are immutable installation data."
  @spec service(t(), module(), module(), keyword()) :: t()
  def service(%__MODULE__{} = integration, role, provider, options \\ []) do
    services = put_unique!(integration.services, role, {provider, options}, :service)
    %{integration | services: services}
  end

  @doc """
  Registers a tool and its optional public argument schema.

  The adapter implements the existing `prepare/3`, `project/2` and, for
  cognitive tools, `invoke/3` callbacks. `governed:` names a GAM operation
  whose executor and authority come from the existing effect registration and
  host configuration. Cognitive tools default to `retry: :never`.

  `args:` lists required named fields and their JSON types. `description:`
  and `access: :subject_scoped` describe the tool for callers. The adapter is
  responsible for validating input and enforcing subject scope. `helper:`
  optionally generates a Server helper referencing the same execution binding.
  """
  @spec tool(t(), atom(), module(), keyword()) :: t()
  def tool(%__MODULE__{} = integration, name, adapter, options \\ []) do
    validate_options!(options, @tool_options, :tool)
    validate_name!(name)

    declaration = %{
      descriptor: %{
        contract: 1,
        adapter: adapter,
        default: name,
        operations: %{name => path(options)}
      },
      helper: Keyword.get(options, :helper),
      public: public_schema!(options)
    }

    tools = put_unique!(integration.tools, name, declaration, :tool)
    %{integration | tools: tools}
  end

  @doc """
  Declares an Activity type that can be started on demand.

  `tools:` narrows the tool scope and `requires:` lists the scoped tools
  needed for a start. `allow_children:` enables explicit subactivity starts
  and can list the allowed Activity types.
  """
  @spec activity(t(), atom(), module(), keyword()) :: t()
  def activity(%__MODULE__{} = integration, name, module, options \\ []) do
    declaration = %{module: module, options: options}
    activities = put_unique!(integration.activities, name, declaration, :activity)
    %{integration | activities: activities}
  end

  @doc false
  @spec validate!(term()) :: t()
  def validate!(
        %__MODULE__{version: 1, services: services, tools: tools, activities: activities} =
          integration
      )
      when is_map(services) and is_map(tools) and is_map(activities) do
    Value.ensure_portable!(integration, "Stack integration")
    Enum.each(integration.services, &validate_service!/1)
    Enum.each(integration.tools, &validate_tool!/1)
    Enum.each(integration.activities, fn {name, binding} -> activity_binding!(name, binding) end)
    integration
  end

  def validate!(_), do: invalid!("expected Spectre.Integration.new() declarations")

  @doc false
  @spec activity_binding!(atom(), activity()) :: activity()
  def activity_binding!(name, %{module: module, options: options} = binding) do
    validate_name!(name)

    unless compiled?(module) and function_exported?(module, :__spectre_activity__, 0) and
             function_exported?(module, :handle_start, 2) and Keyword.keyword?(options) do
      invalid!("#{inspect(module)} must use Spectre.Activity with keyword options")
    end

    validate_activity_options!(options)
    Value.ensure_portable!(binding, "Stack Activity binding")
  end

  defp validate_activity_options!(options) do
    validate_options!(options, [:tools, :requires, :allow_children], :activity)
    tools = Keyword.get(options, :tools, :all)
    requires = Keyword.get(options, :requires, [])
    children = Keyword.get(options, :allow_children, false)

    unless tool_scope?(tools) and tool_refs?(requires) and
             (tools == :all or requires -- tools == []) and
             (is_boolean(children) or
                (is_list(children) and Enum.all?(children, &activity_ref?/1))) do
      invalid!("invalid Activity tool scope, requirements or child types")
    end
  end

  @doc false
  @spec tool_scope?(term()) :: boolean()
  def tool_scope?(:all), do: true
  def tool_scope?(scope), do: tool_refs?(scope)

  defp tool_refs?(refs) when is_list(refs), do: Enum.all?(refs, &scoped_ref?/1)
  defp tool_refs?(_), do: false

  defp activity_ref?(name) when is_atom(name), do: name not in [nil, false, true]
  defp activity_ref?(name), do: scoped_ref?(name)

  defp scoped_ref?({id, name}) when is_atom(name) and name not in [nil, false, true],
    do: Value.valid_id?(id)

  defp scoped_ref?(_ref), do: false

  defp validate_service!({role, {provider, options}}) do
    unless compiled?(role) and
             function_exported?(role, :behaviour_info, 1) and
             compiled?(provider) and Keyword.keyword?(options) do
      invalid!("invalid provider #{inspect(provider)} for #{inspect(role)}")
    end

    required = role.behaviour_info(:callbacks) -- role.behaviour_info(:optional_callbacks)

    unless Enum.all?(required, fn {name, arity} -> function_exported?(provider, name, arity) end),
      do: invalid!("#{inspect(provider)} does not implement #{inspect(role)}")
  end

  defp validate_tool!({name, %{descriptor: descriptor, helper: helper, public: public}}) do
    validate_name!(name)
    Tools.validate!(%{(helper || :integration_tool) => descriptor})

    unless descriptor.default == name and Map.keys(descriptor.operations) == [name] and
             is_map(public) do
      invalid!("invalid tool declaration #{inspect(name)}")
    end
  end

  @doc false
  @spec execution_projection(t()) :: t() | nil
  def execution_projection(%__MODULE__{} = integration) do
    tools =
      Map.new(
        for {name, %{helper: nil} = tool} <- integration.tools,
            do: {name, Map.delete(tool, :public)}
      )

    effective = %{integration | tools: tools}
    if effective == new(), do: nil, else: effective
  end

  defp path(options) do
    max_bytes = Keyword.get(options, :max_bytes, Spectre.Server.Checkpoint.max_bytes())

    case Keyword.fetch(options, :governed) do
      :error ->
        %{path: :cognitive, retry: Keyword.get(options, :retry, :never), max_bytes: max_bytes}

      {:ok, operation} ->
        governed_path!(options, operation, max_bytes)
    end
  end

  defp governed_path!(options, operation, max_bytes) do
    if Keyword.has_key?(options, :retry), do: invalid!("GAM owns governed tool retries")
    %{path: :governed, operation: operation, max_bytes: max_bytes}
  end

  defp public_schema!(options) do
    description = Keyword.get(options, :description)
    access = Keyword.get(options, :access)
    args = Keyword.get(options, :args, [])

    unless (is_nil(description) or is_binary(description)) and access in [nil, :subject_scoped] and
             Keyword.keyword?(args) and Enum.uniq(Keyword.keys(args)) == Keyword.keys(args) do
      invalid!("invalid public tool description, access or argument declarations")
    end

    %{description: description, access: access, arguments: argument_schema(args)}
  end

  defp argument_schema(args) do
    %{
      "type" => "object",
      "properties" =>
        Map.new(args, fn {name, type} -> {Atom.to_string(name), schema_type!(type)} end),
      "required" => args |> Keyword.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
      "additionalProperties" => false
    }
  end

  defp schema_type!(type) when type in [:string, :integer, :number, :boolean, :object, :array],
    do: %{"type" => Atom.to_string(type)}

  defp schema_type!({:array, item}), do: %{"type" => "array", "items" => schema_type!(item)}
  defp schema_type!(type), do: invalid!("unknown tool argument type #{inspect(type)}")

  defp compiled?(module) when is_atom(module),
    do: match?({:module, ^module}, Code.ensure_compiled(module))

  defp compiled?(_), do: false

  defp validate_options!(opts, allowed, kind) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [] and
             Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts),
           do: invalid!("invalid #{kind} options")
  end

  defp validate_name!(name) when is_atom(name) and name not in [nil, false, true], do: :ok
  defp validate_name!(name), do: invalid!("expected an operation name, got #{inspect(name)}")

  defp put_unique!(entries, name, declaration, kind) do
    if Map.has_key?(entries, name), do: invalid!("duplicate #{kind} #{inspect(name)}")
    Map.put(entries, name, declaration)
  end

  defp invalid!(message), do: raise(ArgumentError, "invalid Stack integration: #{message}")
end
