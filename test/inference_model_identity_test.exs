defmodule SpectreInferenceModelIdentityTest do
  use ExUnit.Case, async: true

  alias Spectre.Inference.ModelIdentity

  test "model identity recursively removes credentials from portable containers" do
    identity = %{
      model: "reasoning-model",
      api_key: "secret",
      options: [
        {"token", "secret"},
        {:safe, %{password: "secret", temperature: 0.2}},
        {:tuple, 42, %{authorization: "secret", region: "eu"}}
      ],
      endpoint: %URI{
        scheme: "https",
        userinfo: "admin:password",
        host: "example.test",
        path: "/v1"
      }
    }

    assert %{
             model: "reasoning-model",
             options: [
               {:safe, %{temperature: 0.2}},
               {:tuple, 42, %{region: "eu"}}
             ],
             endpoint: {:struct, URI, endpoint}
           } = ModelIdentity.sanitize(identity)

    assert endpoint.scheme == "https"
    assert endpoint.host == "example.test"
    refute Map.has_key?(endpoint, :userinfo)
    refute inspect(ModelIdentity.sanitize(identity)) =~ "admin:password"
  end

  test "credentialed endpoint strings lose userinfo without rewriting ordinary identities" do
    identity = %{
      model: "provider:reasoning-model",
      endpoint: "https://admin:password@example.test/v1?region=eu",
      fallbacks: ["//service:token@fallback.test/inference", "not a URI"]
    }

    assert %{
             model: "provider:reasoning-model",
             endpoint: "https://example.test/v1?region=eu",
             fallbacks: ["//fallback.test/inference", "not a URI"]
           } = ModelIdentity.sanitize(identity)

    sanitized = inspect(ModelIdentity.sanitize(identity))
    refute sanitized =~ "admin:password"
    refute sanitized =~ "service:token"
  end
end
