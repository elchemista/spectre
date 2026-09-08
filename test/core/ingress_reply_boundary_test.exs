defmodule Spectre.Core.IngressReplyBoundaryTest.Adapter do
  use Spectre.Ingress, ref: "ingress:reply-boundary"
  @impl true
  def authenticate(_, _, {:return, reply}, _, _), do: reply
  def authenticate(_, _, :raise_authentication, _, _), do: raise("private identity data")
  def authenticate(_, _, :throw_authentication, _, _), do: throw("private identity data")
  def authenticate(_, _, :exit_authentication, _, _), do: exit("private identity data")
  def authenticate(_, _, _, _, _), do: {:error, :not_used}
  @impl true
  def observe(_, {:return, reply}, _, _), do: reply
  def observe(_, :raise, _, _), do: raise("private source data")
  def observe(_, :throw, _, _), do: throw("private source data")
  def observe(_, :exit, _, _), do: exit("private source data")
end

defmodule Spectre.Core.IngressReplyBoundaryTest.BadRef do
  def ref, do: %{secret: "invalid reference"}
  def authenticate(_, _, _, _, _), do: {:error, :not_used}
  def observe(_, _, _, _), do: {:error, :not_used}
end

defmodule Spectre.Core.IngressReplyBoundaryTest.CrashedRef do
  def ref, do: raise("private reference")
  def authenticate(_, _, _, _, _), do: {:error, :not_used}
  def observe(_, _, _, _), do: {:error, :not_used}
end

defmodule Spectre.Core.IngressReplyBoundaryTest do
  use Spectre.Test.GovernedBoundaryCase, async: false

  alias Spectre.{Evidence, Ingress, SubmissionContext}
  alias Spectre.Core.IngressReplyBoundaryTest.{Adapter, BadRef, CrashedRef}
  alias Spectre.Domain.{Context, Sequencer}
  alias Spectre.V04Test.{Fixture, Runtime}

  setup c do
    {:ok, context} =
      SubmissionContext.new(%{Fixture.context(c.f) | ref: nil, ingress_ref: Adapter.ref()})

    {:ok, observed} =
      Ingress.evidence(context, Runtime.now(),
        proposition: "customer.message",
        issuer_ref: context.authenticated_principal_ref,
        payload: %{"text" => "Please refund order 42", "channel" => "authenticated-chat"}
      )

    %{context: context, observed: observed}
  end

  test "a valid observation is normalized to a list and does not itself append", c do
    assert {:ok, {Adapter, "ingress:reply-boundary"}} = Ingress.resolve(Adapter)
    assert {:ok, [record]} = observe(c, {:ok, c.observed})
    assert record === c.observed
    assert Sequencer.projection(c.f.server) === c.attempted
  end

  test "malformed adapter declarations fail before input delivery", c do
    assert {:error, {:invalid_ingress, :map}} = Ingress.resolve(%{token: "private"})

    assert {:error, {:ingress_module_unavailable, __MODULE__.Missing}} =
             Ingress.resolve(__MODULE__.Missing)

    assert {:error, {:ingress_callback_unavailable, Enum, :ref, 0}} = Ingress.resolve(Enum)
    assert {:error, {:invalid_ingress_ref, BadRef, :map}} = Ingress.resolve(BadRef)
    assert {:error, {:ingress_ref_unavailable, CrashedRef}} = Ingress.resolve(CrashedRef)

    assert {:error, :invalid_ingress_observation_options_or_binding} =
             Ingress.observe(Adapter, c.context, nil, Runtime.now(), [:invalid])

    assert {:error, :invalid_ingress_observation_options_or_binding} =
             Ingress.observe(Adapter, Fixture.context(c.f), nil, Runtime.now(), [])

    assert {:error, :invalid_ingress_observation} =
             Ingress.observe(Adapter, c.context, nil, 1.0, [])

    assert {:error, :invalid_ingress_evidence} = Ingress.evidence(nil, Runtime.now(), %{})
  end

  test "empty, duplicate and malformed observation replies are not successful observations", c do
    assert {:error, :empty_ingress_observation} = observe(c, {:ok, []})
    assert {:error, :duplicate_ingress_evidence} = observe(c, {:ok, [c.observed, c.observed]})
    assert {:error, :invalid_ingress_observation_response} = observe(c, :ok)
    assert {:error, :source_unavailable} = observe(c, {:error, :source_unavailable})
  end

  test "authentication callbacks cross one typed and diagnostic-safe boundary", c do
    valid = Fixture.context(c.f)

    assert {:ok, ^valid} = authenticate(c, {:return, {:ok, valid}})

    assert {:error, :identity_unavailable} =
             authenticate(c, {:return, {:error, :identity_unavailable}})

    assert {:error, :invalid_ingress_authentication_response} =
             authenticate(c, {:return, :authenticated})

    assert {:error, {:ingress_authentication_failed, RuntimeError}} =
             authenticate(c, :raise_authentication)

    assert {:error, {:ingress_authentication_failed, :throw}} =
             authenticate(c, :throw_authentication)

    assert {:error, {:ingress_authentication_failed, :exit}} =
             authenticate(c, :exit_authentication)
  end

  test "authentication options reject non-keywords and unknown host policy", c do
    state = :sys.get_state(c.f.server)

    assert {:error, :invalid_authentication_options} =
             Context.authentication_request(state, c.context.scope_ref, :input, %{})

    assert {:error, {:unknown_options, :authentication, [:private_override]}} =
             Context.authentication_request(
               state,
               c.context.scope_ref,
               :input,
               private_override: true
             )
  end

  for {mode, reason} <- [
        {:raise, {:ingress_observation_exception, RuntimeError}},
        {:exit, {:ingress_observation_failure, :exit}},
        {:throw, {:ingress_observation_failure, :throw}}
      ] do
    test "observer #{mode} does not publish private diagnostics", c do
      assert {:error, unquote(Macro.escape(reason))} =
               Ingress.observe(Adapter, c.context, unquote(mode), Runtime.now(), [])

      assert Sequencer.projection(c.f.server) === c.attempted
    end
  end

  for {field, value, tag} <- [
        {:bindings, %{}, :ingress_evidence_context_mismatch},
        {:source_ref, "foreign-ingress", :ingress_evidence_source_mismatch},
        {:provenance, :derived, :ingress_evidence_not_observed},
        {:observed_at, 2_000_000, :ingress_evidence_from_future}
      ] do
    test "a freshly addressed observation cannot forge #{field}", c do
      attrs =
        c.observed
        |> Map.from_struct()
        |> Map.put(:ref, nil)
        |> Map.put(unquote(field), unquote(Macro.escape(value)))

      attrs = if attrs.provenance == :derived, do: %{attrs | parent_refs: ["parent"]}, else: attrs
      assert {:ok, forged} = Evidence.new(attrs)
      assert {:error, reason} = observe(c, {:ok, forged})
      assert elem(reason, 0) == unquote(tag)
      assert elem(reason, 1) == forged.ref
      assert Sequencer.projection(c.f.server) === c.attempted
    end
  end

  test "observed evidence with parents is rejected by record validation before ingress policy",
       c do
    assert {:error, {:observed_evidence_has_parents, _}} =
             observe(c, {:ok, %{c.observed | ref: nil, parent_refs: ["parent"]}})
  end

  defp observe(c, reply),
    do: Ingress.observe(Adapter, c.context, {:return, reply}, Runtime.now(), [])

  defp authenticate(c, input) do
    Context.run_authentication(
      {Adapter, [c.context.domain_ref, c.context.scope_ref, input, c.context.host_generation, []]}
    )
  end
end
