defmodule Spectre.Router.Adapter do
  @moduledoc """
  Extension point for proposal routing, entirely in GAM Zone M.

      defmodule MyApp.BinaryMatcher do
        use Spectre.Router.Adapter

        @impl true
        def evaluate(request, _opts) do
          {:ok, for rule <- request.rules, rule.data == request.input,
            do: result(rule, 1.0)}
        end
      end

  Register it in host configuration with `adapters: [binary: MyApp.BinaryMatcher]`
  and select it with `via: [:binary]`. A callback sees only the explicitly supplied
  input and its own rule data, not the Turn, Scope, candidate templates, executor
  handles or other matchers' data. It can nominate only visible rule references.

  `prepare/2` optionally compiles each rule's portable data once at router creation.
  `evaluate/2` returns at most 32 distinct scored rules. Scores are between zero
  and one; `matched` is optional portable diagnostic data, never authority.
  The host must govern any external inference separately: this callback is not
  permission to call a model or external service. Same-BEAM code is not sandboxed.
  """

  defmodule Request do
    @moduledoc "Minimal, explicitly supplied input visible to one routing method."
    @enforce_keys [:input, :rules]
    defstruct [:input, :rules]
    @type t :: %__MODULE__{input: term(), rules: [%{ref: String.t(), data: term()}]}
  end

  @type result :: %{
          required(:rule) => String.t(),
          required(:score) => number(),
          optional(:matched) => term()
        }
  @callback prepare(term(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback evaluate(Request.t(), keyword()) :: {:ok, [result()]} | :skip | {:error, term()}
  @optional_callbacks prepare: 2

  defmacro __using__(opts) do
    if opts != [],
      do:
        raise(ArgumentError, "router methods are configured in Router.new/2, not in use options")

    quote do
      @behaviour Spectre.Router.Adapter
      import Spectre.Router.Adapter, only: [result: 2, result: 3]
    end
  end

  @doc "Nominates a visible rule without exposing its target Candidate template."
  @spec result(map() | String.t(), number(), term()) :: result()
  def result(rule, score, matched \\ nil)
  def result(%{ref: ref}, score, matched), do: result(ref, score, matched)
  def result(ref, score, matched), do: %{rule: ref, score: score, matched: matched}
end
