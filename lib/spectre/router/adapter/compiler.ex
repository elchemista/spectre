defmodule Spectre.Router.Adapter.Compiler do
  @moduledoc false

  alias Spectre.Definition
  alias Spectre.Definition.Canonical.Data

  @contract_version 1
  @compiled_key :__spectre_router_adapters__
  @built_in_steps [
    :regex,
    :bag,
    :jaro,
    :embedding,
    :semantic_cache,
    :classifier,
    :llm,
    :llm_classifier,
    :arbitrate,
    :terminalize
  ]
  @control_steps [:arbitrate, :terminalize]
  @strengths [:hard, :strong, :medium, :weak]
  @descriptor_keys [:contract, :id, :accept, :margin, :strength]

  @type descriptor :: %{
          required(:contract) => pos_integer(),
          required(:id) => atom(),
          required(:accept) => float(),
          required(:margin) => float() | nil,
          required(:strength) => Spectre.Router.Adapter.strength()
        }

  @type entry :: %{
          required(:id) => atom(),
          required(:module) => module(),
          required(:descriptor) => descriptor(),
          required(:order) => non_neg_integer()
        }

  @doc false
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc false
  @spec compiled_key() :: atom()
  def compiled_key, do: @compiled_key

  @doc false
  @spec built_in_steps() :: [atom()]
  def built_in_steps, do: @built_in_steps

  @doc false
  @spec control_steps() :: [atom()]
  def control_steps, do: @control_steps

  @doc false
  @spec fetch_descriptor(module()) :: {:ok, descriptor()} | {:error, term()}
  def fetch_descriptor(module) when is_atom(module) do
    load_descriptor(module, @built_in_steps)
  end

  @doc false
  @spec descriptor_from_use!(Macro.t(), Macro.Env.t()) :: descriptor()
  def descriptor_from_use!(opts_ast, %Macro.Env{} = env) do
    opts = evaluate_opts!(opts_ast, env)

    case descriptor_from_opts(opts, []) do
      {:ok, descriptor} -> descriptor
      {:error, reason} -> raise ArgumentError, format_descriptor_error(env.module, reason)
    end
  end

  @doc false
  @spec compile_router!(module(), keyword(), [atom()]) :: keyword()
  def compile_router!(owner, router, consumed_rule_keys)
      when is_atom(owner) and is_list(router) and is_list(consumed_rule_keys) do
    via = router |> Keyword.get(:via, []) |> List.wrap()

    if Enum.any?(via, &module_atom?/1) do
      case compile_via(via, consumed_rule_keys) do
        {:ok, normalized_via, adapters} ->
          router
          |> Keyword.put(:via, normalized_via)
          |> Keyword.put(@compiled_key, adapters)

        {:error, reason} ->
          raise ArgumentError,
                "invalid Spectre agent definition #{inspect(owner)}: #{format_reason(reason)}"
      end
    else
      router
    end
  end

  @doc false
  @spec compiled_adapters(keyword()) :: %{optional(atom()) => entry()}
  def compiled_adapters(router) when is_list(router) do
    case Keyword.get(router, @compiled_key, %{}) do
      adapters when is_map(adapters) -> adapters
      _invalid -> %{}
    end
  end

  @doc false
  @spec validate_router(keyword()) :: :ok | {:error, term()}
  def validate_router(router) when is_list(router) do
    adapters = compiled_adapters(router)
    known = MapSet.new(@built_in_steps ++ Map.keys(adapters))

    with :ok <- validate_compiled_map(Keyword.get(router, @compiled_key, %{})) do
      validate_via_steps(Keyword.get(router, :via, []), known)
    end
  end

  def validate_router(router), do: {:error, {:invalid_router, router}}

  @doc false
  @spec validate_definition(Definition.t()) :: :ok | {:error, term()}
  def validate_definition(%Definition{} = definition) do
    adapters = compiled_adapters(definition.router)
    adapter_ids = Map.keys(adapters)
    scope = if definition.kind == :skill, do: {:skill, definition.id}, else: :agent

    with :ok <- validate_rule_set(definition.rules, definition.kind, scope, adapter_ids) do
      validate_mounted_rule_sets(definition, adapter_ids)
    end
  end

  @doc false
  @spec preflight_rule_data!(map(), Definition.scope()) :: map()
  def preflight_rule_data!(%{via: via, opts: opts} = rule, scope)
      when is_list(via) and is_list(opts) do
    via
    |> Enum.filter(&(ordinary_atom?(&1) and &1 not in @built_in_steps))
    |> Enum.uniq()
    |> Enum.each(&preflight_rule_value!(opts, rule, scope, &1))

    rule
  end

  def preflight_rule_data!(rule, _scope), do: rule

  @spec preflight_rule_value!(keyword(), map(), Definition.scope(), atom()) :: :ok
  defp preflight_rule_value!(opts, rule, scope, id) do
    case Keyword.fetch(opts, id) do
      {:ok, value} -> validate_preflight_value!(value, rule, scope, id)
      :error -> :ok
    end
  end

  @spec validate_preflight_value!(term(), map(), Definition.scope(), atom()) :: :ok
  defp validate_preflight_value!(value, rule, scope, id) do
    label = Map.get(rule, :label)

    case structural_rule_data(value, rule, id, scope, label) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "invalid router Adapter rule data for #{inspect(id)} " <>
                "on #{inspect({scope, label})}: #{inspect(reason)}"
    end
  end

  @doc false
  @spec dependency_report(Definition.t(), [atom()] | nil) :: %{
          warnings: [map()],
          errors: [map()]
        }
  def dependency_report(%Definition{} = definition, adapter_ids \\ nil) do
    adapter_ids = adapter_ids || Map.keys(compiled_adapters(definition.router))

    definition
    |> scoped_rule_sets()
    |> Enum.flat_map(fn {scope, rules} ->
      Enum.flat_map(rules, &dependency_finding(&1, scope, adapter_ids))
    end)
    |> Enum.reduce(%{warnings: [], errors: []}, fn finding, report ->
      key = if finding.status == :warning, do: :warnings, else: :errors
      Map.update!(report, key, &[finding | &1])
    end)
    |> then(fn report ->
      %{
        warnings: Enum.reverse(report.warnings),
        errors: Enum.reverse(report.errors)
      }
    end)
  end

  @doc false
  @spec format_reason(term()) :: String.t()
  def format_reason({:unknown_router_step, step}),
    do: "unknown router via step #{inspect(step)}"

  def format_reason({:invalid_router_adapter, module, reason}),
    do: "invalid router Adapter #{inspect(module)}: #{inspect(reason)}"

  def format_reason({:duplicate_router_adapter_id, id}),
    do: "duplicate router Adapter id #{inspect(id)}"

  def format_reason({:reserved_router_adapter_id, id}),
    do: "reserved router Adapter id #{inspect(id)}"

  def format_reason(reason), do: inspect(reason)

  @spec evaluate_opts!(Macro.t(), Macro.Env.t()) :: keyword()
  defp evaluate_opts!(opts_ast, env) do
    expanded = Macro.prewalk(opts_ast, &Macro.expand(&1, env))
    {opts, _binding} = Code.eval_quoted(expanded, [], env)

    if Keyword.keyword?(opts),
      do: opts,
      else: raise(ArgumentError, "Spectre.Router.Adapter options must be a keyword list")
  end

  @spec descriptor_from_opts(keyword(), [atom()]) :: {:ok, descriptor()} | {:error, term()}
  defp descriptor_from_opts(opts, reserved_ids) do
    unknown = Keyword.keys(opts) -- [:id, :accept, :margin, :strength]
    id = Keyword.get(opts, :id)
    accept = Keyword.get(opts, :accept, 0.0)
    margin = Keyword.get(opts, :margin)
    strength = Keyword.get(opts, :strength, :weak)

    with :ok <- validate_descriptor_options(unknown),
         :ok <- validate_descriptor_id(id, reserved_ids),
         {:ok, accept} <- validate_probability(accept, :invalid_accept),
         {:ok, margin} <- validate_optional_probability(margin, :invalid_margin),
         :ok <- validate_descriptor_strength(strength) do
      {:ok,
       %{
         contract: @contract_version,
         id: id,
         accept: accept,
         margin: margin,
         strength: strength
       }}
    end
  end

  @spec validate_descriptor_options([atom()]) :: :ok | {:error, term()}
  defp validate_descriptor_options([]), do: :ok
  defp validate_descriptor_options(unknown), do: {:error, {:unknown_options, unknown}}

  @spec validate_descriptor_id(term(), [atom()]) :: :ok | {:error, term()}
  defp validate_descriptor_id(id, reserved_ids) do
    cond do
      not ordinary_atom?(id) -> {:error, {:invalid_id, id}}
      id in reserved_ids -> {:error, {:reserved_id, id}}
      true -> :ok
    end
  end

  @spec validate_probability(term(), atom()) :: {:ok, float()} | {:error, term()}
  defp validate_probability(value, error) do
    if probability?(value), do: {:ok, as_float(value)}, else: {:error, {error, value}}
  end

  @spec validate_optional_probability(term(), atom()) ::
          {:ok, float() | nil} | {:error, term()}
  defp validate_optional_probability(nil, _error), do: {:ok, nil}
  defp validate_optional_probability(value, error), do: validate_probability(value, error)

  @spec validate_descriptor_strength(term()) :: :ok | {:error, term()}
  defp validate_descriptor_strength(strength) when strength in @strengths, do: :ok
  defp validate_descriptor_strength(strength), do: {:error, {:invalid_strength, strength}}

  @spec compile_via([term()], [atom()]) ::
          {:ok, [atom()], %{optional(atom()) => entry()}} | {:error, term()}
  defp compile_via(via, consumed_rule_keys) do
    reserved_ids = Enum.uniq(@built_in_steps ++ consumed_rule_keys)

    with {:ok, adapters} <- collect_adapters(via, reserved_ids),
         {:ok, normalized} <- normalize_via(via, adapters) do
      {:ok, normalized, adapters}
    end
  end

  @spec collect_adapters([term()], [atom()]) ::
          {:ok, %{optional(atom()) => entry()}} | {:error, term()}
  defp collect_adapters(via, reserved_ids) do
    via
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{}}, &collect_adapter(&1, &2, reserved_ids))
  end

  @spec collect_adapter({term(), non_neg_integer()}, {:ok, map()}, [atom()]) ::
          {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp collect_adapter({module, order}, {:ok, adapters}, reserved_ids) do
    if module_atom?(module) do
      load_adapter_entry(module, order, adapters, reserved_ids)
    else
      {:cont, {:ok, adapters}}
    end
  end

  @spec load_adapter_entry(module(), non_neg_integer(), map(), [atom()]) ::
          {:cont, {:ok, map()}} | {:halt, {:error, term()}}
  defp load_adapter_entry(module, order, adapters, reserved_ids) do
    case load_descriptor(module, reserved_ids) do
      {:ok, %{id: id}} when is_map_key(adapters, id) ->
        {:halt, {:error, {:duplicate_router_adapter_id, id}}}

      {:ok, descriptor} ->
        entry = %{id: descriptor.id, module: module, descriptor: descriptor, order: order}
        {:cont, {:ok, Map.put(adapters, descriptor.id, entry)}}

      {:error, reason} ->
        {:halt, {:error, {:invalid_router_adapter, module, reason}}}
    end
  end

  @spec load_descriptor(module(), [atom()]) :: {:ok, descriptor()} | {:error, term()}
  defp load_descriptor(module, reserved_ids) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__spectre_router_adapter__, 0),
         true <- function_exported?(module, :evaluate, 1),
         {:ok, descriptor} <- safe_descriptor(module),
         {:ok, descriptor} <- validate_descriptor(descriptor, reserved_ids) do
      {:ok, descriptor}
    else
      false -> {:error, :module_or_callback_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @spec safe_descriptor(module()) :: {:ok, term()} | {:error, term()}
  defp safe_descriptor(module) do
    {:ok, module.__spectre_router_adapter__()}
  rescue
    exception -> {:error, {:descriptor_exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {:descriptor_failure, kind, failure_class(reason)}}
  end

  @spec validate_descriptor(term(), [atom()]) :: {:ok, descriptor()} | {:error, term()}
  defp validate_descriptor(descriptor, reserved_ids) when is_map(descriptor) do
    keys = Map.keys(descriptor)

    with true <- Enum.sort(keys) == Enum.sort(@descriptor_keys),
         @contract_version <- Map.get(descriptor, :contract),
         opts <- Map.take(descriptor, [:id, :accept, :margin, :strength]) |> Map.to_list(),
         {:ok, normalized} <- descriptor_from_opts(opts, reserved_ids) do
      {:ok, normalized}
    else
      false ->
        {:error, {:invalid_descriptor_keys, keys}}

      contract when is_integer(contract) ->
        {:error, {:unsupported_contract, contract, @contract_version}}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_descriptor}
    end
  end

  defp validate_descriptor(descriptor, _reserved_ids),
    do: {:error, {:invalid_descriptor, value_class(descriptor)}}

  @spec normalize_via([term()], map()) :: {:ok, [atom()]} | {:error, term()}
  defp normalize_via(via, adapters) do
    module_ids = Map.new(adapters, fn {id, entry} -> {entry.module, id} end)
    known = MapSet.new(@built_in_steps ++ Map.keys(adapters))

    via
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, normalized} ->
      step = Map.get(module_ids, step, step)

      if is_atom(step) and MapSet.member?(known, step),
        do: {:cont, {:ok, [step | normalized]}},
        else: {:halt, {:error, {:unknown_router_step, step}}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  @spec validate_compiled_map(term()) :: :ok | {:error, term()}
  defp validate_compiled_map(adapters) when is_map(adapters) do
    if Enum.all?(adapters, &valid_entry?/1),
      do: :ok,
      else: {:error, :invalid_router_adapter_map}
  end

  defp validate_compiled_map(_adapters), do: {:error, :invalid_router_adapter_map}

  @spec valid_entry?({term(), term()}) :: boolean()
  defp valid_entry?({id, %{id: id, module: module, descriptor: descriptor, order: order} = entry}) do
    with true <- Enum.sort(Map.keys(entry)) == [:descriptor, :id, :module, :order],
         true <- ordinary_atom?(id),
         true <- module_atom?(module),
         true <- is_integer(order) and order >= 0,
         {:ok, %{id: ^id}} <- validate_descriptor(descriptor, @built_in_steps) do
      true
    else
      _invalid -> false
    end
  end

  defp valid_entry?(_entry), do: false

  @spec validate_via_steps(term(), MapSet.t()) :: :ok | {:error, term()}
  defp validate_via_steps(via, known) when is_list(via) do
    case Enum.find(via, &(not is_atom(&1) or not MapSet.member?(known, &1))) do
      nil -> :ok
      step -> {:error, {:unknown_router_step, step}}
    end
  end

  defp validate_via_steps(via, _known), do: {:error, {:invalid_router_via, via}}

  @spec validate_rule_set([map()], atom(), Definition.scope(), [atom()]) :: :ok | {:error, term()}
  defp validate_rule_set(rules, kind, scope, adapter_ids) when is_list(rules) do
    Enum.reduce_while(rules, :ok, fn rule, :ok ->
      case validate_rule(rule, kind, scope, adapter_ids) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_mounted_rule_sets(Definition.t(), [atom()]) :: :ok | {:error, term()}
  defp validate_mounted_rule_sets(%Definition{kind: :skill}, _adapter_ids), do: :ok

  defp validate_mounted_rule_sets(%Definition{skills: mounts}, adapter_ids) do
    Enum.reduce_while(mounts, :ok, fn mount, :ok ->
      skill = Definition.fetch!(mount.module)

      case validate_rule_set(skill.rules, :agent, {:skill, mount.id}, adapter_ids) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_rule(map(), atom(), Definition.scope(), [atom()]) :: :ok | {:error, term()}
  defp validate_rule(rule, kind, scope, adapter_ids) when is_map(rule) do
    via = Map.get(rule, :via, [])
    label = Map.get(rule, :label)

    with :ok <- validate_rule_via(via, kind, scope, label, adapter_ids) do
      validate_rule_data(rule, scope, label, adapter_ids)
    end
  end

  @spec validate_rule_via(term(), atom(), Definition.scope(), atom(), [atom()]) ::
          :ok | {:error, term()}
  defp validate_rule_via(via, _kind, _scope, _label, _adapter_ids) when via == [], do: :ok

  defp validate_rule_via(via, kind, scope, label, adapter_ids) when is_list(via) do
    invalid_index = Enum.find_index(via, &(not ordinary_atom?(&1)))

    cond do
      not is_nil(invalid_index) ->
        {:error, {:invalid_router_rule_via, scope, label, Enum.at(via, invalid_index)}}

      control = Enum.find(via, &(&1 in @control_steps)) ->
        {:error, {:router_control_step_in_rule_via, scope, label, control}}

      kind == :skill ->
        :ok

      true ->
        validate_resolvable_rule_via(via, scope, label, adapter_ids)
    end
  end

  defp validate_rule_via(via, _kind, scope, label, _adapter_ids),
    do: {:error, {:invalid_router_rule_via, scope, label, via}}

  @spec validate_resolvable_rule_via([atom()], Definition.scope(), atom(), [atom()]) ::
          :ok | {:error, term()}
  defp validate_resolvable_rule_via(via, scope, label, adapter_ids) do
    case dependency_status(via, adapter_ids) do
      :ok ->
        :ok

      {:error, unresolved} ->
        {:error, {:unresolvable_router_rule, scope, label, unresolved}}

      {:warning, unresolved} ->
        IO.warn(
          "router rule #{inspect({scope, label})} ignores unavailable providers #{inspect(unresolved)}"
        )

        :ok
    end
  end

  @spec scoped_rule_sets(Definition.t()) :: [{Definition.scope(), [map()]}]
  defp scoped_rule_sets(%Definition{kind: :skill} = definition) do
    [{{:skill, definition.id}, definition.rules}]
  end

  defp scoped_rule_sets(%Definition{} = definition) do
    own = [{:agent, definition.rules}]

    mounted =
      Enum.map(definition.skills, fn mount ->
        skill = Definition.fetch!(mount.module)
        {{:skill, mount.id}, skill.rules}
      end)

    own ++ mounted
  end

  @spec dependency_finding(map(), Definition.scope(), [atom()]) :: [map()]
  defp dependency_finding(rule, scope, adapter_ids) do
    via = Map.get(rule, :via, [])

    case dependency_status(via, adapter_ids) do
      :ok ->
        []

      {status, unresolved} ->
        [
          %{
            status: status,
            scope: scope,
            label: Map.get(rule, :label),
            unresolved: unresolved
          }
        ]
    end
  end

  @spec dependency_status([atom()], [atom()]) ::
          :ok | {:warning, [atom()]} | {:error, [atom()]}
  defp dependency_status([], _adapter_ids), do: :ok

  defp dependency_status(via, adapter_ids) do
    known = MapSet.new(@built_in_steps ++ adapter_ids)
    {resolved, unresolved} = Enum.split_with(via, &MapSet.member?(known, &1))

    cond do
      unresolved == [] -> :ok
      resolved == [] -> {:error, unresolved}
      true -> {:warning, unresolved}
    end
  end

  @spec validate_rule_data(map(), Definition.scope(), atom(), [atom()]) ::
          :ok | {:error, term()}
  defp validate_rule_data(rule, scope, label, adapter_ids) do
    opts = Map.get(rule, :opts, [])

    if Keyword.keyword?(opts) do
      Enum.reduce_while(adapter_ids, :ok, fn id, :ok ->
        validate_adapter_rule_data(opts, rule, id, scope, label)
      end)
    else
      {:error, {:invalid_router_rule_opts, scope, label}}
    end
  end

  @spec validate_adapter_rule_data(keyword(), map(), atom(), Definition.scope(), atom()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp validate_adapter_rule_data(opts, rule, id, scope, label) do
    if Keyword.has_key?(opts, id) do
      validate_adapter_rule_value(Keyword.fetch!(opts, id), rule, id, scope, label)
    else
      {:cont, :ok}
    end
  end

  @spec validate_adapter_rule_value(term(), map(), atom(), Definition.scope(), atom()) ::
          {:cont, :ok} | {:halt, {:error, term()}}
  defp validate_adapter_rule_value(value, rule, id, scope, label) do
    case structural_rule_data(value, rule, id, scope, label) do
      :ok ->
        {:cont, :ok}

      {:error, reason} ->
        {:halt, {:error, {:invalid_router_adapter_rule_data, id, scope, label, reason}}}
    end
  end

  @spec structural_rule_data(term(), map(), atom(), Definition.scope(), atom()) ::
          :ok | {:error, term()}
  defp structural_rule_data(value, rule, id, scope, label) do
    case Data.structural(value,
           owner: Map.get(rule, :owner),
           path: [:routing, :adapter, id, scope, label]
         ) do
      {:ok, _lowered} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec ordinary_atom?(term()) :: boolean()
  defp ordinary_atom?(value) do
    is_atom(value) and value not in [nil, true, false] and not module_atom?(value)
  end

  @spec module_atom?(term()) :: boolean()
  defp module_atom?(value) when is_atom(value) do
    value |> Atom.to_string() |> String.starts_with?("Elixir.")
  end

  defp module_atom?(_value), do: false

  @spec probability?(term()) :: boolean()
  defp probability?(value) when is_integer(value), do: value >= 0 and value <= 1
  defp probability?(value) when is_float(value), do: value >= 0.0 and value <= 1.0
  defp probability?(_value), do: false

  @spec as_float(number()) :: float()
  defp as_float(value) when is_integer(value), do: value / 1
  defp as_float(value) when is_float(value), do: value

  @spec failure_class(term()) :: atom()
  defp failure_class(value) when is_atom(value), do: value
  defp failure_class(value) when is_tuple(value), do: :tuple
  defp failure_class(value) when is_map(value), do: :map
  defp failure_class(value) when is_list(value), do: :list
  defp failure_class(_value), do: :other

  @spec value_class(term()) :: atom()
  defp value_class(value) when is_list(value), do: :list
  defp value_class(value) when is_tuple(value), do: :tuple
  defp value_class(value) when is_atom(value), do: :atom
  defp value_class(value) when is_binary(value), do: :binary
  defp value_class(value) when is_number(value), do: :number
  defp value_class(_value), do: :other

  @spec format_descriptor_error(module(), term()) :: String.t()
  defp format_descriptor_error(module, reason) do
    "invalid Spectre.Router.Adapter descriptor for #{inspect(module)}: #{inspect(reason)}"
  end
end
