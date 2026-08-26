defmodule Spectre.Privacy do
  @moduledoc """
  Read-only privacy posture and erasure planning.

  `erasure_plan/3` only inspects configuration and exported callbacks. It does
  not start an Instance, read a store, acquire ownership, or delete data.
  """

  alias Spectre.AgentRef
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Owner
  alias Spectre.Instance.Ref
  alias Spectre.Journal.Store, as: JournalStore
  alias Spectre.Privacy.ErasurePlan
  alias Spectre.Receipt.Sink, as: ReceiptSink
  alias Spectre.Stack.PackageData

  @unavailable_reasons [
    :checkpoint_store_not_loaded,
    :instance_owner_not_loaded,
    :journal_store_not_loaded,
    :receipt_sink_not_loaded
  ]

  @doc "Builds a read-only erasure capability plan for one Agent and Subject."
  @spec erasure_plan(module() | AgentRef.t() | Ref.t(), term(), keyword()) ::
          {:ok, ErasurePlan.t()} | {:error, term()}
  def erasure_plan(agent_or_ref, subject, opts \\ [])

  def erasure_plan(agent_or_ref, subject, opts) when is_list(opts) do
    with :ok <- keyword(opts),
         {:ok, ref, agent} <- instance_ref(agent_or_ref, subject),
         {:ok, base_opts} <- base_opts(opts),
         {:ok, checkpoint} <- checkpoint(agent, opts, base_opts),
         {:ok, owner} <- owner(agent, opts, base_opts),
         {:ok, journal} <- journal(agent, opts, base_opts),
         {:ok, receipt_sink} <- receipt_sink(agent, opts, base_opts),
         {:ok, package_data} <- PackageData.erasure_plan(ref, package_opts(opts, base_opts)) do
      components = %{
        owner: owner_component(owner),
        journal: journal_component(journal),
        receipt_payloads: receipt_component(receipt_sink),
        package_data: package_data,
        checkpoint: checkpoint_component(checkpoint)
      }

      {:ok, ErasurePlan.new(ref.key, components)}
    end
  rescue
    ArgumentError -> {:error, :invalid_privacy_erasure_identity}
  end

  def erasure_plan(_agent_or_ref, _subject, _opts),
    do: {:error, :invalid_privacy_erasure_options}

  defp checkpoint(agent, opts, base_opts) do
    first_configured([
      {opts, :checkpoint_store},
      {base_opts, :checkpoint_store},
      {agent_config(agent), :checkpoint_store}
    ])
    |> CheckpointStore.normalize()
  end

  defp owner(agent, opts, base_opts) do
    first_configured([
      {opts, :owner},
      {base_opts, :owner},
      {agent_config(agent), :owner}
    ])
    |> Owner.normalize()
  end

  defp journal(agent, opts, base_opts) do
    first_configured([
      {opts, :journal},
      {base_opts, :journal},
      {agent_config(agent), :journal}
    ])
    |> JournalStore.normalize()
  end

  defp receipt_sink(agent, opts, base_opts) do
    first_configured([
      {opts, :receipt_sink},
      {base_opts, :receipt_sink},
      {agent_config(agent), :receipt_sink}
    ])
    |> ReceiptSink.normalize()
  end

  defp owner_component({module, _opts}) do
    capability_component(Owner.maintenance_capability({module, []}), module)
  end

  defp journal_component(nil), do: ErasurePlan.component(false, :not_configured)

  defp journal_component({module, _opts} = journal) do
    capability_component(JournalStore.erasure_capability(journal), module)
  end

  defp receipt_component(nil), do: ErasurePlan.component(false, :not_configured)

  defp receipt_component({module, _opts} = sink) do
    capability_component(ReceiptSink.payload_erasure_capability(sink), module)
  end

  defp checkpoint_component(nil), do: ErasurePlan.component(false, :required)

  defp checkpoint_component({module, _opts} = checkpoint) do
    capability_component(CheckpointStore.erasure_capability(checkpoint), module)
  end

  defp capability_component(:ok, module), do: ErasurePlan.component(true, :ready, module)

  defp capability_component({:error, reason}, module) do
    status = if unavailable?(reason), do: :unavailable, else: :unsupported
    ErasurePlan.component(true, status, module)
  end

  # Capability boundaries expose a closed set of load failures. Match those
  # exact tags so a future, unrelated adapter error cannot be misclassified by
  # a coincidental suffix.
  defp unavailable?({reason, _module}) when reason in @unavailable_reasons, do: true

  defp unavailable?(_reason), do: false

  defp base_opts(opts) do
    case Keyword.get(opts, :opts, []) do
      value when is_list(value) ->
        if Keyword.keyword?(value),
          do: {:ok, value},
          else: {:error, {:invalid_privacy_erasure_option, :opts}}

      _invalid ->
        {:error, {:invalid_privacy_erasure_option, :opts}}
    end
  end

  @spec package_opts(keyword(), keyword()) :: keyword()
  defp package_opts(opts, base_opts) do
    case Keyword.fetch(opts, :stack_runtime) do
      {:ok, runtime} -> Keyword.put(base_opts, :stack_runtime, runtime)
      :error -> base_opts
    end
  end

  defp agent_config(agent) when is_atom(agent) and not is_nil(agent) do
    if Code.ensure_loaded?(agent) and function_exported?(agent, :__spectre_config__, 0),
      do: agent.__spectre_config__(),
      else: []
  end

  defp agent_config(_agent), do: []

  defp first_configured(entries) do
    Enum.reduce_while(entries, nil, fn {options, key}, _acc ->
      case Keyword.fetch(options, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, nil}
      end
    end)
  end

  defp instance_ref(%Ref{} = ref, subject) do
    supplied = Ref.new(ref.agent_ref, subject)

    if supplied.key == ref.key,
      do: {:ok, ref, ref.agent_ref.definition},
      else: {:error, :privacy_erasure_subject_mismatch}
  end

  defp instance_ref(%AgentRef{} = agent_ref, subject) do
    ref = Ref.new(agent_ref, subject)
    {:ok, ref, agent_ref.definition}
  end

  defp instance_ref(agent, subject) when is_atom(agent) and not is_nil(agent) do
    {:ok, Ref.new(agent, subject), agent}
  end

  defp instance_ref(_agent, _subject), do: {:error, :invalid_privacy_erasure_identity}

  defp keyword(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, :invalid_privacy_erasure_options}
  end
end
