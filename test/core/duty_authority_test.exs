defmodule Spectre.Core.DutyAuthorityTest do
  use ExUnit.Case, async: true

  alias Spectre.{Act, Duty, Mandate, Portable, Principal}
  alias Spectre.Duty.{Authority, Derive}

  # Typed inputs to the independence algebra, not an alternative admission
  # path. Kernel/Fold remain responsible for ordinary Mandate coverage.
  setup do
    {:ok, reviewer} = Principal.new(kind: :human, attributes: %{"role" => "reviewer"})
    root = mandate("review-root", nil)
    leaf = mandate("review-leaf", root.ref)

    cause =
      act(%{
        proposer_ref: "causal-agent",
        authenticated_principal_ref: "causal-agent",
        authorizer_ref: "causal-grantor",
        accountable_ref: "causal-owner",
        mandate_ref: "mandate:cause"
      })

    {:ok, duty} =
      Duty.new(%{
        class: :ambiguous_outcome,
        act_ref: cause.ref,
        mandate_ref: cause.mandate_ref,
        accountable: cause.accountable_ref,
        disposition_authority_refs: [reviewer.ref],
        conflict_refs: Derive.conflict_refs(cause.accountable_ref, [], cause),
        opened_at: 100
      })

    disposition =
      act(%{
        proposer_ref: reviewer.ref,
        authenticated_principal_ref: reviewer.ref,
        mandate_ref: leaf.ref
      })

    c = %{
      reviewer: reviewer,
      root: root,
      leaf: leaf,
      cause: cause,
      duty: duty,
      disposition: disposition,
      principals: %{reviewer.ref => reviewer},
      mandates: %{root.ref => root, leaf.ref => leaf}
    }

    assert validate(c) == :ok
    c
  end

  test "a named independent Principal may use an independent delegated route", c do
    assert validate(c) == :ok
    assert c.disposition.proposer_ref == c.reviewer.ref
    assert c.leaf.parent_ref == c.root.ref
  end

  test "an exact named Mandate is an alternative to a named Principal", c do
    c = %{c | duty: %{c.duty | disposition_authority_refs: [c.leaf.ref]}, principals: %{}}
    assert validate(c) == :ok
  end

  test "an unnamed authority cannot resolve discretionary debt", c do
    assert {:error, {:duty_disposition_authority_not_named, _}} =
             validate(%{c | duty: %{c.duty | disposition_authority_refs: []}})
  end

  test "listing a principal ref without a known Principal is not authority", c do
    assert {:error, {:duty_disposition_authority_mismatch, _, _}} =
             validate(%{c | principals: %{}})
  end

  test "listing a parent Mandate does not silently name all descendants", c do
    c = %{c | duty: %{c.duty | disposition_authority_refs: [c.root.ref]}}
    assert {:error, {:duty_disposition_authority_mismatch, _, _}} = validate(c)
  end

  test "one valid named route suffices despite unrelated route names", c do
    c = %{c | duty: %{c.duty | disposition_authority_refs: ["absent", c.reviewer.ref]}}
    assert validate(c) == :ok
  end

  for field <- [:proposer_ref, :authenticated_principal_ref] do
    test "a named Principal cannot be used with a different #{field}", c do
      disposition = replace_act(c.disposition, %{unquote(field) => "another-reviewer"})

      assert {:error, {:duty_disposition_authority_mismatch, _, _}} =
               validate(%{c | disposition: disposition})
    end
  end

  for field <- [:proposer_ref, :authenticated_principal_ref, :authorizer_ref, :accountable_ref] do
    test "a conflicted #{field} cannot hide behind an exact named Mandate", c do
      c = %{
        c
        | duty: %{c.duty | disposition_authority_refs: [c.leaf.ref]},
          disposition: replace_act(c.disposition, %{unquote(field) => "causal-owner"})
      }

      assert {:error, {:duty_disposition_not_independent, _, "causal-owner"}} = validate(c)
    end
  end

  test "cause Act identity cannot be substituted", c do
    cause = replace_act(c.cause, %{candidate_identity_key: "another-cause"})
    assert {:error, {:duty_cause_act_mismatch, _, _}} = validate(%{c | cause: cause})
  end

  test "the frozen causal Mandate cannot be substituted", c do
    assert {:error, {:duty_cause_mandate_mismatch, _, _}} =
             validate(%{c | duty: %{c.duty | mandate_ref: "another-mandate"}})
  end

  test "a named causal Act cannot disappear from the authority check", c do
    assert {:error, {:duty_cause_act_not_found, _}} = validate(%{c | cause: nil})
  end

  for role <- [:proposer_ref, :authorizer_ref, :accountable_ref, :mandate_ref] do
    test "the #{role} of the cause must remain in frozen conflicts", c do
      ref = Map.fetch!(c.cause, unquote(role))
      duty = %{c.duty | conflict_refs: List.delete(c.duty.conflict_refs, ref)}
      assert {:error, {:duty_causal_conflict_not_frozen, _, ^ref}} = validate(%{c | duty: duty})
    end
  end

  test "extra conflicts remain binding even if they are not causal Act roles", c do
    duty = %{c.duty | conflict_refs: [c.reviewer.ref | c.duty.conflict_refs]}
    assert {:error, {:duty_disposition_not_independent, _, ref}} = validate(%{c | duty: duty})
    assert ref == c.reviewer.ref
  end

  for {level, field} <- [
        {:leaf, :grantor_ref},
        {:leaf, :holder_ref},
        {:leaf, :accountable_ref},
        {:root, :grantor_ref},
        {:root, :holder_ref},
        {:root, :accountable_ref}
      ] do
    test "a conflicted #{field} at the #{level} cannot launder disposition authority", c do
      # Deliberately corrupt the disposable route to isolate its independence
      # checks; this is not presented as a valid delegated ledger history.
      route = Map.fetch!(c, unquote(level))
      route = Map.put(route, unquote(field), "causal-owner")
      c = %{c | mandates: Map.put(c.mandates, route.ref, route)}

      assert {:error, {:duty_disposition_mandate_route_not_independent, _, ref, "causal-owner"}} =
               validate(c)

      assert ref == route.ref
    end
  end

  test "a route descending from the cause is never independent", c do
    causal = %{c.root | ref: c.cause.mandate_ref}
    leaf = %{c.leaf | parent_ref: causal.ref}
    c = %{c | mandates: %{causal.ref => causal, leaf.ref => leaf}}
    assert {:error, {:duty_disposition_mandate_descends_from_cause, _, ref}} = validate(c)
    assert ref == causal.ref
  end

  test "a missing leaf is a typed authority history error", c do
    assert {:error, {:duty_disposition_mandate_not_found, _, ref}} =
             validate(%{c | mandates: Map.delete(c.mandates, c.leaf.ref)})

    assert ref == c.leaf.ref
  end

  test "a missing ancestor cannot be mistaken for an independent root", c do
    assert {:error, {:duty_disposition_mandate_not_found, _, ref}} =
             validate(%{c | mandates: Map.delete(c.mandates, c.root.ref)})

    assert ref == c.root.ref
  end

  test "canonical maps must be decoded before entering the authority algebra", c do
    mandates = Map.put(c.mandates, c.leaf.ref, Mandate.canonical(c.leaf))

    assert {:error, {:invalid_duty_disposition_mandate, _, _}} =
             validate(%{c | mandates: mandates})
  end

  test "a cyclic disposition route fails closed", c do
    root = %{c.root | parent_ref: c.leaf.ref}

    assert {:error, {:duty_disposition_mandate_ancestry_cycle, _, _}} =
             validate(%{c | mandates: Map.put(c.mandates, root.ref, root)})
  end

  test "unrelated corrupt routes do not disable an independent disposition", c do
    assert validate(%{c | mandates: Map.put(c.mandates, "unrelated", :corrupt)}) == :ok
  end

  test "an Evidence-born Duty can retain a causal Mandate without inventing an Act", c do
    duty = %{c.duty | act_ref: nil}
    assert validate(%{c | duty: duty, cause: nil}) == :ok
    duty = %{duty | conflict_refs: List.delete(duty.conflict_refs, duty.mandate_ref)}

    assert {:error, {:duty_causal_conflict_not_frozen, _, _}} =
             validate(%{c | duty: duty, cause: nil})
  end

  test "a Duty without causal Act or Mandate still protects its accountable principal", c do
    duty = %{c.duty | act_ref: nil, mandate_ref: nil, conflict_refs: ["causal-owner"]}
    assert validate(%{c | duty: duty, cause: nil}) == :ok
    disposition = replace_act(c.disposition, %{accountable_ref: "causal-owner"})

    assert {:error, {:duty_disposition_not_independent, _, "causal-owner"}} =
             validate(%{c | duty: duty, cause: nil, disposition: disposition})
  end

  test "an index alias cannot substitute a different Principal for the named reviewer", c do
    {:ok, other} = Principal.new(kind: :human, attributes: %{"role" => "unrelated"})

    assert {:error, {:duty_disposition_authority_mismatch, _, _}} =
             validate(%{c | principals: %{c.reviewer.ref => other}})
  end

  test "an index alias cannot substitute a different leaf on a Principal-named route", c do
    assert {:error, {:invalid_duty_disposition_mandate, _, _}} =
             validate(%{c | mandates: Map.put(c.mandates, c.leaf.ref, c.root)})
  end

  test "a named causal Act remains required even if the Duty has no causal Mandate", c do
    duty = %{c.duty | mandate_ref: nil}
    assert {:error, {:duty_cause_act_not_found, _}} = validate(%{c | duty: duty, cause: nil})
  end

  test "an aliased Mandate cannot satisfy an exact Mandate-named route", c do
    duty = %{c.duty | disposition_authority_refs: [c.leaf.ref]}
    mandates = Map.put(c.mandates, c.leaf.ref, c.root)

    assert {:error, {:duty_disposition_authority_mismatch, _, _}} =
             validate(%{c | duty: duty, mandates: mandates})
  end

  test "a distinct authenticated causal actor must also be frozen", c do
    cause = replace_act(c.cause, %{authenticated_principal_ref: "causal-authenticator"})

    duty = %{
      c.duty
      | act_ref: cause.ref,
        conflict_refs: Derive.conflict_refs(cause.accountable_ref, [], cause)
    }

    c = %{c | cause: cause, duty: duty}
    assert validate(c) == :ok
    duty = %{duty | conflict_refs: List.delete(duty.conflict_refs, "causal-authenticator")}

    assert {:error, {:duty_causal_conflict_not_frozen, _, "causal-authenticator"}} =
             validate(%{c | duty: duty})
  end

  defp validate(c),
    do: Authority.validate(c.duty, c.disposition, c.cause, c.principals, c.mandates)

  defp replace_act(act, attrs),
    do: act |> Map.from_struct() |> Map.delete(:ref) |> Map.merge(attrs) |> act()

  defp act(attrs) do
    {:ok, act} =
      Act.new(
        Map.merge(
          %{
            decision_ref: "decision",
            candidate_identity_key: "disposition",
            submission_context_ref: "context",
            authenticated_principal_ref: "reviewer",
            authentication_ref: "authentication",
            ingress_ref: "ingress",
            host_generation: 1,
            class: "duty.dispose",
            row: %{govern: true},
            consequence: %{},
            material_digest: Portable.digest!(%{}),
            proposer_ref: "reviewer",
            executor_ref: "executor",
            authorizer_ref: "review-grantor",
            accountable_ref: "review-owner",
            scope_ref: "scope",
            purpose_ref: "purpose",
            mandate_ref: "review-mandate",
            mandate_revision: 1,
            host_profile_ref: "profile",
            surface_revision: 1,
            executor_contract_ref: "contract",
            committed_at: 100
          },
          attrs
        )
      )

    act
  end

  defp mandate(name, parent) do
    {:ok, mandate} =
      Mandate.new(%{
        grantor_ref: "review-grantor",
        holder_ref: name,
        accountable_ref: "review-owner",
        executor_refs: ["executor"],
        executor_contract_refs: ["contract"],
        scope_refs: ["scope"],
        classes: ["duty.dispose"],
        ceiling: %{govern: true},
        purpose_ref: "purpose",
        not_before: 90,
        expires_at: 200,
        parent_ref: parent,
        revocation: %{"mode" => :cascade, "controller_refs" => ["review-grantor"]},
        source_ref: "genesis"
      })

    mandate
  end
end
