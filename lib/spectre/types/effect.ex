defmodule Spectre.Effect do
  @moduledoc """
  Runtime or host work represented as data.

  Effects generalize the old pending-action shape. An action is now one effect
  kind; future capabilities such as retrieval or search can use the same
  contract without changing turn decisions. Action effects carry their owning
  module and mounted scope as first-class fields; payload data cannot override
  that trusted runtime origin.
  """

  defstruct [
    :id,
    :idempotency_key,
    :kind,
    :name,
    :owner,
    :scope,
    :run_id,
    :mode,
    :policy,
    :result,
    :error,
    args: %{},
    status: :pending,
    payload: %{},
    metadata: %{}
  ]

  @type status ::
          :pending | :waiting_policy | :approved | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: term(),
          idempotency_key: String.t(),
          kind: atom(),
          name: atom() | String.t() | nil,
          owner: module() | nil,
          scope: Spectre.Definition.scope() | nil,
          run_id: String.t() | nil,
          args: map(),
          status: status(),
          mode: atom() | nil,
          policy: term(),
          result: term(),
          error: term(),
          payload: map(),
          metadata: map()
        }

  @doc """
  Builds a pending effect outside a routed Skill context.

  Effects staged through this generic compatibility API default to Agent scope.
  Routed actions should use `stage_action/3` so ownership cannot be omitted.
  """
  @spec stage(map() | struct()) :: t()
  def stage(attrs) when is_map(attrs) do
    attrs
    |> build()
    |> put_origin(nil, :agent)
  end

  @doc """
  Builds a pending action effect with a trusted owner and scope.

  Explicit origin arguments replace any owner or scope supplied by the action
  payload. Both deterministic DSL actions and model-planned actions use this
  constructor.
  """
  @spec stage_action(map() | struct(), module(), Spectre.Definition.scope()) :: t()
  def stage_action(attrs, owner, scope)
      when is_map(attrs) and is_atom(owner) and not is_nil(owner) do
    attrs
    |> normalize_map()
    |> Map.put(:kind, :action)
    |> build()
    |> put_origin(owner, scope)
  end

  @doc """
  Restores a persisted effect without inventing a missing scope.

  Durable codecs use this behavior for legacy state. An unscoped restored
  effect remains observable but must be rejected by the execution boundary.
  """
  @spec restore(map() | struct()) :: t()
  def restore(attrs) when is_map(attrs), do: build(attrs)

  @spec build(map() | struct()) :: t()
  defp build(attrs) do
    attrs = normalize_map(attrs)
    payload = effect_payload(attrs)
    owner = origin_attr(attrs, payload, :owner)
    scope = origin_attr(attrs, payload, :scope)
    id = attr_or(attrs, :id, Spectre.Identity.uuid7())

    %__MODULE__{
      id: id,
      idempotency_key: attr_or(attrs, :idempotency_key, Spectre.Identity.idempotency_key(id)),
      kind: attr_or(attrs, :kind, :action),
      name:
        normalize_name(
          get_attr(attrs, :name),
          Map.get(payload, :selected_tool),
          Map.get(payload, :al)
        ),
      owner: owner,
      scope: scope,
      run_id: get_attr(attrs, :run_id),
      args: attr_or(attrs, :args, %{}),
      status: attr_or(attrs, :status, :pending),
      mode: get_attr(attrs, :mode),
      policy: get_attr(attrs, :policy),
      result: get_attr(attrs, :result),
      error: get_attr(attrs, :error),
      payload: drop_origin(payload),
      metadata: attr_or(attrs, :metadata, %{})
    }
  end

  @doc """
  Associates an Effect with its owning Instance Run.

  Extension-owned Effect builders should use
  `Spectre.Context.lifecycle_run_id/1` and bind the returned value before
  staging. Passing `nil` preserves the stateless and Session compatibility
  lifecycle.
  """
  @spec bind_run(t(), String.t() | nil) :: t()
  def bind_run(%__MODULE__{} = effect, run_id)
      when is_nil(run_id) or (is_binary(run_id) and run_id != "") do
    %{effect | run_id: run_id}
  end

  @doc """
  Marks an effect as waiting on a policy gate.
  """
  @spec waiting_policy(t(), term()) :: t()
  def waiting_policy(%__MODULE__{} = effect, policy) when not is_nil(policy) do
    %{effect | status: :waiting_policy, policy: policy}
  end

  @doc """
  Marks a policy-gated effect as approved without executing it.

  Approval is a durable state transition. The host may execute the effect only
  after the approved state has been persisted.
  """
  @spec approve(t()) :: t()
  def approve(%__MODULE__{status: :waiting_policy} = effect) do
    %{effect | status: :approved}
  end

  def approve(%__MODULE__{} = effect), do: effect

  @doc """
  Marks an effect as completed with a result.
  """
  @spec complete(t(), term()) :: t()
  def complete(%__MODULE__{} = effect, result) do
    metadata = Map.put(effect.metadata, :result_evidence, result_evidence_for(effect))
    %{effect | status: :completed, result: result, error: nil, metadata: metadata}
  end

  @doc "Returns the non-authoritative trust and provenance attached to a result."
  @spec result_evidence(t()) :: map()
  def result_evidence(%__MODULE__{} = effect) do
    Map.get(effect.metadata, :result_evidence, %{
      trust: :untrusted,
      provenance: %{source: :legacy_effect_result},
      authenticity: %{}
    })
  end

  defp result_evidence_for(%__MODULE__{} = effect) do
    %{
      trust: :untrusted,
      provenance: %{
        source: if(effect.kind == :action, do: :action_provider, else: :effect_provider),
        effect_id: effect.id,
        kind: effect.kind,
        name: effect.name,
        via: via(effect),
        schema_hash: schema_hash(effect)
      },
      authenticity: %{status: :unverified}
    }
  end

  @doc """
  Marks an effect as failed with an error.
  """
  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = effect, error) do
    %{effect | status: :failed, error: error}
  end

  @doc """
  Marks an effect as cancelled.
  """
  @spec cancel(t(), term()) :: t()
  def cancel(%__MODULE__{} = effect, reason \\ nil) do
    metadata =
      if is_nil(reason),
        do: effect.metadata,
        else: Map.put(effect.metadata, :cancel_reason, reason)

    %{effect | status: :cancelled, metadata: metadata}
  end

  @doc """
  Returns the stable key used for protection and dispatch checks.
  """
  @spec effect_key(t() | map() | atom() | String.t()) :: atom() | String.t() | nil
  def effect_key(%__MODULE__{name: name})
      when (is_atom(name) and not is_nil(name)) or is_binary(name),
      do: name

  def effect_key(%__MODULE__{payload: %{selected_tool: tool}}) when is_binary(tool), do: tool
  def effect_key(%{name: name}) when is_atom(name) or is_binary(name), do: name
  def effect_key(%{selected_tool: tool}) when is_binary(tool), do: tool
  def effect_key(name) when is_atom(name) or is_binary(name), do: name
  def effect_key(_other), do: nil

  @doc """
  Returns the stable key that an action adapter can use to deduplicate retries.
  """
  @spec idempotency_key(t()) :: String.t()
  def idempotency_key(%__MODULE__{idempotency_key: key}) when is_binary(key), do: key

  def idempotency_key(%__MODULE__{id: id}), do: Spectre.Identity.idempotency_key(id)

  @doc """
  Returns whether an effect is ready for its host capability boundary.

  Policy-gated effects become executable only after their durable
  `:waiting_policy -> :approved` transition.
  """
  @spec executable?(t()) :: boolean()
  def executable?(%__MODULE__{status: status}), do: status in [:pending, :approved]

  @doc """
  Returns whether an effect reached a terminal lifecycle state.
  """
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: status in [:completed, :failed, :cancelled]

  @doc """
  Normalizes a terminal effect into a host-facing outcome.

  Older adapters may have stored `{:ok, value}` or `{:error, reason}` inside
  a completed effect. These shapes are flattened for backwards compatibility.
  Non-terminal effects return `nil`.
  """
  @type outcome :: {:ok, term()} | {:error, term()} | {:cancelled, term()} | nil
  @spec outcome(t()) :: outcome()
  def outcome(%__MODULE__{status: :completed, result: {:ok, result}}), do: {:ok, result}
  def outcome(%__MODULE__{status: :completed, result: {:error, reason}}), do: {:error, reason}
  def outcome(%__MODULE__{status: :completed, result: result}), do: {:ok, result}
  def outcome(%__MODULE__{status: :failed, error: reason}), do: {:error, reason}

  def outcome(%__MODULE__{status: :cancelled, metadata: metadata}),
    do: {:cancelled, Map.get(metadata, :cancel_reason)}

  def outcome(%__MODULE__{}), do: nil

  @doc """
  Returns hooks attached to an effect payload.
  """
  @spec hooks(t()) :: [map()]
  def hooks(%__MODULE__{payload: payload}), do: Map.get(payload, :hooks, [])

  @doc """
  Returns the selected tool encoded in an action effect payload.
  """
  @spec selected_tool(t()) :: String.t() | nil
  def selected_tool(%__MODULE__{payload: payload}), do: Map.get(payload, :selected_tool)

  @doc """
  Returns the provider identifier encoded in an action effect.

  Effects written before provider separation default to the local Elixir
  provider.
  """
  @spec via(t()) :: Spectre.Action.provider_ref()
  def via(%__MODULE__{payload: payload}),
    do: Map.get(payload, :via) || Map.get(payload, "via") || :local

  @doc """
  Returns the planner that produced the action, when present.
  """
  @spec planned_by(t()) :: module() | atom() | nil
  def planned_by(%__MODULE__{payload: payload}),
    do: Map.get(payload, :planned_by) || Map.get(payload, "planned_by")

  @doc """
  Returns the approved provider schema hash, when present.
  """
  @spec schema_hash(t()) :: String.t() | nil
  def schema_hash(%__MODULE__{payload: payload}),
    do: Map.get(payload, :schema_hash) || Map.get(payload, "schema_hash")

  @doc """
  Returns the Action Language text encoded in an action effect payload.
  """
  @spec al(t()) :: String.t() | nil
  def al(%__MODULE__{payload: payload}), do: Map.get(payload, :al)

  @doc """
  Returns the source encoded in an effect payload.
  """
  @spec source(t()) :: atom() | nil
  def source(%__MODULE__{payload: payload}), do: Map.get(payload, :source)

  @doc """
  Returns the module that owned the route which staged the effect.

  Legacy persisted effects may not carry an owner and return `nil`.
  """
  @spec owner(t()) :: module() | nil
  def owner(%__MODULE__{owner: owner}), do: owner

  @doc """
  Returns the Agent or mounted-Skill scope that staged the effect.

  Older persisted effects may not carry a scope and return `nil`.
  """
  @spec scope(t()) :: Spectre.Definition.scope() | nil
  def scope(%__MODULE__{scope: scope}), do: scope

  @spec effect_payload(map()) :: map()
  defp effect_payload(attrs) do
    payload = attr_or(attrs, :payload, %{})
    selected_tool = payload_attr(attrs, payload, :selected_tool)
    al = payload_attr(attrs, payload, :al)

    payload
    |> Map.put_new(:selected_tool, selected_tool)
    |> Map.put_new(:al, al)
    |> Map.put_new(
      :source,
      payload_attr(attrs, payload, :source, infer_source(selected_tool, al))
    )
    |> Map.put_new(:hooks, payload_attr(attrs, payload, :hooks, []))
    |> Map.put_new(:raw, drop_origin(attrs))
    |> Map.put_new(:created_at, attr_or(attrs, :created_at, DateTime.utc_now()))
  end

  @spec origin_attr(map(), map(), :owner | :scope) :: term()
  defp origin_attr(attrs, payload, key),
    do: get_attr(attrs, key) || Map.get(payload, key) || Map.get(payload, Atom.to_string(key))

  @spec put_origin(t(), module() | nil, Spectre.Definition.scope()) :: t()
  defp put_origin(%__MODULE__{} = effect, owner, scope),
    do: %{effect | owner: owner, scope: scope}

  @spec drop_origin(map()) :: map()
  defp drop_origin(map) do
    Map.drop(map, [:owner, :scope, "owner", "scope"])
  end

  @spec payload_attr(map(), map(), atom(), term()) :: term()
  defp payload_attr(attrs, payload, key, default \\ nil) do
    get_attr(attrs, key) || Map.get(payload, key) || default
  end

  @spec normalize_map(map() | struct()) :: map()
  defp normalize_map(%{__struct__: _} = attrs), do: Map.from_struct(attrs)
  defp normalize_map(attrs), do: attrs

  @spec attr_or(map(), atom(), term()) :: term()
  defp attr_or(attrs, key, default), do: get_attr(attrs, key) || default

  @spec normalize_name(term(), String.t() | nil, String.t() | nil) :: atom() | String.t() | nil
  defp normalize_name(name, _selected_tool, _al) when is_atom(name) and not is_nil(name), do: name
  defp normalize_name(name, _selected_tool, _al) when is_binary(name), do: name
  defp normalize_name(_name, selected_tool, al), do: infer_name(selected_tool, al)

  @spec infer_name(String.t() | nil, String.t() | nil) :: atom() | nil
  defp infer_name(selected_tool, _al) when is_binary(selected_tool) do
    selected_tool
    |> String.replace_prefix("Elixir.", "")
    |> String.split(".")
    |> List.last()
    |> case do
      nil -> nil
      fun_arity -> fun_arity |> String.split("/") |> hd() |> existing_atom()
    end
  end

  defp infer_name(_selected_tool, al) when is_binary(al) do
    al
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("_", &String.downcase/1)
    |> String.replace(~r/[^a-z0-9_]/, "")
    |> case do
      "" -> nil
      name -> existing_atom(name)
    end
  end

  defp infer_name(_selected_tool, _al), do: nil

  @spec infer_source(String.t() | nil, String.t() | nil) :: :al | :manual
  defp infer_source(selected_tool, al) when is_binary(selected_tool) or is_binary(al), do: :al
  defp infer_source(_selected_tool, _al), do: :manual

  @spec get_attr(map(), atom()) :: term()
  defp get_attr(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @spec existing_atom(String.t()) :: atom() | nil
  defp existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
