defmodule SpectreDeclarativeCheckerRefactorTest do
  use ExUnit.Case, async: true

  alias Spectre.Eval.Case, as: EvalCase
  alias Spectre.Governance.CandidateState
  alias Spectre.Governance.Checker.Declarative
  alias Spectre.Governance.Checker.Declarative.Rehearsability

  @doc false
  @spec __spectre_config__() :: keyword()
  def __spectre_config__, do: boundary_reply(:config, [])

  @doc false
  @spec __spectre_router__() :: keyword()
  def __spectre_router__, do: boundary_reply(:router, [])

  @doc false
  @spec __spectre_rules__() :: [map()]
  def __spectre_rules__, do: boundary_reply(:rules, [])

  test "agent callback exceptions become stable checker errors" do
    Process.put(boundary_key(:config), :raise)

    assert {:error,
            {:declarative_checker_agent_callback_failed, :__spectre_config__,
             {:exception, RuntimeError}}} =
             Declarative.run(:unreachable_store, candidate(), [], agent: __MODULE__)
  end

  test "agent callback throws become stable checker errors" do
    Process.put(boundary_key(:router), :throw)

    assert {:error,
            {:declarative_checker_agent_callback_failed, :__spectre_router__, {:signal, :throw}}} =
             Declarative.run(:unreachable_store, candidate(), [], agent: __MODULE__)
  end

  test "definition rule callback failures remain inside the checker boundary" do
    Process.put(boundary_key(:rules), :throw)

    assert {:error,
            {:declarative_checker_agent_callback_failed, :definition_rules,
             {:exception, ArgumentError}}} =
             Declarative.run(:unreachable_store, candidate(), [], agent: __MODULE__)
  end

  test "malformed callback replies fail closed before Store access" do
    Process.put(boundary_key(:config), %{})

    assert {:error,
            {:declarative_checker_agent_callback_failed, :__spectre_config__,
             {:invalid_reply, :map}}} =
             Declarative.run(:unreachable_store, candidate(), [], agent: __MODULE__)
  end

  test "single-pass case contract preserves duration error precedence" do
    state_case = %EvalCase{id: "state-first", state: %{step: 1}}
    duration_case = %EvalCase{id: "duration-second", max_duration_us: 10}

    assert {:error, {:declarative_checker_duration_not_rehearsable, "duration-second"}} =
             Rehearsability.verify_cases([state_case, duration_case])

    assert {:error, {:declarative_checker_state_not_rehearsable, "state-first"}} =
             Rehearsability.verify_cases([state_case])
  end

  @spec candidate() :: %{required(:governance) => CandidateState.t()}
  defp candidate, do: %{governance: struct(CandidateState)}

  @spec boundary_reply(atom(), term()) :: term()
  defp boundary_reply(name, default) do
    case Process.get(boundary_key(name), default) do
      :raise -> raise "checker boundary probe"
      :throw -> throw(:checker_boundary_probe)
      value -> value
    end
  end

  @spec boundary_key(atom()) :: {module(), atom()}
  defp boundary_key(name), do: {__MODULE__, name}
end
