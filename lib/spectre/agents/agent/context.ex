defmodule Spectre.Agent.Context do
  @moduledoc false

  # Host-owned reads run in Instance's temporary worker. They do not create
  # Evidence or authorize protected retrieval. Sources must already be
  # observable through the authenticated Scope before they inform a request.
  alias Spectre.Agent.{Observer, Wiring}
  alias Spectre.Canonical.Value
  alias Spectre.{History, Memory, Portable}
  alias Spectre.Mind.Turn

  @type t :: %{history: [map()], memory: [map()]}
  @max_bytes 65_536

  @doc false
  @spec load(map(), map(), term()) :: {:ok, t()} | {:error, term()}
  def load(owner, wiring, input) do
    owner.plan.settings
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{history: [], memory: []}}, fn {name, config}, {:ok, context} ->
      case observed_window(name, config, owner, wiring, input) do
        {:ok, kind, items} ->
          context = Map.update!(context, kind, &(&1 ++ items))

          checked_context(context)

        :skip ->
          {:cont, {:ok, context}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp observed_window(name, config, owner, wiring, input) do
    phase = if String.starts_with?(name, "history/"), do: :history_load, else: :memory_load
    metadata = %{definition_ref: owner.definition_ref, owner: owner.prefix}

    if phase == :history_load or String.starts_with?(name, "memory/") do
      Observer.span(%{wiring: wiring}, phase, metadata, fn ->
        window(name, config, owner.prefix, wiring, input)
      end)
    else
      :skip
    end
  end

  defp checked_context(context) do
    case Value.validate(context, max_bytes: @max_bytes) do
      :ok -> {:cont, {:ok, context}}
      {:error, _} -> {:halt, {:error, :agent_context_budget_exceeded}}
    end
  end

  @doc false
  @spec evidence_refs(t()) :: {:ok, [String.t()]} | {:error, term()}
  def evidence_refs(context) do
    items = context.history ++ context.memory

    if Enum.all?(items, &match?([_ | _], &1.evidence_refs)),
      do:
        Portable.normalize_refs(Enum.flat_map(items, & &1.evidence_refs), :context_evidence_refs),
      else: {:error, :context_evidence_required}
  end

  @doc false
  @spec validate_sources(t(), Spectre.Mind.Turn.t()) :: :ok | {:error, term()}
  def validate_sources(context, turn) do
    with {:ok, refs} <- evidence_refs(context) do
      visible = Turn.evidence_refs(turn)

      if Enum.all?(refs, &(&1 in visible)),
        do: :ok,
        else: {:error, :context_evidence_exceeds_window}
    end
  end

  @doc false
  @spec prompt_parts(t() | map()) :: [map()]
  def prompt_parts(context) do
    for kind <- [:history, :memory], item <- Map.get(context, kind, []) do
      %{
        "role" => kind,
        "name" => item.ref,
        "text" => item.content,
        "evidence_refs" => item.evidence_refs,
        "status" => Map.get(item, :status),
        "speaker" => Map.get(item, :role)
      }
    end
  end

  defp window("history/" <> name, config, prefix, wiring, _input) do
    with {:ok, {module, opts}} <- Wiring.fetch(wiring, prefix, :history, name),
         {binding, opts} = Keyword.split(opts, [:tenant_id, :conversation_id]),
         {:ok, history} <- History.bind({module, opts}, binding),
         {:ok, page} <- History.load(history, Map.take(config, [:keep, :max_bytes])) do
      {:ok, :history, page.messages}
    else
      :error -> {:error, {:unwired_history, prefix <> name}}
      error -> error
    end
  end

  defp window("memory/" <> name, config, prefix, wiring, input) do
    with {:ok, {module, opts}} <- Wiring.fetch(wiring, prefix, :memory, name),
         {binding, opts} = Keyword.split(opts, [:tenant_id]),
         {:ok, items} <-
           Memory.retrieve({module, opts}, binding, input, Map.take(config, [:limit, :max_bytes])) do
      {:ok, :memory, items}
    else
      :error -> {:error, {:unwired_memory, prefix <> name}}
      error -> error
    end
  end

  defp window(_name, _config, _prefix, _wiring, _input), do: :skip
end
