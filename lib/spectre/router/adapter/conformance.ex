defmodule Spectre.Router.Adapter.Conformance do
  @moduledoc """
  Executable contract checks for third-party Router Adapters.

  Adapter packages provide a deterministic `%Spectre.Router.Adapter.Request{}`
  fixture whose rules are expected to produce evidence. The runner validates
  the descriptor, isolates `evaluate/1` behind the normal provider boundary,
  and applies the same strict result normalizer and thresholds used by live
  routing.
  """

  alias Spectre.Definition.Canonical.Data
  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Router.Adapter.Compiler
  alias Spectre.Router.Adapter.Request
  alias Spectre.Router.Adapter.RuleView
  alias Spectre.Router.Adapter.Runner

  @allowed_options [:provider_timeout, :router_adapter_timeout, :telemetry_handler]

  @type phase :: :options | :descriptor | :fixture | :callback | :result

  @type report :: %{
          required(:contract_version) => pos_integer(),
          required(:adapter_id) => atom(),
          required(:result_count) => non_neg_integer(),
          required(:accepted_count) => non_neg_integer(),
          required(:rejected_count) => non_neg_integer(),
          required(:thresholds) => %{score: float(), margin: float() | nil}
        }

  @type failure :: {:router_adapter_conformance_failed, phase(), term()}

  @doc "Returns the Router Adapter conformance contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: Compiler.contract_version()

  @doc """
  Runs the Adapter contract against one deterministic Request fixture.

  The fixture must contain at least one valid RuleView and the callback must
  return `{:ok, result_or_results}`. A skip or declared error is valid during
  normal routing but cannot prove result conformance, so this runner reports it
  in the `:callback` phase.
  """
  @spec run(module(), Request.t(), keyword()) :: {:ok, report()} | {:error, failure()}
  def run(adapter, request, opts \\ [])

  def run(adapter, %Request{} = request, opts) when is_atom(adapter) and is_list(opts) do
    with :ok <- validate_options(opts),
         {:ok, descriptor} <- descriptor(adapter),
         :ok <- validate_request(request),
         {:ok, results} <- evaluate(adapter, descriptor.id, request, opts),
         {:ok, results} <- normalize(results, request.rules) do
      thresholds = Enum.map(results, &Runner.threshold(&1, descriptor))
      accepted_count = Enum.count(thresholds, &match?({true, nil}, &1))

      {:ok,
       %{
         contract_version: descriptor.contract,
         adapter_id: descriptor.id,
         result_count: length(results),
         accepted_count: accepted_count,
         rejected_count: length(results) - accepted_count,
         thresholds: %{score: descriptor.accept, margin: descriptor.margin}
       }}
    end
  end

  def run(_adapter, _request, _opts), do: failure(:options, :invalid_arguments)

  @spec validate_options(keyword()) :: :ok | {:error, failure()}
  defp validate_options(opts) do
    if Keyword.keyword?(opts) do
      case Keyword.keys(opts) -- @allowed_options do
        [] -> :ok
        unknown -> failure(:options, {:unknown_options, Enum.uniq(unknown)})
      end
    else
      failure(:options, :invalid_options)
    end
  end

  @spec descriptor(module()) :: {:ok, Compiler.descriptor()} | {:error, failure()}
  defp descriptor(adapter) do
    case Compiler.fetch_descriptor(adapter) do
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, reason} -> failure(:descriptor, reason)
    end
  end

  @spec validate_request(Request.t()) :: :ok | {:error, failure()}
  defp validate_request(%Request{} = request) do
    checks = [
      {:invalid_text, is_binary(request.text)},
      {:invalid_meta, is_map(request.meta) and not is_struct(request.meta)},
      {:invalid_recent_chat, is_binary(request.recent_chat)},
      {:invalid_current_flow, optional_ordinary_atom?(request.current_flow)},
      {:invalid_current_scope, optional_scope?(request.current_scope)},
      {:invalid_rules, is_list(request.rules)},
      {:empty_rules, request.rules != []}
    ]

    case Enum.find(checks, fn {_reason, valid?} -> not valid? end) do
      nil -> validate_rule_views(request.rules)
      {reason, false} -> failure(:fixture, reason)
    end
  end

  @spec validate_rule_views([term()]) :: :ok | {:error, failure()}
  defp validate_rule_views(rules) do
    refs = Enum.map(rules, &rule_view_ref/1)

    cond do
      Enum.any?(refs, &match?({:error, _reason}, &1)) ->
        {:error, reason} = Enum.find(refs, &match?({:error, _reason}, &1))
        failure(:fixture, reason)

      length(Enum.uniq(refs)) != length(refs) ->
        failure(:fixture, :duplicate_rule_ref)

      true ->
        :ok
    end
  end

  @spec rule_view_ref(term()) :: RuleView.ref() | {:error, term()}
  defp rule_view_ref(
         %RuleView{ref: {scope, label}, scope: scope, label: label, opts: opts} = rule
       )
       when is_atom(label) and not is_nil(label) and is_list(opts) do
    checks = [
      {:invalid_rule_scope, valid_scope?(scope)},
      {:invalid_rule_opts, Keyword.keyword?(opts)},
      {:invalid_rule_flow, optional_ordinary_atom?(rule.flow)},
      {:invalid_rule_flow_path, atom_list?(rule.flow_path)},
      {:invalid_rule_global, is_boolean(rule.global?)},
      {:invalid_rule_data, structural_data?(rule.data)}
    ]

    case Enum.find(checks, fn {_reason, valid?} -> not valid? end) do
      nil -> {scope, label}
      {reason, false} -> {:error, reason}
    end
  end

  defp rule_view_ref(%RuleView{}), do: {:error, :invalid_rule_view}
  defp rule_view_ref(_rule), do: {:error, :rule_must_be_a_rule_view}

  @spec evaluate(module(), atom(), Request.t(), keyword()) ::
          {:ok, term()} | {:error, failure()}
  defp evaluate(adapter, adapter_id, request, opts) do
    call_opts = Keyword.put(opts, :purpose, adapter_id)

    case Call.run(
           :router_adapter,
           fn -> adapter.evaluate(request) |> normalize_callback_reply() end,
           call_opts
         ) do
      {:ok, results} -> {:ok, results}
      {:error, %Failure{} = failure} -> failure(:callback, failure.kind)
      {:error, reason} -> failure(:callback, reason_class(reason))
    end
  end

  @spec normalize_callback_reply(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_callback_reply({:ok, results}), do: {:ok, results}
  defp normalize_callback_reply(:skip), do: {:error, :fixture_skipped}
  defp normalize_callback_reply({:skip, _reason}), do: {:error, :fixture_skipped}
  defp normalize_callback_reply({:error, _reason}), do: {:error, :adapter_error}

  defp normalize_callback_reply(other),
    do: {:error, Failure.invalid_reply(:router_adapter, other)}

  @spec normalize(term(), [RuleView.t()]) :: {:ok, [map()]} | {:error, failure()}
  defp normalize(results, rules) do
    case Runner.normalize_results(results, rules) do
      {:ok, results} -> {:ok, results}
      {:error, reason} -> failure(:result, reason)
    end
  end

  @spec reason_class(term()) :: atom()
  defp reason_class(reason) when is_atom(reason), do: reason
  defp reason_class(reason) when is_tuple(reason), do: :tuple
  defp reason_class(reason) when is_map(reason), do: :map
  defp reason_class(reason) when is_list(reason), do: :list
  defp reason_class(_reason), do: :other

  @spec ordinary_atom?(term()) :: boolean()
  defp ordinary_atom?(value), do: is_atom(value) and value not in [nil, true, false]

  @spec optional_ordinary_atom?(term()) :: boolean()
  defp optional_ordinary_atom?(nil), do: true
  defp optional_ordinary_atom?(value), do: ordinary_atom?(value)

  @spec optional_scope?(term()) :: boolean()
  defp optional_scope?(nil), do: true
  defp optional_scope?(scope), do: valid_scope?(scope)

  @spec atom_list?(term()) :: boolean()
  defp atom_list?(value), do: is_list(value) and Enum.all?(value, &ordinary_atom?/1)

  @spec structural_data?(term()) :: boolean()
  defp structural_data?(value) do
    match?({:ok, _lowered}, Data.structural(value, path: [:router_adapter_conformance, :data]))
  end

  @spec valid_scope?(term()) :: boolean()
  defp valid_scope?(:agent), do: true
  defp valid_scope?({:skill, id}), do: not is_nil(id)
  defp valid_scope?(_scope), do: false

  @spec failure(phase(), term()) :: {:error, failure()}
  defp failure(phase, reason),
    do: {:error, {:router_adapter_conformance_failed, phase, reason}}
end
