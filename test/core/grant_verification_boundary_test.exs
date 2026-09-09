defmodule Spectre.GrantVerificationBoundaryTest do
  use ExUnit.Case, async: true

  alias Spectre.Kernel.Grant

  setup do
    secret = :crypto.strong_rand_bytes(32)

    claims = %{
      act_ref: "act:one",
      domain_ref: "domain:one",
      executor_ref: "executor:one",
      material_digest: String.duplicate("a", 64),
      nonce: "nonce:one",
      issued_at: 10,
      expires_at: 20,
      generation: 1
    }

    {:ok, grant} = Grant.mint(claims, secret)

    expected =
      claims
      |> Map.take([:act_ref, :domain_ref, :executor_ref, :material_digest, :generation])
      |> Map.put(:now, 11)

    %{secret: secret, grant: grant, expected: expected}
  end

  test "complete authenticated bindings succeed", c do
    assert :ok = Grant.verify(c.grant, c.secret, c.expected)
  end

  for field <- [:act_ref, :domain_ref, :executor_ref, :material_digest, :generation, :now] do
    test "omitting #{field} never turns verification into a partial match", c do
      assert {:error, :invalid_grant} =
               Grant.verify(c.grant, c.secret, Map.delete(c.expected, unquote(field)))
    end
  end

  test "an empty expectation does not authenticate a bearer token", c do
    assert {:error, :invalid_grant} = Grant.verify(c.grant, c.secret, %{})

    assert {:error, :grant_generation_mismatch} =
             Grant.verify(c.grant, c.secret, %{c.expected | generation: 1.0})
  end

  test "time, shape and authentication failures remain distinguishable", c do
    assert {:error, :invalid_grant_material} = Grant.mint(nil, c.secret)
    assert {:error, :invalid_grant} = Grant.verify(nil, c.secret, c.expected)
    assert {:error, :incomplete_grant_material} = Grant.mint(%{}, c.secret)

    assert {:error, :grant_not_yet_valid} =
             Grant.verify(c.grant, c.secret, %{c.expected | now: 9})

    assert {:error, :grant_expired} = Grant.verify(c.grant, c.secret, %{c.expected | now: 20})

    assert {:error, :grant_authentication_failed} =
             Grant.verify(c.grant, :crypto.strong_rand_bytes(32), c.expected)

    assert {:error, :invalid_grant} = Grant.verify(%{c.grant | mac: nil}, c.secret, c.expected)
  end
end
