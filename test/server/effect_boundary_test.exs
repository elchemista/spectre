defmodule Spectre.Server.EffectBoundaryTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.GAM.Effect

  defmodule Adapter do
    def effect_schema(:deliver, _), do: {:ok, "schema:v1"}
    def execute_effect(:deliver, %{mode: :raise}, _), do: raise("PRIVATE")
    def execute_effect(:deliver, %{mode: :throw}, _), do: throw(:private)
    def execute_effect(:deliver, %{mode: :bad_receipt}, _), do: {:ok, self()}
    def execute_effect(:deliver, %{mode: :bad_error}, _), do: {:error, :ambiguous, self()}
    def execute_effect(:deliver, %{mode: :invalid}, _), do: :invalid
    def execute_effect(:deliver, _, _), do: {:ok, %{accepted: true}}
  end

  defmodule Package do
    use Spectre.Stack.Installable, id: :effect_boundary, version: "0.1.0", spectre: "~> 0.4.0"

    def effects(_),
      do: %{
        {:mail, :send} => %{
          contract: 1,
          adapter: Adapter,
          operation: :deliver,
          side_effect: :non_idempotent,
          material: :arguments,
          partition: [:subject, :flow],
          schema_hash: nil,
          config: %{}
        }
      }
  end

  defmodule Stack do
    use Spectre.Stack
    install(Package)
  end

  defmodule App do
    use Spectre.Server
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: App
  end

  defmodule NoStack do
    use Spectre.Agent
  end

  test "resolution fences schema metadata and execution rechecks the frozen contract" do
    assert {:ok, effect} =
             Effect.resolve(Agent, {{:skill, :mail}, :mail, :send}, %{schema_hash: "schema:v1"})

    assert effect.schema_hash == "schema:v1"

    assert {:error, :effect_schema_mismatch} =
             Effect.resolve(Agent, {:mail, :send}, %{schema_hash: "old"})

    assert {:error, :invalid_effect_metadata} = Effect.resolve(Agent, {:mail, :send}, :invalid)
    assert {:error, {:unregistered_effect, :unknown}} = Effect.resolve(Agent, :unknown)
    assert {:error, :agent_has_no_stack} = Effect.catalog(NoStack)
    assert {:error, _} = Effect.catalog(__MODULE__)

    context = %{agent: Agent, identity: %{subject: "human"}, current_flow: :mail}
    assert {:ok, %{accepted: true}} = Effect.execute(effect, %{}, context)

    assert {:error, :definitive_no_effect, :effect_contract_changed} =
             Effect.execute(%{effect | contract_ref: "stale"}, %{}, context)

    assert {:error, :definitive_no_effect, {:effect_identity_required, :subject}} =
             Effect.execute(effect, %{}, %{context | identity: %{}})

    assert {:error, :definitive_no_effect, {:effect_identity_required, :flow}} =
             Effect.execute(effect, %{}, %{context | current_flow: nil})

    assert {:error, :definitive_no_effect, _} = Effect.execute(effect, %{secret: self()}, context)

    assert {:error, :definitive_no_effect, :invalid_effect_execution} =
             Effect.execute(nil, %{}, context)
  end

  test "adapter failures and invalid receipts preserve uncertainty without leaking private values" do
    {:ok, effect} = Effect.resolve(Agent, {:mail, :send})
    context = %{agent: Agent, identity: %{subject: "human"}, current_flow: :mail}

    for {mode, reason} <- [
          raise: :effect_adapter_exception,
          throw: :effect_adapter_failure,
          bad_receipt: :effect_receipt_not_portable,
          bad_error: :effect_error_details_unavailable,
          invalid: :invalid_effect_adapter_result
        ] do
      assert {:error, :ambiguous, ^reason} = Effect.execute(effect, %{mode: mode}, context)
    end
  end
end
