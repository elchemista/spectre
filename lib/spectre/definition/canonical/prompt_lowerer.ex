defmodule Spectre.Definition.Canonical.PromptLowerer do
  @moduledoc false

  alias Spectre.Definition
  alias Spectre.Definition.Canonical.Data
  alias Spectre.Prompt
  alias Spectre.Prompt.Fragment
  alias Spectre.Prompt.Operation

  @doc false
  @spec lower(Definition.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def lower(%Definition{} = definition, opts \\ []) do
    with {:ok, entries} <- collect_entries(definition) do
      lower_entries(entries, definition, opts)
    end
  rescue
    exception in ArgumentError ->
      {:error, {:invalid_compiled_prompt, Exception.message(exception)}}
  end

  @spec collect_entries(Definition.t()) :: {:ok, [{Operation.t(), map()}]} | {:error, term()}
  defp collect_entries(definition) do
    entries =
      definition_entries(definition) ++
        rule_entries(definition.rules) ++
        policy_entries(definition.policies) ++ fail_entries(definition.config)

    {:ok, Enum.uniq_by(entries, &entry_identity/1)}
  end

  @spec definition_entries(Definition.t()) :: [{Operation.t(), map()}]
  defp definition_entries(definition) do
    Enum.map(definition.injections, fn operation ->
      {operation, %{declaration: :definition, owner: definition.owner}}
    end)
  end

  @spec rule_entries([map()]) :: [{Operation.t(), map()}]
  defp rule_entries(rules) do
    Enum.flat_map(rules, fn rule ->
      label = Map.get(rule, :label)

      flow =
        Enum.map(Map.get(rule, :injections, []), fn operation ->
          {operation, %{declaration: :flow, label: label}}
        end)

      handler = handler_entries(rule)
      flow ++ handler
    end)
  end

  @spec handler_entries(map()) :: [{Operation.t(), map()}]
  defp handler_entries(%{label: label, handler: {kind, prompt, opts}})
       when kind in [:ask, :reason, :act, :reply] and is_list(opts) do
    scope = {:handler, label}
    base = {static_operation({:handler, label, prompt}, prompt, scope), %{declaration: :handler}}

    injected =
      opts
      |> Keyword.get(:inject)
      |> Operation.normalize(scope)
      |> Enum.map(&{&1, %{declaration: :handler_injection, label: label}})

    [base | injected]
  end

  defp handler_entries(_rule), do: []

  @spec policy_entries(map()) :: [{Operation.t(), map()}]
  defp policy_entries(policies) do
    Enum.flat_map(policies, fn {name, policy} ->
      request = policy_prompt_entry(name, :request, Map.get(policy, :request))

      otherwise =
        case Map.get(policy, :otherwise) do
          {:ask, prompt} -> policy_prompt_entry(name, :otherwise, prompt)
          _other -> []
        end

      request ++ otherwise
    end)
  end

  @spec policy_prompt_entry(atom(), atom(), term()) :: [{Operation.t(), map()}]
  defp policy_prompt_entry(_name, _kind, nil), do: []

  defp policy_prompt_entry(name, kind, prompt) do
    scope = {:policy, name}
    id = {:policy, name, kind, prompt}
    operation = static_operation(id, prompt, scope)
    [{operation, %{declaration: :policy, policy: name, prompt: prompt}}]
  end

  @spec fail_entries(keyword()) :: [{Operation.t(), map()}]
  defp fail_entries(config) do
    case Keyword.get(config, :fail) do
      {prompt, _opts} ->
        operation = static_operation({:agent_failure, prompt}, prompt, :agent_failure)
        [{operation, %{declaration: :agent_failure, prompt: prompt}}]

      _other ->
        []
    end
  end

  @spec entry_identity({Operation.t(), map()}) :: term()
  defp entry_identity({operation, provenance}) do
    {
      operation.scope,
      operation.id,
      operation.source,
      operation.target,
      operation.position,
      operation.source_line,
      Map.get(provenance, :declaration)
    }
  end

  @spec static_operation(term(), atom() | String.t(), term()) :: Operation.t()
  defp static_operation(id, prompt, scope) do
    %Operation{
      id: id,
      source: {:prompt, prompt},
      scope: scope,
      target: :task,
      position: :end,
      condition: nil,
      source_line: nil,
      required?: true,
      trust: :instruction,
      opts: []
    }
  end

  @spec lower_entries([{Operation.t(), map()}], Definition.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  defp lower_entries(entries, definition, opts) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, fragments} ->
      case lower_entry(entry, definition, opts) do
        {:ok, fragment} -> {:cont, {:ok, [fragment_data(fragment) | fragments]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fragments} -> {:ok, Enum.reverse(fragments)}
      {:error, _reason} = error -> error
    end
  end

  @spec lower_entry({Operation.t(), map()}, Definition.t(), keyword()) ::
          {:ok, Fragment.t()} | {:error, term()}
  defp lower_entry({%Operation{} = operation, declaration}, definition, _opts) do
    with {:ok, source} <- lower_source(operation, definition, declaration),
         {:ok, condition_ref} <- lower_condition(operation.condition, definition.owner),
         {:ok, provenance} <-
           Data.lower(
             Map.merge(source.provenance, %{
               declaration: declaration,
               owner_ref: Data.module_ref(definition.owner),
               required?: operation.required?,
               source_line: operation.source_line
             })
           ) do
      Fragment.canonical(%{
        id: operation.id,
        content: source.content,
        scope: operation.scope,
        target: operation.target,
        position: operation.position,
        source: source.reference,
        trust: operation.trust,
        placeholders: source.placeholders,
        provenance: provenance,
        visibility: Keyword.get(operation.opts, :visibility, :private),
        requested_priority: Keyword.get(operation.opts, :priority, :normal),
        granted_priority: Keyword.get(operation.opts, :priority, :normal),
        budget_class: Keyword.get(operation.opts, :budget_class, :standard),
        token_cap: Keyword.get(operation.opts, :token_cap),
        condition_ref: condition_ref
      })
    end
  end

  @spec lower_source(Operation.t(), Definition.t(), map()) :: {:ok, map()} | {:error, term()}
  defp lower_source(%Operation{source: {:prompt, prompt}} = operation, definition, declaration) do
    policy = Map.get(declaration, :policy)
    logical_path = logical_path(prompt, policy)

    prompt_opts =
      if policy do
        [prompt_scope: :agent, policy_prompt?: true, policy: policy]
      else
        [prompt_scope: :agent]
      end

    case Prompt.resolve(definition.owner, prompt, %{}, prompt_opts) do
      {:ok, path} ->
        lower_asset(path, logical_path)

      {:error, {:missing_prompt, _path}} ->
        {:ok,
         %{
           content: "",
           placeholders: %{},
           provenance: %{kind: :compiled_asset, logical_path: logical_path, status: :missing},
           reference: %{kind: :compiled_asset, logical_path: logical_path}
         }}

      {:error, reason} ->
        {:error, {:compiled_prompt_resolution_failed, operation.id, reason}}
    end
  end

  defp lower_source(
         %Operation{source: {:provider, module, function}, target: :context},
         _definition,
         _declaration
       ) do
    reference = Data.callback_ref(module, function, [0, 1, 2])

    {:ok,
     %{
       content: nil,
       placeholders: %{},
       provenance: %{kind: :compiled_provider},
       reference: reference
     }}
  end

  defp lower_source(%Operation{} = operation, _definition, _declaration),
    do: {:error, {:unsupported_compiled_prompt_source, operation.id, operation.source}}

  @spec lower_asset(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defp lower_asset(path, logical_path) do
    with {:ok, content} <- File.read(path),
         {:ok, closed, placeholders} <- Fragment.close_template(content) do
      {:ok,
       %{
         content: closed,
         placeholders: placeholders,
         provenance: %{
           kind: :compiled_asset,
           logical_path: logical_path,
           status: :snapshotted,
           source_digest: sha256(content)
         },
         reference: %{kind: :compiled_asset, logical_path: logical_path}
       }}
    else
      {:error, :executable_prompt_template} ->
        {:error, {:executable_compiled_prompt, logical_path}}

      {:error, reason} ->
        {:error, {:compiled_prompt_read_failed, logical_path, reason}}
    end
  end

  @spec lower_condition(term(), module()) :: {:ok, map() | nil} | {:error, term()}
  defp lower_condition(nil, _owner), do: {:ok, nil}

  defp lower_condition({module, function}, _owner)
       when is_atom(module) and is_atom(function),
       do: {:ok, Data.callback_ref(module, function, [1, 2])}

  defp lower_condition(condition, owner) when is_function(condition),
    do: Data.lower(condition, owner: owner, path: [:prompt_condition])

  defp lower_condition(condition, _owner),
    do: {:error, {:invalid_compiled_prompt_condition, condition}}

  @spec logical_path(atom() | String.t(), atom() | nil) :: String.t()
  defp logical_path(prompt, policy)
       when is_atom(prompt) and is_atom(policy) and not is_nil(policy),
       do: Path.join(["policies", Atom.to_string(policy), "#{prompt}.text.heex"])

  defp logical_path(prompt, _policy) when is_atom(prompt), do: "#{prompt}.text.heex"
  defp logical_path(prompt, _policy) when is_binary(prompt), do: prompt

  @spec fragment_data(Fragment.t()) :: map()
  defp fragment_data(%Fragment{} = fragment) do
    fragment
    |> Fragment.canonical_data()
    |> Map.put(:digest, fragment.digest)
  end

  @spec sha256(binary()) :: String.t()
  defp sha256(content) do
    content
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
