defmodule Spectre.Stack.PackageData do
  @moduledoc """
  Optional erasure contract for data owned by Stack packages.

  A package that persists Instance-scoped data implements `erasure_plan/2` and
  `erase_instance/2` on its installable module. Core discovers those callbacks
  from the immutable Stack bound to the Agent; runtime handles remain call-local
  options and are never copied into a Run, checkpoint, or erasure proof.
  """

  alias Spectre.Instance.Ref
  alias Spectre.Stack.Definition, as: StackDefinition
  alias Spectre.Stack.Installation

  @type outcome :: :erased | :already_erased
  @type plan_component :: %{
          required(:configured) => boolean(),
          required(:status) => :ready | :not_configured | :unsupported | :unavailable,
          required(:package_count) => non_neg_integer(),
          required(:adapters) => [map()]
        }

  @callback erasure_plan(Ref.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback erase_instance(Ref.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @doc "Builds a read-only capability component for installed package data."
  @spec erasure_plan(Ref.t(), keyword()) :: {:ok, plan_component()} | {:error, term()}
  def erasure_plan(ref, opts \\ [])

  def erasure_plan(%Ref{} = ref, opts) when is_list(opts) do
    with :ok <- keyword(opts),
         {:ok, adapters} <- adapters(ref) do
      entries = Enum.map(adapters, &plan_entry(&1, ref, opts))
      {:ok, plan_component(entries)}
    end
  end

  def erasure_plan(%Ref{}, _opts), do: {:error, :invalid_package_data_erasure_options}

  @doc "Erases every installed package-data adapter in Stack order."
  @spec erase_instance(Ref.t(), keyword(), (-> :ok | {:error, term()})) ::
          {:ok, map()} | {:error, term()}
  def erase_instance(ref, opts \\ [], authorize \\ fn -> :ok end)

  def erase_instance(%Ref{} = ref, opts, authorize)
      when is_list(opts) and is_function(authorize, 0) do
    with :ok <- keyword(opts),
         {:ok, adapters} <- adapters(ref),
         :ok <- complete_adapters(adapters) do
      erase_adapters(adapters, ref, opts, authorize)
    end
  end

  def erase_instance(%Ref{}, _opts, _authorize),
    do: {:error, :invalid_package_data_erasure_options}

  defp erase_adapters(adapters, ref, opts, authorize) do
    adapters
    |> Enum.reduce_while({:ok, []}, &erase_adapter(&1, &2, ref, opts, authorize))
    |> erase_result(length(adapters))
  end

  defp erase_adapter(adapter, {:ok, completed}, ref, opts, authorize) do
    with :ok <- authorize.(),
         {:ok, result} <-
           invoke(adapter.module, :erase_instance, [ref, adapter_opts(opts, adapter)]) do
      {:cont, {:ok, [erase_entry(adapter, result) | completed]}}
    else
      {:error, reason} ->
        {:halt,
         {:error, {:package_data_erase_failed, completed_ids(completed), adapter.module, reason}}}
    end
  end

  @doc false
  @spec erasure_capability(plan_component()) :: :ok | {:error, term()}
  def erasure_capability(%{status: status}) when status in [:ready, :not_configured], do: :ok

  def erasure_capability(%{status: status, adapters: adapters}),
    do: {:error, {:package_data_erasure_unavailable, status, adapters}}

  def erasure_capability(_component), do: {:error, :invalid_package_data_erasure_plan}

  @spec adapters(Ref.t()) :: {:ok, [map()]} | {:error, term()}
  defp adapters(%Ref{agent_ref: %{definition: agent}})
       when is_atom(agent) and not is_nil(agent) do
    with {:ok, definition} <- Spectre.Definition.fetch(agent) do
      stack_adapters(definition.stack)
    end
  end

  # A portable AgentRef may intentionally omit its source module. Core cannot
  # discover a Stack in that shape, so preserve the existing stable-key
  # erasure contract and report no configured package-data adapters.
  defp adapters(%Ref{}), do: {:ok, []}

  @spec stack_adapters(module() | nil) :: {:ok, [map()]} | {:error, term()}
  defp stack_adapters(nil), do: {:ok, []}

  defp stack_adapters(stack) do
    with {:ok, definition} <- StackDefinition.fetch(stack) do
      adapters =
        definition.installations
        |> Enum.map(&adapter/1)
        |> Enum.reject(&is_nil/1)

      {:ok, adapters}
    end
  end

  @spec adapter(Installation.t()) :: map() | nil
  defp adapter(%Installation{} = installation) do
    module = installation.package.module
    plan? = callback?(module, :erasure_plan)
    erase? = callback?(module, :erase_instance)

    if plan? or erase? do
      %{
        installation: installation.id,
        package: installation.package.id,
        module: module,
        plan?: plan?,
        erase?: erase?
      }
    end
  end

  @spec callback?(module(), atom()) :: boolean()
  defp callback?(module, function),
    do: Code.ensure_loaded?(module) and function_exported?(module, function, 2)

  @spec plan_entry(map(), Ref.t(), keyword()) :: map()
  defp plan_entry(%{plan?: true, erase?: true} = adapter, ref, opts) do
    case invoke(adapter.module, :erasure_plan, [ref, adapter_opts(opts, adapter)]) do
      {:ok, %{supported?: false}} -> adapter_entry(adapter, :unsupported)
      {:ok, plan} when is_map(plan) -> adapter_entry(adapter, :ready)
      {:ok, _invalid} -> adapter_entry(adapter, :unsupported)
      {:error, _reason} -> adapter_entry(adapter, :unavailable)
    end
  end

  defp plan_entry(adapter, _ref, _opts), do: adapter_entry(adapter, :unsupported)

  @spec adapter_entry(map(), atom()) :: map()
  defp adapter_entry(adapter, status) do
    %{
      installation: adapter.installation,
      package: adapter.package,
      adapter: inspect(adapter.module),
      status: status
    }
  end

  @spec plan_component([map()]) :: plan_component()
  defp plan_component([]) do
    %{configured: false, status: :not_configured, package_count: 0, adapters: []}
  end

  defp plan_component(entries) do
    status =
      cond do
        Enum.all?(entries, &(&1.status == :ready)) -> :ready
        Enum.any?(entries, &(&1.status == :unavailable)) -> :unavailable
        true -> :unsupported
      end

    %{
      configured: true,
      status: status,
      package_count: length(entries),
      adapters: entries
    }
  end

  @spec complete_adapters([map()]) :: :ok | {:error, term()}
  defp complete_adapters(adapters) do
    case Enum.find(adapters, &(not (&1.plan? and &1.erase?))) do
      nil -> :ok
      adapter -> {:error, {:package_data_adapter_incomplete, adapter.module}}
    end
  end

  @spec adapter_opts(keyword(), map()) :: keyword()
  defp adapter_opts(opts, adapter) do
    opts
    |> Keyword.put(:stack_installation, adapter.installation)
    |> Keyword.put(:stack_package, adapter.package)
  end

  @spec invoke(module(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defp invoke(module, function, args) do
    case apply(module, function, args) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      invalid -> {:error, {:invalid_package_data_reply, module, function, reply_shape(invalid)}}
    end
  rescue
    exception ->
      {:error,
       {:package_data_callback_exception, module, function, exception.__struct__,
        Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:package_data_callback_failure, module, function, kind, reason}}
  end

  @spec erase_entry(map(), term()) :: map()
  defp erase_entry(adapter, result) do
    %{
      installation: adapter.installation,
      package: adapter.package,
      adapter: inspect(adapter.module),
      outcome: erase_outcome(result)
    }
  end

  @spec erase_outcome(term()) :: outcome()
  defp erase_outcome(%{already_erased?: true}), do: :already_erased
  defp erase_outcome(:already_erased), do: :already_erased
  defp erase_outcome(_result), do: :erased

  @spec completed_ids([map()]) :: [term()]
  defp completed_ids(completed),
    do: completed |> Enum.reverse() |> Enum.map(& &1.installation)

  @spec erase_result({:ok, [map()]} | {:error, term()}, non_neg_integer()) ::
          {:ok, map()} | {:error, term()}
  defp erase_result({:error, _reason} = error, _total), do: error

  defp erase_result({:ok, completed}, total) do
    packages = Enum.reverse(completed)
    already = Enum.count(packages, &(&1.outcome == :already_erased))
    erased = total - already

    outcome =
      cond do
        total == 0 -> :not_configured
        erased == 0 -> :already_erased
        true -> :erased
      end

    {:ok,
     %{
       outcome: outcome,
       package_count: total,
       erased_count: erased,
       already_erased_count: already,
       packages: packages
     }}
  end

  @spec keyword(keyword()) :: :ok | {:error, term()}
  defp keyword(opts) do
    if Keyword.keyword?(opts),
      do: :ok,
      else: {:error, :invalid_package_data_erasure_options}
  end

  @spec reply_shape(term()) :: atom()
  defp reply_shape(value) when is_map(value), do: :map
  defp reply_shape(value) when is_list(value), do: :list
  defp reply_shape(value) when is_tuple(value), do: :tuple
  defp reply_shape(value) when is_atom(value), do: :atom
  defp reply_shape(_value), do: :other
end
