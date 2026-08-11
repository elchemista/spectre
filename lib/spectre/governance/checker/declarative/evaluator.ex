defmodule Spectre.Governance.Checker.Declarative.Evaluator do
  @moduledoc """
  Executes normalized evaluation cases against an exact loaded Definition.

  Runtime Skills use the production Skill runtime, while compiled misses use
  the real restricted Router path accepted by `Rehearsability`. Each result is
  a deterministic pass/fail observation suitable for an evaluation delta.
  """

  alias Spectre.Eval.Case, as: EvalCase
  alias Spectre.Governance.Checker.Declarative.Rehearsability
  alias Spectre.Governance.Checker.Declarative.Shape
  alias Spectre.Input
  alias Spectre.Input.Pipeline
  alias Spectre.Router
  alias Spectre.Router.Receipt, as: RouterReceipt
  alias Spectre.Runtime.SkillDispatch
  alias Spectre.Skill.Runtime
  alias Spectre.Skill.Runtime.Loader
  alias Spectre.State

  @type result :: %{
          required(:case_id) => String.t(),
          required(:passed) => boolean()
        }
  @type observation :: %{
          required(:outcome) => RouterReceipt.outcome(),
          required(:route) => String.t() | nil,
          required(:strategy) => String.t() | nil,
          required(:llm_called?) => boolean(),
          required(:output) => String.t() | nil,
          optional(:accepted?) => boolean(),
          optional(:duration_us) => non_neg_integer()
        }

  @doc false
  @spec normalize_cases(term()) :: {:ok, [EvalCase.t()]} | {:error, term()}
  def normalize_cases(cases) when is_list(cases) do
    cases
    |> Stream.with_index()
    |> Enum.reduce_while({:ok, []}, &normalize_case/2)
    |> reverse_cases()
  end

  def normalize_cases(value),
    do: {:error, {:invalid_declarative_eval_cases, Shape.of(value)}}

  @doc false
  @spec verify_candidate_case_ids([EvalCase.t()], [String.t()]) :: :ok | {:error, term()}
  def verify_candidate_case_ids(cases, expected) do
    actual = cases |> Enum.map(& &1.id) |> Enum.sort()

    if actual == Enum.sort(expected),
      do: :ok,
      else: {:error, {:declarative_candidate_cases_mismatch, expected, actual}}
  end

  @doc false
  @spec evaluate(Loader.loaded(), [EvalCase.t()], Rehearsability.agent_snapshot()) ::
          {:ok, [result()]} | {:error, term()}
  def evaluate(loaded, cases, agent_snapshot) do
    cases
    |> Enum.reduce_while({:ok, []}, fn evaluation_case, {:ok, results} ->
      case decide(loaded, evaluation_case, agent_snapshot) do
        {:ok, result} -> {:cont, {:ok, [result | results]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> reverse_evaluations()
  end

  @spec normalize_case({EvalCase.t() | map(), non_neg_integer()}, {:ok, [EvalCase.t()]}) ::
          {:cont, {:ok, [EvalCase.t()]}} | {:halt, {:error, term()}}
  defp normalize_case({value, index}, {:ok, normalized}) do
    case EvalCase.new(value) do
      {:ok, evaluation_case} -> {:cont, {:ok, [evaluation_case | normalized]}}
      {:error, reason} -> {:halt, {:error, {:invalid_declarative_eval_case, index, reason}}}
    end
  end

  @spec reverse_cases({:ok, [EvalCase.t()]} | {:error, term()}) ::
          {:ok, [EvalCase.t()]} | {:error, term()}
  defp reverse_cases({:ok, cases}), do: {:ok, Enum.reverse(cases)}
  defp reverse_cases({:error, _reason} = error), do: error

  @spec reverse_evaluations({:ok, [result()]} | {:error, term()}) ::
          {:ok, [result()]} | {:error, term()}
  defp reverse_evaluations({:ok, results}), do: {:ok, Enum.reverse(results)}
  defp reverse_evaluations({:error, _reason} = error), do: error

  @spec decide(Loader.loaded(), EvalCase.t(), Rehearsability.agent_snapshot()) ::
          {:ok, result()} | {:error, term()}
  defp decide(loaded, %EvalCase{} = evaluation_case, agent_snapshot) do
    started_at = System.monotonic_time()

    with {:ok, context} <- evaluation_context(evaluation_case, loaded.surface),
         {:ok, input} <- normalize_input(agent_snapshot, evaluation_case.input) do
      observed =
        loaded
        |> observe(evaluation_case, input, context)
        |> Map.put(:duration_us, elapsed_us(started_at))

      {:ok,
       %{
         case_id: evaluation_case.id,
         passed: expectation_met?(evaluation_case, observed)
       }}
    end
  end

  @spec observe(Loader.loaded(), EvalCase.t(), Input.t(), map()) :: observation()
  defp observe(loaded, %EvalCase{state: state}, input, context) do
    runtime = loaded.runtime
    runtime_result = Runtime.respond(runtime, input, context, expected_revision: runtime.revision)
    state = State.new(state)
    input = Input.new(input)

    case runtime_result do
      {:ok, response, _runtime} ->
        runtime_observation(loaded.agent, state, input, response)

      {:error, :runtime_skill_route_not_found} ->
        loaded.agent
        |> compiled_observation(state, input)
        |> Map.delete(:accepted?)

      {:error, _reason} ->
        error_observation()
    end
  end

  @spec runtime_observation(module(), State.t(), Input.t(), Runtime.Response.t()) :: observation()
  defp runtime_observation(agent, state, input, response) do
    case SkillDispatch.compiled_deterministic_route(agent, state, input) do
      {:ok, _label} ->
        error_observation()

      :not_found ->
        %{
          outcome: :route,
          route: EvalCase.canonical(response.route_label),
          strategy: "RUNTIME_SKILL",
          llm_called?: false,
          output: response.output
        }
    end
  end

  @spec compiled_observation(module(), State.t(), Input.t()) :: observation()
  defp compiled_observation(agent, state, input) do
    {:ok, %RouterReceipt{} = receipt} =
      Router.evaluate(agent, input, state: state, input_pipeline: [])

    %{
      outcome: receipt.outcome,
      route: EvalCase.canonical(receipt.label),
      strategy: EvalCase.canonical(receipt.strategy),
      llm_called?: receipt.llm_called? == true,
      output: nil,
      accepted?: receipt.accepted? == true
    }
  end

  @spec error_observation() :: observation()
  defp error_observation do
    %{outcome: :error, route: nil, strategy: nil, llm_called?: false, output: nil}
  end

  @spec expectation_met?(EvalCase.t(), observation()) :: boolean()
  defp expectation_met?(evaluation_case, observed) do
    routes = EvalCase.expected_routes(evaluation_case)

    evaluation_case.expected_outcome == observed.outcome and
      route_expectation_met?(routes, observed.route) and
      strategy_expectation_met?(evaluation_case.expected_strategy, observed.strategy) and
      llm_expectation_met?(evaluation_case.llm, observed.llm_called?) and
      duration_expectation_met?(evaluation_case.max_duration_us, observed.duration_us) and
      output_expectation_met?(evaluation_case.expected_output, observed.output)
  end

  @spec route_expectation_met?([String.t()], String.t() | nil) :: boolean()
  defp route_expectation_met?([], _observed), do: true
  defp route_expectation_met?(routes, observed), do: observed in routes

  @spec strategy_expectation_met?(String.t() | nil, String.t() | nil) :: boolean()
  defp strategy_expectation_met?(nil, _observed), do: true

  defp strategy_expectation_met?(expected, observed),
    do: EvalCase.canonical(expected) == observed

  @spec duration_expectation_met?(pos_integer() | nil, non_neg_integer()) :: boolean()
  defp duration_expectation_met?(nil, _observed), do: true
  defp duration_expectation_met?(maximum, observed), do: observed <= maximum

  @spec output_expectation_met?(String.t() | nil, String.t() | nil) :: boolean()
  defp output_expectation_met?(nil, _observed), do: true
  defp output_expectation_met?(expected, observed), do: expected == observed

  @spec llm_expectation_met?(:forbidden | :required | :allowed, boolean()) :: boolean()
  defp llm_expectation_met?(:forbidden, called?), do: called? == false
  defp llm_expectation_met?(:required, called?), do: called? == true
  defp llm_expectation_met?(:allowed, _called?), do: true

  @spec normalize_input(Rehearsability.agent_snapshot(), String.t() | map()) ::
          {:ok, Input.t()} | {:error, term()}
  defp normalize_input(agent_snapshot, input) do
    specs = Keyword.get(agent_snapshot.config, :input_pipeline, [])
    input = Input.new(input)

    normalized =
      if specs in [nil, false, []] do
        {:ok, input}
      else
        Pipeline.run(input, %{agent: agent_snapshot.agent, opts: []}, specs)
      end

    with {:ok, input} <- normalized,
         :ok <- input_size(input, Keyword.get(agent_snapshot.config, :input_max_bytes, 64_000)) do
      {:ok, input}
    end
  rescue
    error -> {:error, {:declarative_checker_input_pipeline_failed, error.__struct__}}
  catch
    kind, _reason -> {:error, {:declarative_checker_input_pipeline_failed, kind}}
  end

  @spec input_size(Input.t(), term()) :: :ok | {:error, term()}
  defp input_size(%Input{text: text}, max_bytes) when is_binary(text) do
    if is_integer(max_bytes) and max_bytes > 0 and byte_size(text) <= max_bytes,
      do: :ok,
      else: {:error, {:payload_too_large, :input, byte_size(text), max_bytes}}
  end

  @spec elapsed_us(integer()) :: non_neg_integer()
  defp elapsed_us(started_at) do
    System.monotonic_time()
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :microsecond)
    |> max(0)
  end

  @spec evaluation_context(EvalCase.t(), Spectre.Morph.Surface.t()) ::
          {:ok, map()} | {:error, term()}
  defp evaluation_context(%EvalCase{context: context}, _surface) when map_size(context) > 0,
    do: {:ok, context}

  defp evaluation_context(%EvalCase{}, %{scope_ceiling: [scope]}),
    do: {:ok, %{"scope" => scope}}

  defp evaluation_context(%EvalCase{}, %{scope_ceiling: scopes}),
    do: {:error, {:declarative_eval_context_required, scopes}}
end
