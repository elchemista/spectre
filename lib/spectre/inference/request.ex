defmodule Spectre.Inference.Request do
  @moduledoc """
  One typed, purpose-labelled inference invocation.
  """

  alias Spectre.Inference.Constraints
  alias Spectre.Prompt.Plan

  defstruct [
    :id,
    :purpose,
    :plan,
    :route,
    :flow,
    modalities: [:text],
    constraints: %Constraints{},
    attempt: 1,
    previous_errors: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          purpose: term(),
          plan: Plan.t(),
          route: term(),
          flow: term(),
          modalities: [atom()],
          constraints: Constraints.t(),
          attempt: pos_integer(),
          previous_errors: [term()],
          metadata: map()
        }

  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    request =
      attrs
      |> Map.put_new(:id, Spectre.Identity.uuid7())
      |> Map.update(:constraints, %Constraints{}, &Constraints.new/1)
      |> Map.update(:modalities, [:text], &normalize_modalities/1)
      |> then(&struct(__MODULE__, Map.take(&1, fields())))

    validate!(request)
    request
  end

  @doc """
  Builds the response-generation request used by `Spectre.Runner`.
  """
  @spec for_response(Plan.t(), Spectre.Context.t(), keyword()) :: t()
  def for_response(%Plan{} = plan, %Spectre.Context{} = ctx, opts) when is_list(opts) do
    route = ctx.route
    flow_constraints = if route && route.rule, do: route.rule.constraints, else: []
    constraints = Constraints.from_options(opts, flow_constraints)
    constraints = put_context_tokens(constraints, plan)

    new(%{
      purpose: Keyword.get(opts, :inference_purpose, :response_generation),
      plan: plan,
      route: route && route.label,
      flow: route && route.flow,
      modalities: modalities(ctx.input, opts),
      constraints: constraints,
      metadata: %{
        flow_constraints: flow_constraints,
        model: Keyword.get(opts, :model) || Keyword.get(opts, :adapter),
        fallback: Keyword.get(opts, :fallback),
        llm_opts: opts,
        explicit_model_override?: Keyword.get(opts, :explicit_model_override?, false),
        agent_model: Keyword.get(ctx.opts, :model) || Keyword.get(ctx.opts, :adapter)
      }
    })
  end

  @doc """
  Builds a route-classification request around an already composed prompt plan.
  """
  @spec for_classification(Plan.t(), Spectre.Context.t() | map(), keyword()) :: t()
  def for_classification(%Plan{} = plan, ctx, opts) when is_map(ctx) and is_list(opts) do
    input = Map.get(ctx, :input)

    constraints =
      opts
      |> Keyword.put_new(:structured_output?, true)
      |> Keyword.put_new(:maximum_output_tokens, 8)
      |> Constraints.from_options([])
      |> put_context_tokens(plan)

    new(%{
      purpose: :route_classification,
      plan: plan,
      modalities: modalities(input, opts),
      constraints: constraints,
      metadata: %{
        model: Keyword.get(opts, :model) || Keyword.get(opts, :adapter),
        fallback: Keyword.get(opts, :fallback),
        llm_opts: opts,
        explicit_model_override?: false,
        agent_model: Keyword.get(opts, :model) || Keyword.get(opts, :adapter)
      }
    })
  end

  @spec put_context_tokens(Constraints.t(), Plan.t()) :: Constraints.t()
  defp put_context_tokens(%Constraints{context_tokens: nil} = constraints, %Plan{} = plan) do
    estimated = max(div(byte_size(Plan.legacy(plan)) + 3, 4), 1)
    %{constraints | context_tokens: estimated}
  end

  defp put_context_tokens(constraints, _plan), do: constraints

  @spec modalities(Spectre.Input.t() | nil, keyword()) :: [atom()]
  defp modalities(input, opts) when is_list(opts) do
    case Keyword.get(opts, :modalities) do
      nil -> input_modalities(input)
      configured -> normalize_modalities(configured)
    end
  end

  @spec input_modalities(Spectre.Input.t() | nil) :: [atom()]
  defp input_modalities(%Spectre.Input{source: %Spectre.Input.Source{metadata: metadata}} = input) do
    metadata
    |> Map.get(:modalities, Map.get(metadata, "modalities"))
    |> case do
      nil -> default_modalities(input)
      modalities -> normalize_modalities(modalities)
    end
  end

  defp input_modalities(%Spectre.Input{} = input), do: default_modalities(input)
  defp input_modalities(_input), do: [:text]

  @spec default_modalities(Spectre.Input.t()) :: [atom()]
  defp default_modalities(%Spectre.Input{text: text}) when is_binary(text) and text != "",
    do: [:text]

  defp default_modalities(%Spectre.Input{}), do: []

  @spec normalize_modalities(term()) :: [atom()]
  defp normalize_modalities(modalities) do
    modalities
    |> List.wrap()
    |> Enum.uniq()
  end

  @spec validate!(t()) :: :ok
  defp validate!(%__MODULE__{} = request) do
    unless is_binary(request.id) and request.id != "",
      do: raise(ArgumentError, "inference request id is required")

    unless not is_nil(request.purpose), do: raise(ArgumentError, "inference purpose is required")
    unless match?(%Plan{}, request.plan), do: raise(ArgumentError, "inference plan is required")

    unless is_integer(request.attempt) and request.attempt > 0,
      do: raise(ArgumentError, "inference attempt must be positive")

    unless is_list(request.modalities) and Enum.all?(request.modalities, &is_atom/1),
      do: raise(ArgumentError, "inference modalities must be atoms")

    :ok
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
