Code.require_file("../helper.exs", __DIR__)

defmodule Spectre.GAM.DefinitionVerifierAdapterTest do
  use ExUnit.Case, async: true

  alias Spectre.GAM.{Definition, Surface}

  defmodule Verifier do
    @behaviour Spectre.GAM.Definition.Verifier

    @impl true
    def verify(surface, definition) do
      {:ok, %{surface_ref: surface.ref, definition_ref: definition.ref, templates: %{}}}
    end
  end

  defmodule CrashingVerifier do
    def verify(_surface, _definition), do: raise("private diagnostic details")
  end

  setup do
    {:ok, surface} = Surface.new(revision: 1, declarations: %{})

    {:ok, definition} =
      Definition.new(namespace: "test", name: "agent", revision: 1, declared_at: 0)

    %{surface: surface, definition: definition}
  end

  test "the kernel requires an explicit authoring verifier", c do
    assert {:error, :definition_verifier_required} =
             Surface.verify_definition(c.surface, c.definition)
  end

  test "the explicit adapter receives validated immutable records", c do
    assert {:ok, report} = Surface.verify_definition(c.surface, c.definition, Verifier)
    assert report.surface_ref == c.surface.ref
    assert report.definition_ref == c.definition.ref
    assert report.templates == %{}
  end

  test "invalid authoring adapters are rejected before invocation", c do
    assert {:error, {:adapter_callback_missing, String, :verify, 2}} =
             Surface.verify_definition(c.surface, c.definition, String)

    assert {:error, {:adapter_callback_exception, CrashingVerifier, :verify, RuntimeError}} =
             Surface.verify_definition(c.surface, c.definition, CrashingVerifier)

    assert {:error, _reason} = Surface.verify_definition(%{}, c.definition, Verifier)
  end
end
