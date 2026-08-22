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
      endpoint: %URI{scheme: "https", host: "example.test", path: "/v1"}
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
  end
end
