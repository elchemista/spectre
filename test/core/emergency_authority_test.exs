defmodule Spectre.Core.EmergencyAuthorityTest do
  use ExUnit.Case, async: true

  alias Spectre.{Genesis, Mandate}
  alias Spectre.GovernedAct.Emergency

  setup do
    mandate = mandate()

    %{
      mandate: mandate,
      genesis: genesis(mandate),
      index: %{mandate.ref => mandate},
      rules: %{"emergency_max_duration_ms" => 100}
    }
  end

  test "no emergency Mandate requires no implicit emergency policy", c do
    assert :ok = Emergency.validate(%{c.genesis | emergency_mandate_ref: nil}, %{}, %{})
  end

  test "a finite, non-delegable application Mandate can be explicitly designated", c do
    assert :ok = Emergency.validate(c.genesis, c.index, c.rules)
  end

  test "the maximum duration includes the exact upper boundary", c do
    assert :ok = Emergency.validate(c.genesis, c.index, %{"emergency_max_duration_ms" => 100})

    assert {:error, :emergency_mandate_duration_exceeded} =
             Emergency.validate(c.genesis, c.index, %{"emergency_max_duration_ms" => 99})
  end

  test "the whole validity window counts, not just time since Genesis", c do
    extended = mandate(not_before: 89)
    assert {:error, :emergency_mandate_duration_exceeded} = validate(extended, c.rules)
  end

  test "a designated emergency cannot omit its constitutional duration limit", c do
    assert {:error, :emergency_max_duration_required} =
             Emergency.validate(c.genesis, c.index, %{})
  end

  test "non-positive, floating and textual duration limits are not integer lifetimes", c do
    for invalid <- [0, -1, 100.0, "100", true] do
      assert {:error, :invalid_emergency_max_duration_ms} =
               Emergency.validate(c.genesis, c.index, %{"emergency_max_duration_ms" => invalid})
    end
  end

  test "Constitution's supported key spellings do not change the lifetime", c do
    assert :ok = Emergency.validate(c.genesis, c.index, %{emergency_max_duration_ms: 100})
  end

  test "a missing designated Mandate cannot silently disable the emergency checks", c do
    assert {:error, :genesis_emergency_mandate_missing} =
             Emergency.validate(c.genesis, %{}, c.rules)
  end

  test "a different Mandate under the selected key is not the designated exception", c do
    other = mandate(holder_ref: "other")

    assert {:error, :invalid_genesis_emergency_mandate} =
             Emergency.validate(c.genesis, %{c.mandate.ref => other}, c.rules)
  end

  test "unrestored maps cannot masquerade as the typed emergency Mandate", c do
    assert {:error, :invalid_genesis_emergency_mandate} =
             Emergency.validate(
               c.genesis,
               %{c.mandate.ref => Mandate.canonical(c.mandate)},
               c.rules
             )
  end

  test "emergency authority cannot delegate even a single level", c do
    delegating = mandate(delegation: %{"allowed" => true, "max_depth" => 1})
    assert {:error, :emergency_mandate_may_not_delegate} = validate(delegating, c.rules)
  end

  for class <-
        ~w(mandate.delegate mandate.restrict surface.revise host_profile.revise definition.revise) do
    test "emergency authority cannot include #{class}", c do
      expanded = mandate(classes: ["app.recover", unquote(class)])
      assert {:error, :emergency_mandate_may_not_rewrite_exception} = validate(expanded, c.rules)
    end
  end

  test "application class names are not rejected by prefix matching", c do
    bounded = mandate(classes: ["myapp.definition.revise.report"])
    assert :ok = validate(bounded, c.rules)
  end

  test "the exception validator does not ban unrelated ordinary Mandates", c do
    ordinary = mandate(holder_ref: "ordinary", classes: ["surface.revise"])
    assert :ok = Emergency.validate(c.genesis, Map.put(c.index, ordinary.ref, ordinary), c.rules)
  end

  defp validate(mandate, rules),
    do: Emergency.validate(genesis(mandate), %{mandate.ref => mandate}, rules)

  defp mandate(overrides \\ []) do
    {:ok, mandate} =
      Mandate.new(
        Map.merge(
          %{
            grantor_ref: "root",
            holder_ref: "operator",
            accountable_ref: "owner",
            executor_refs: ["executor"],
            executor_contract_refs: ["contract"],
            scope_refs: ["scope"],
            classes: ["app.recover"],
            ceiling: %{write: true},
            purpose_ref: "recovery",
            purpose_params: %{},
            not_before: 90,
            expires_at: 190,
            source_ref: "genesis"
          },
          Map.new(overrides)
        )
      )

    mandate
  end

  defp genesis(mandate) do
    {:ok, genesis} =
      Genesis.new(%{
        ref: "genesis",
        domain_ref: "domain",
        principal_refs: ["operator"],
        root_mandate_refs: [mandate.ref],
        constitution_ref: "constitution",
        surface_ref: "surface",
        surface_revision: 1,
        host_profile_ref: "host-profile",
        emergency_mandate_ref: mandate.ref,
        issued_at: 100,
        attestation_ref: "attestation"
      })

    genesis
  end
end
