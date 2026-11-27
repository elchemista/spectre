defmodule Spectre.Server.ManagedIdentityTest do
  use ExUnit.Case, async: true
  alias Spectre.Server.GAM.Managed.Identity

  test "known string keys normalize without discarding tenant and organization" do
    identity = %{"subject" => "42", "org" => "agency", tenant: "north"}

    assert {:ok, %{org: "agency", subject: "42", tenant: "north"}} =
             Identity.normalize(identity)

    assert {:ok, other} = Identity.normalize(Map.put(identity, :tenant, "south"))
    assert {:ok, first} = Identity.normalize(identity)

    refute ExGAM.Canonical.Value.digest!(first) ==
             ExGAM.Canonical.Value.digest!(other)
  end

  test "conflicting alias keys and process handles are rejected" do
    assert {:error, :invalid_managed_identity} =
             Identity.normalize(%{:subject => "a", "subject" => "b"})

    assert {:error, :invalid_managed_identity} = Identity.normalize(%{subject: self()})
    assert {:error, :invalid_managed_identity} = Identity.normalize(nil)
  end

  test "unknown fields and credentials cannot become authority or presented identity" do
    assert {:error, :invalid_managed_identity} =
             Identity.normalize(%{subject: "u", authentication_secret: "secret"})

    assert {:error, :invalid_managed_identity} =
             Identity.normalize(%{"subject" => "u", "api_key" => "secret"})

    assert {:error, :invalid_managed_identity} =
             Identity.normalize(%{subject: "u", unknown: "ignored?"})
  end

  test "equal atom and string keys normalize to a single identity" do
    assert {:ok, %{subject: "a"}} = Identity.normalize(%{:subject => "a", "subject" => "a"})
  end
end
