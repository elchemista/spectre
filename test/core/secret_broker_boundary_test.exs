defmodule Spectre.Core.SecretBrokerBoundaryTest.FixedClock do
  @behaviour Spectre.Clock
  @impl true
  def now, do: 1_000_001
end

defmodule Spectre.Core.SecretBrokerBoundaryTest.InvalidClock do
  @behaviour Spectre.Clock
  @impl true
  def now, do: -1
end

defmodule Spectre.Core.SecretBrokerBoundaryTest.UnavailableClock do
  @behaviour Spectre.Clock
  @impl true
  def now, do: raise("private clock failure")
end

defmodule Spectre.Core.SecretBrokerBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.Portable
  alias Spectre.Secret.Broker.Passthrough
  alias Spectre.Secret.CheckoutReceipt

  alias Spectre.Core.SecretBrokerBoundaryTest.{
    FixedClock,
    InvalidClock,
    UnavailableClock
  }

  setup c do
    secret = :crypto.strong_rand_bytes(32)
    unique = Integer.to_string(System.unique_integer([:positive, :monotonic]))

    attempt = %{
      c.attempt
      | ref: "attempt:broker-boundary:" <> unique,
        grant_nonce_digest: Portable.digest!("broker-nonce:" <> unique)
    }

    claims =
      c.act
      |> CheckoutReceipt.binding(attempt, Passthrough.ref())
      |> Map.merge(%{
        domain_ref: c.f.refs.domain,
        ledger_revision: 1,
        issued_at: 1_000_000,
        expires_at: 1_100_000
      })

    assert {:ok, receipt} = CheckoutReceipt.mint(claims, secret)
    %{attempt: attempt, claims: claims, checkout_receipt: receipt, checkout_secret: secret}
  end

  test "a checkout receipt is exact-bound, current and authenticated", c do
    assert :ok =
             CheckoutReceipt.verify(c.checkout_receipt, c.checkout_secret, %{
               domain_ref: c.f.refs.domain,
               now: FixedClock.now()
             })

    assert {:error, {:checkout_receipt_mismatch, :domain_ref}} =
             CheckoutReceipt.verify(c.checkout_receipt, c.checkout_secret, %{
               domain_ref: "foreign-domain",
               now: FixedClock.now()
             })

    assert {:error, :invalid_checkout_receipt_time} =
             CheckoutReceipt.verify(c.checkout_receipt, c.checkout_secret, %{now: :untrusted})

    forged = %{c.checkout_receipt | mac: String.duplicate("0", 64)}

    assert {:error, :checkout_receipt_authentication_failed} =
             CheckoutReceipt.verify(forged, c.checkout_secret, %{now: FixedClock.now()})
  end

  test "malformed receipt material never becomes a partial bearer credential", c do
    assert {:error, :invalid_checkout_receipt_material} =
             CheckoutReceipt.mint(:not_claims, c.checkout_secret)

    assert {:error, :invalid_checkout_receipt_material} =
             CheckoutReceipt.mint(c.claims, "short")

    assert {:error, :incomplete_checkout_receipt} =
             CheckoutReceipt.mint(Map.delete(c.claims, :broker_ref), c.checkout_secret)

    assert {:error, :invalid_checkout_receipt} =
             CheckoutReceipt.verify(:not_a_receipt, c.checkout_secret, %{now: FixedClock.now()})
  end

  test "the development broker claims a valid receipt exactly once", c do
    opts = broker_options(c, FixedClock)

    assert {:ok, {:private_capability, c.act.ref}} ==
             Passthrough.checkout(c.checkout_receipt, c.act, c.attempt, opts)

    assert {:error, :ambiguous, %{evidence: [], details_ref: details_ref}} =
             Passthrough.checkout(c.checkout_receipt, c.act, c.attempt, opts)

    assert details_ref == "spectre:secret-broker:passthrough:checkout-refused:v1"
  end

  test "broker option and clock failures fail closed without private diagnostics", c do
    assert {:error, :ambiguous, %{evidence: [], details_ref: _}} =
             Passthrough.checkout(:not_a_receipt, c.act, c.attempt, [])

    for opts <- [
          Keyword.delete(broker_options(c, FixedClock), :checkout_receipt_secret),
          Keyword.delete(broker_options(c, FixedClock), :domain_ref),
          broker_options(c, Enum),
          broker_options(c, InvalidClock),
          broker_options(c, UnavailableClock)
        ] do
      assert {:error, :ambiguous, %{evidence: [], details_ref: _}} =
               Passthrough.checkout(c.checkout_receipt, c.act, c.attempt, opts)
    end
  end

  defp broker_options(c, clock) do
    [
      capability: {:private_capability, c.act.ref},
      checkout_receipt_secret: c.checkout_secret,
      domain_ref: c.f.refs.domain,
      clock: clock
    ]
  end
end
