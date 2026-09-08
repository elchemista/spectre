defmodule Spectre.Agent.Publication do
  @moduledoc """
  Binds compiled authoring code and plans to explicit governed Definitions.

  Publication is pure construction, not Domain activation. Every Skill mount
  needs its own explicitly supplied Definition; parent revision/time are never
  copied into a child. Runtime verification compares the complete plan again.
  BEAM fingerprints detect an accidental code upgrade, not hostile host code
  in the same VM and not a cryptographic signature or remote attestation.
  """

  alias Spectre.{Adapter, Definition, Portable}

  @doc "Builds a Definition without choosing publication metadata or activating it."
  def definition(module, opts) do
    with :ok <- Adapter.validate(module, __spectre_plan__: 0),
         {:ok, attrs} <-
           Portable.normalize_attrs(
             opts,
             [:revision, :declared_at, :previous_ref, :components],
             :publication
           ),
         plan = module.__spectre_plan__(),
         {:ok, children} <- components(plan.components, Map.get(attrs, :components, %{})),
         {:ok, body} <- body(module, plan, children) do
      attrs
      |> Map.drop([:components])
      |> Map.merge(plan.identity)
      |> Map.put(:body, body)
      |> Definition.new()
    end
  end

  @doc "Declaration convenience that raises for invalid explicit publication metadata."
  def definition!(module, opts) do
    case definition(module, opts) do
      {:ok, definition} -> definition
      {:error, reason} -> raise ArgumentError, "invalid Spectre publication: #{inspect(reason)}"
    end
  end

  @doc "Checks current code and all mounted plans against an exact immutable Definition."
  def verify(module, %Definition{} = supplied) do
    with {:ok, supplied} <- Definition.new(supplied),
         :ok <- Adapter.validate(module, __spectre_plan__: 0),
         plan = module.__spectre_plan__(),
         {:ok, children} <- children(supplied),
         {:ok, children} <- components(plan.components, children),
         {:ok, expected} <- body(module, plan, children),
         true <-
           supplied.namespace === plan.identity.namespace and supplied.name === plan.identity.name,
         true <- supplied.body === expected do
      {:ok, plan, children}
    else
      false -> {:error, :authoring_definition_mismatch}
      {:error, _} = error -> error
    end
  end

  def verify(_module, _definition), do: {:error, :invalid_authoring_definition}

  @doc "Returns flattened ports with component origin; no runtime address or secret is included."
  def ports(module), do: collect_ports(module.__spectre_plan__(), "")

  @doc false
  def code_ref(module),
    do:
      Portable.content_ref!(:authoring_code, %{
        "module" => Atom.to_string(module),
        "beam_fingerprint" => Base.encode16(module.module_info(:md5))
      })

  @doc false
  def flow_body(flow, flow_name \\ nil) do
    rules = Map.new(flow.routes, fn {name, entry} -> {rule_ref(flow_name, name), entry.rule} end)
    base = %{"pipelines" => flow.pipelines}

    if is_nil(flow.routing) and rules == %{},
      do: base,
      else:
        Map.put(base, "routing", %{"rules" => rules, "config" => flow.routing || default_router()})
  end

  @doc false
  def rule_ref(nil, name), do: name
  def rule_ref(flow, name), do: flow <> "/" <> name

  defp body(module, plan, children) do
    # The portable plan is the only copy of flow/request/prompt declarations.
    # Skill plans live in their explicit child Definitions, not twice in the
    # parent. Workers/Vigils publish independently when the host opens them.
    plan =
      plan
      |> Map.delete(:components)
      |> Map.update!(:jobs, fn jobs ->
        Map.new(jobs, fn {name, job} ->
          {name, %{kind: job.kind, module: job.module, code_ref: code_ref(job.module)}}
        end)
      end)

    body = %{
      "format" => "spectre-agent-declaration-v3",
      "authoring" => %{
        "code_ref" => code_ref(module),
        "plan" => plan,
        "component_definitions" =>
          Map.new(children, fn {name, child} -> {name, Definition.canonical(child)} end)
      }
    }

    with :ok <- Portable.validate(body), do: {:ok, body}
  end

  defp components(declared, supplied) when is_map(supplied) and not is_struct(supplied) do
    with {:ok, supplied} <- Spectre.Agent.Wiring.registry(supplied) do
      verify_components(declared, supplied)
    end
  end

  defp components(_declared, _supplied), do: {:error, :invalid_component_definitions}

  defp verify_components(declared, supplied) do
    if Enum.sort(Map.keys(declared)) === Enum.sort(Map.keys(supplied)) do
      Enum.reduce_while(declared, {:ok, %{}}, fn {name, entry}, {:ok, children} ->
        case verify(entry.module, supplied[name]) do
          {:ok, plan, _children} when plan === entry.plan ->
            {:cont, {:ok, Map.put(children, name, supplied[name])}}

          {:ok, _changed, _children} ->
            {:halt, {:error, {:component_code_changed, name}}}

          {:error, reason} ->
            {:halt, {:error, {:component_definition, name, reason}}}
        end
      end)
    else
      {:error, {:component_definitions_required, Enum.sort(Map.keys(declared))}}
    end
  end

  # Decode only here. Runtime calls this after verify/2 checked the entire
  # tree; it reuses the verified plans instead of recursively verifying again.
  @doc false
  @spec children(Definition.t()) :: {:ok, %{String.t() => Definition.t()}} | {:error, term()}
  def children(%Definition{body: %{"authoring" => %{"component_definitions" => children}}})
      when is_map(children) do
    Enum.reduce_while(children, {:ok, %{}}, fn {name, data}, {:ok, acc} ->
      case Definition.from_canonical(data) do
        {:ok, definition} -> {:cont, {:ok, Map.put(acc, name, definition)}}
        error -> {:halt, error}
      end
    end)
  end

  def children(_definition), do: {:error, :not_an_authoring_definition}

  defp collect_ports(plan, prefix) do
    direct =
      Map.new(required_ports(plan), fn {name, port} ->
        required =
          case {port.kind, Map.get(plan.settings, name)} do
            {:semantic_cache, %{learn: :review}} -> [put: 3, verify: 4]
            _ordinary -> []
          end

        port = Map.put(port, :required_callbacks, required)

        port =
          if Map.has_key?(port, :via), do: Map.update!(port, :via, &(prefix <> &1)), else: port

        {prefix <> name, port}
      end)

    Enum.reduce(plan.components, direct, fn {name, entry}, ports ->
      Map.merge(ports, collect_ports(entry.plan, prefix <> name <> "/"))
    end)
  end

  defp required_ports(plan) do
    ports =
      Enum.reduce(plan.settings, plan.ports, fn {name, _config}, ports ->
        case String.split(name, "/", parts: 2) do
          ["history", _] -> require_port(ports, :history, name)
          ["memory", _] -> require_port(ports, :memory, name)
          _other -> ports
        end
      end)

    ports =
      Enum.reduce(plan.asks, ports, fn {_name, ask}, ports ->
        case Map.get(ask, :via, Map.get(ask, :model)) do
          nil -> ports
          target -> require_port(ports, :request, "request/" <> to_string(target))
        end
      end)

    Enum.reduce(plan.flows, ports, fn {_name, flow}, ports ->
      ports =
        Enum.reduce(flow.pipelines, ports, &require_port(&2, :pipelines, "pipelines/" <> &1))

      via = if flow.routing, do: flow.routing["via"], else: []

      ports =
        via
        |> Enum.reject(&(&1 in ["regex", "string_bag", "bag_distance", "jaro"]))
        |> Enum.reduce(ports, fn method, ports ->
          key = "router/" <> method

          if method in ["semantic_cache", "local_classifier", "llm_classifier"] do
            # The ordinary bridge is supplied by the flow binding. An explicit
            # host matcher may replace it, using the same registry as :binary.
            Map.put_new(ports, key, %{
              kind: :router,
              module: nil,
              options: [],
              origin: key,
              optional: true
            })
          else
            require_port(ports, :router, key)
          end
        end)

      Enum.reduce(flow.binding, ports, fn {kind, name}, ports ->
        kind = if kind == :cache, do: :semantic_cache, else: kind
        key = Atom.to_string(kind) <> "/" <> to_string(name)
        ports = require_port(ports, kind, key)

        config = Map.get(plan.settings, key, %{})

        if kind == :classifier and Map.has_key?(config, :class) do
          ports = Map.update!(ports, key, &Map.put(&1, :mode, :governed))

          case Map.get(config, :via) do
            nil ->
              ports

            via ->
              target = "request/" <> to_string(via)

              ports
              |> require_port(:request, target)
              |> Map.update!(key, &Map.put(&1, :via, target))
          end
        else
          ports
        end
      end)
    end)
  end

  defp require_port(ports, kind, name),
    do: Map.put_new(ports, name, %{kind: kind, module: nil, options: [], origin: name})

  defp default_router do
    {:ok, config} = Spectre.Router.configuration([])
    config
  end
end
