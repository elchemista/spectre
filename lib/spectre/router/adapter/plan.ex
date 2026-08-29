defmodule Spectre.Router.Adapter.Plan do
  @moduledoc false

  alias Spectre.Router.Adapter.Compiler

  @type availability :: :available | {:unavailable, term()}

  @type entry :: %{
          required(:id) => atom(),
          required(:module) => module(),
          required(:descriptor) => Compiler.descriptor(),
          required(:order) => non_neg_integer(),
          required(:availability) => availability()
        }

  @type t :: %{
          required(:entries) => %{optional(atom()) => entry()},
          required(:diagnostics) => [term()]
        }

  @doc false
  @spec build(%{optional(atom()) => Compiler.entry()}, keyword()) ::
          {:ok, t()} | {:error, term()}
  def build(compiled, opts) when is_map(compiled) and is_list(opts) do
    with {:ok, active} <- active_entries(compiled, opts) do
      {entries, diagnostics} = check_entries(active)
      {:ok, %{entries: entries, diagnostics: diagnostics}}
    end
  end

  @doc false
  @spec fetch(t(), atom()) :: {:ok, entry()} | :error
  def fetch(%{entries: entries}, adapter_id) when is_map(entries) and is_atom(adapter_id),
    do: Map.fetch(entries, adapter_id)

  @doc false
  @spec diagnostics(t()) :: [term()]
  def diagnostics(%{diagnostics: diagnostics}) when is_list(diagnostics), do: diagnostics

  @doc false
  @spec entries(t()) :: [entry()]
  def entries(%{entries: entries}) when is_map(entries) do
    entries |> Map.values() |> Enum.sort_by(& &1.order)
  end

  @doc false
  @spec adapter_plan?(term()) :: boolean()
  def adapter_plan?(%{entries: entries, diagnostics: diagnostics}),
    do: is_map(entries) and is_list(diagnostics)

  def adapter_plan?(_plan), do: false

  @spec active_entries(map(), keyword()) :: {:ok, [Compiler.entry()]} | {:error, term()}
  defp active_entries(compiled, opts) do
    case Keyword.get(opts, :pipeline) do
      nil ->
        opts
        |> Keyword.get(:via, [:regex])
        |> List.wrap()
        |> entries_from_via(compiled)

      _custom_pipeline ->
        {:ok, compiled |> Map.values() |> Enum.sort_by(& &1.order)}
    end
  end

  @spec entries_from_via([term()], map()) ::
          {:ok, [Compiler.entry()]} | {:error, term()}
  defp entries_from_via(via, compiled) do
    known = MapSet.new(Compiler.built_in_steps() ++ Map.keys(compiled))

    via
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn {step, order}, {:ok, entries, seen} ->
      cond do
        not is_atom(step) or not MapSet.member?(known, step) ->
          {:halt, {:error, {:unknown_router_step, step}}}

        Map.has_key?(compiled, step) and not MapSet.member?(seen, step) ->
          entry = compiled |> Map.fetch!(step) |> Map.put(:order, order)
          {:cont, {:ok, [entry | entries], MapSet.put(seen, step)}}

        true ->
          {:cont, {:ok, entries, seen}}
      end
    end)
    |> case do
      {:ok, entries, _seen} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  @spec check_entries([Compiler.entry()]) :: {%{optional(atom()) => entry()}, [term()]}
  defp check_entries(entries) do
    Enum.reduce(entries, {%{}, []}, fn entry, {checked, diagnostics} ->
      {entry, diagnostic} = check_entry(entry)
      diagnostics = if is_nil(diagnostic), do: diagnostics, else: [diagnostic | diagnostics]
      {Map.put(checked, entry.id, entry), diagnostics}
    end)
    |> then(fn {checked, diagnostics} -> {checked, Enum.reverse(diagnostics)} end)
  end

  @spec check_entry(Compiler.entry()) :: {entry(), term() | nil}
  defp check_entry(entry) do
    case read_live_descriptor(entry.module) do
      {:ok, descriptor} when descriptor == entry.descriptor ->
        {Map.put(entry, :availability, :available), nil}

      {:ok, _different} ->
        diagnostic = {:router_adapter_descriptor_drift, entry.id, entry.module}
        {Map.put(entry, :availability, {:unavailable, diagnostic}), diagnostic}

      {:error, failure_class} ->
        diagnostic =
          {:router_adapter_descriptor_unavailable, entry.id, entry.module, failure_class}

        {Map.put(entry, :availability, {:unavailable, diagnostic}), diagnostic}
    end
  end

  @spec read_live_descriptor(module()) :: {:ok, term()} | {:error, term()}
  defp read_live_descriptor(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :module_unavailable}

      not function_exported?(module, :__spectre_router_adapter__, 0) ->
        {:error, :descriptor_callback_unavailable}

      not function_exported?(module, :evaluate, 1) ->
        {:error, :evaluate_callback_unavailable}

      true ->
        {:ok, module.__spectre_router_adapter__()}
    end
  rescue
    exception -> {:error, {:exception, exception.__struct__}}
  catch
    kind, reason -> {:error, {kind, failure_class(reason)}}
  end

  @spec failure_class(term()) :: atom()
  defp failure_class(value) when is_atom(value), do: value
  defp failure_class(value) when is_tuple(value), do: :tuple
  defp failure_class(value) when is_map(value), do: :map
  defp failure_class(value) when is_list(value), do: :list
  defp failure_class(_value), do: :other
end
