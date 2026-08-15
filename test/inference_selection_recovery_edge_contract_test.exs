defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.GoodModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:ok, "completed"}
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.ErrorModel do
  @moduledoc false

  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:error, :provider_unavailable}
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.Adapter do
  @moduledoc false

  @behaviour Spectre.Inference.StreamAdapter

  @impl Spectre.Inference.StreamAdapter
  def capabilities(_profile, _opts),
    do: MapSet.new([:stream, :pull_transport, :resume, :reconcile])

  @impl Spectre.Inference.StreamAdapter
  def open(_descriptor, _opts), do: {:ok, %{}, %{}}

  @impl Spectre.Inference.StreamAdapter
  def resume(_descriptor, _cursor, _opts), do: {:ok, %{}, %{}}

  @impl Spectre.Inference.StreamAdapter
  def request_transport_item(state), do: {:ok, state}

  @impl Spectre.Inference.StreamAdapter
  def handle_transport(_message, state), do: {:ignore, state}

  @impl Spectre.Inference.StreamAdapter
  def cancel(_state, _reason), do: :ok

  @impl Spectre.Inference.StreamAdapter
  # The fixture deliberately exposes every adapter result class to exercise
  # reconciliation normalization at the trust boundary.
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def reconcile(_descriptor, _provider_request_id, opts) do
    case Keyword.get(opts, :reconcile_mode, :success) do
      :success -> {:ok, %{text: "reconciled"}}
      :pending -> :pending
      :not_found -> :not_found
      :error -> {:error, :reconcile_failed}
      :tuple -> {:unexpected, :reply}
      :atom -> :unexpected
      :map -> %{unexpected: true}
      :list -> [:unexpected]
      :raise -> raise "reconcile failed"
      :throw -> throw({:secret, :reconcile_failed})
    end
  end
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.Selector do
  @moduledoc false

  @behaviour Spectre.Inference.Selector

  @impl Spectre.Inference.Selector
  def select(request, profiles, ctx, _opts) do
    profile = List.first(profiles)

    case Map.get(ctx.assigns, :selection_mode, :valid) do
      :invalid -> {:ok, %{request_id: "", model: profile.model}}
      :unregistered -> {:ok, selection(request, profile, :missing)}
      :valid -> {:ok, selection(request, profile, profile.id)}
    end
  end

  defp selection(request, profile, level) do
    %{
      request_id: request.id,
      level: level,
      model: profile.model,
      reason: :fixture,
      selector: __MODULE__,
      profile_hash: profile.profile_hash,
      attempt: request.attempt
    }
  end
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.Extension do
  @moduledoc false

  @behaviour Spectre.Extension

  alias Spectre.Inference.Profile

  @impl Spectre.Extension
  def id, do: :selection_recovery_edge

  @impl Spectre.Extension
  def inference_selector(_config) do
    profile =
      Profile.new(
        id: :selected,
        rank: 1,
        model: SpectreInferenceSelectionRecoveryEdgeContractTest.GoodModel,
        supports: [:text],
        context_window: 1,
        privacy: :cloud,
        cost_tier: :low,
        latency_tier: :low
      )

    {SpectreInferenceSelectionRecoveryEdgeContractTest.Selector, profiles: [profile]}
  end
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.DuplicateExtension do
  @moduledoc false

  @behaviour Spectre.Extension

  alias Spectre.Inference.Profile

  @impl Spectre.Extension
  def id, do: :duplicate_selection_profiles

  @impl Spectre.Extension
  def inference_selector(_config) do
    profile =
      Profile.new(
        id: :duplicate,
        rank: 1,
        model: SpectreInferenceSelectionRecoveryEdgeContractTest.GoodModel,
        cost_tier: :low,
        latency_tier: :low
      )

    {SpectreInferenceSelectionRecoveryEdgeContractTest.Selector,
     profiles: [profile, %{profile | profile_hash: nil}]}
  end
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.InvalidProfilesExtension do
  @moduledoc false

  @behaviour Spectre.Extension

  @impl Spectre.Extension
  def id, do: :invalid_selection_profiles

  @impl Spectre.Extension
  def inference_selector(_config),
    do: {SpectreInferenceSelectionRecoveryEdgeContractTest.Selector, profiles: :invalid}
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.RaisingPlanner do
  @moduledoc false

  @behaviour Spectre.Action.Planner

  @impl Spectre.Action.Planner
  def plan_response(text, _context, _opts), do: {:ok, %{reply_text: text, actions: []}}

  @impl Spectre.Action.Planner
  def clean_reply(text, _context, _opts), do: text

  @impl Spectre.Action.Planner
  def incremental_cleaner?, do: raise("cleaner capability failed")
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.BareAgent do
  @moduledoc false
  use Spectre.Agent
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.SelectedAgent do
  @moduledoc false
  use Spectre.Agent

  Spectre.Extension.register!(
    __MODULE__,
    SpectreInferenceSelectionRecoveryEdgeContractTest.Extension
  )
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.DuplicateAgent do
  @moduledoc false
  use Spectre.Agent

  Spectre.Extension.register!(
    __MODULE__,
    SpectreInferenceSelectionRecoveryEdgeContractTest.DuplicateExtension
  )
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.InvalidProfilesAgent do
  @moduledoc false
  use Spectre.Agent

  Spectre.Extension.register!(
    __MODULE__,
    SpectreInferenceSelectionRecoveryEdgeContractTest.InvalidProfilesExtension
  )
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest.PlannerAgent do
  @moduledoc false
  use Spectre.Agent
  action_planner(SpectreInferenceSelectionRecoveryEdgeContractTest.RaisingPlanner)
end

defmodule SpectreInferenceSelectionRecoveryEdgeContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Context
  alias Spectre.Inference
  alias Spectre.Inference.Descriptor
  alias Spectre.Inference.FrozenSelection
  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Input
  alias Spectre.Prompt.Plan
  alias Spectre.State

  @adapter SpectreInferenceSelectionRecoveryEdgeContractTest.Adapter
  @bare SpectreInferenceSelectionRecoveryEdgeContractTest.BareAgent
  @selected SpectreInferenceSelectionRecoveryEdgeContractTest.SelectedAgent
  @good SpectreInferenceSelectionRecoveryEdgeContractTest.GoodModel
  @error SpectreInferenceSelectionRecoveryEdgeContractTest.ErrorModel

  test "prepared one-shot execution verifies its frozen binding and normalizes outcomes" do
    assert {:ok, prepared} = Inference.prepare(@bare, request("execute", @good), context(@bare))
    assert {:ok, %Response{text: "completed"}} = Inference.execute(prepared)

    assert {:ok, failed} = Inference.prepare(@bare, request("failure", @error), context(@bare))
    assert {:error, :provider_unavailable} = Inference.execute(failed)

    mismatched = %{
      prepared
      | frozen_selection: %{prepared.frozen_selection | model_ref: "model:mismatch"}
    }

    assert {:error, :inference_binding_selection_mismatch} = Inference.execute(mismatched)
  end

  test "reconciliation normalizes every adapter result and contains callback failures" do
    assert {:ok, prepared} =
             Inference.prepare(
               @bare,
               stream_request("reconcile", stream_adapter: {@adapter, fixture: true}),
               context(@bare)
             )

    assert {:error, :missing_inference_provider_request_id} =
             Inference.reconcile(prepared, nil)

    assert {:error, :inference_reconcile_capability_unavailable} =
             Inference.reconcile(%{prepared | stream_capabilities: MapSet.new()}, "request")

    assert {:ok, %Response{text: "reconciled"}} = Inference.reconcile(prepared, "request")

    for mode <- [:pending, :not_found] do
      assert ^mode = Inference.reconcile(prepared, "request", reconcile_mode: mode)
    end

    assert {:error, :reconcile_failed} =
             Inference.reconcile(prepared, "request", reconcile_mode: :error)

    expected_classes = [tuple: :unexpected, atom: :unexpected, map: :map, list: :other]

    Enum.each(expected_classes, fn {mode, expected} ->
      assert {:error, {:invalid_inference_reconcile_reply, ^expected}} =
               Inference.reconcile(prepared, "request", reconcile_mode: mode)
    end)

    assert {:error, {:inference_reconcile_exception, RuntimeError}} =
             Inference.reconcile(prepared, "request", reconcile_mode: :raise)

    assert {:error, {:inference_reconcile_failure, :throw, :secret}} =
             Inference.reconcile(prepared, "request", reconcile_mode: :throw)
  end

  test "rebind and fallback preparation preserve the descriptor but reverify selection" do
    input = Input.new("recover")
    state = %State{}
    assert {:ok, prepared} = Inference.prepare(@bare, request("rebind", @good), context(@bare))

    assert {:ok, rebound} =
             Inference.rebind(
               @bare,
               prepared.descriptor,
               prepared.frozen_selection,
               input,
               state,
               model: @good
             )

    assert rebound.descriptor == prepared.descriptor

    assert {:error, :inference_recovery_selection_mismatch} =
             Inference.rebind(
               @bare,
               prepared.descriptor,
               prepared.frozen_selection,
               input,
               state,
               model: @error
             )

    assert {:ok, attempt} =
             Inference.prepare_attempt(
               @bare,
               prepared.descriptor,
               2,
               input,
               state,
               model: @good,
               fallback: [@good],
               inference_previous_errors: [:first_failed]
             )

    assert attempt.selection.attempt == 2
    assert attempt.descriptor == prepared.descriptor

    assert {:error, :missing_llm_adapter} =
             Inference.prepare_attempt(@bare, prepared.descriptor, 2, input, state, [])
  end

  test "credential rotation does not change frozen model identity" do
    first =
      {@good, :complete,
       [api_key: "first-secret", headers: [{"authorization", "Bearer first"}], temperature: 0.2]}

    rotated =
      {@good, :complete,
       [api_key: "second-secret", headers: [{"authorization", "Bearer second"}], temperature: 0.2]}

    changed =
      {@good, :complete,
       [api_key: "second-secret", headers: [{"authorization", "Bearer second"}], temperature: 0.7]}

    assert FrozenSelection.model_ref(first) == FrozenSelection.model_ref(rotated)
    refute FrozenSelection.model_ref(rotated) == FrozenSelection.model_ref(changed)

    input = Input.new("recover after credential rotation")
    state = %State{}

    assert {:ok, prepared} =
             Inference.prepare(@bare, request("credential-rotation", first), context(@bare))

    assert {:ok, rebound} =
             Inference.rebind(
               @bare,
               prepared.descriptor,
               prepared.frozen_selection,
               input,
               state,
               model: rotated
             )

    assert rebound.frozen_selection.model_ref == prepared.frozen_selection.model_ref
  end

  test "custom selection rejects duplicate, malformed, absent, invalid, and incompatible profiles" do
    assert {:error, {:duplicate_inference_profile, "duplicate"}} =
             Inference.prepare(
               SpectreInferenceSelectionRecoveryEdgeContractTest.DuplicateAgent,
               selected_request("duplicate"),
               context(SpectreInferenceSelectionRecoveryEdgeContractTest.DuplicateAgent)
             )

    assert {:error, {:invalid_inference_profiles, :atom}} =
             Inference.prepare(
               SpectreInferenceSelectionRecoveryEdgeContractTest.InvalidProfilesAgent,
               selected_request("invalid-profiles"),
               context(SpectreInferenceSelectionRecoveryEdgeContractTest.InvalidProfilesAgent)
             )

    assert {:error, {:inference_profile_not_registered, "missing"}} =
             Inference.prepare(
               @selected,
               selected_request("missing"),
               context(@selected, selection_mode: :unregistered)
             )

    assert {:error, {:invalid_inference_selection, _message}} =
             Inference.prepare(
               @selected,
               selected_request("invalid-selection"),
               context(@selected, selection_mode: :invalid)
             )

    assert {:error, {:inference_profile_incompatible, "selected"}} =
             Inference.prepare(
               @selected,
               %{selected_request("incompatible") | modalities: [:image]},
               context(@selected)
             )
  end

  test "stream setup handles tuple adapters and fails closed on every configuration gap" do
    assert {:ok, tuple_binding} =
             Inference.prepare(
               @bare,
               stream_request("tuple", stream_adapter: {@adapter, fixture: true}),
               context(@bare)
             )

    assert tuple_binding.stream_adapter == @adapter
    assert tuple_binding.stream_adapter_opts == [fixture: true]

    cases = [
      {[], {:streaming_unsupported, :adapter}},
      {[stream_adapter: 42], {:streaming_unsupported, :adapter_configuration}},
      {[stream_adapter: {@adapter, [:not_keyword]}],
       {:streaming_unsupported, :adapter_configuration}},
      {[stream_adapter: @adapter, stream_adapter_opts: :invalid],
       {:streaming_unsupported, :adapter_configuration}}
    ]

    Enum.each(cases, fn {adapter_opts, expected} ->
      assert {:error, ^expected} =
               Inference.prepare(
                 @bare,
                 stream_request("stream-config", adapter_opts),
                 context(@bare)
               )
    end)

    assert {:error, {:streaming_unsupported, :profile}} =
             Inference.prepare(
               @selected,
               selected_request("profile-stream",
                 llm_opts: stream_opts(stream_adapter: @adapter)
               ),
               context(@selected)
             )

    assert {:error, {:streaming_unsupported, :planner_cleaner}} =
             Inference.prepare(
               SpectreInferenceSelectionRecoveryEdgeContractTest.PlannerAgent,
               stream_request("planner", stream_adapter: @adapter),
               context(SpectreInferenceSelectionRecoveryEdgeContractTest.PlannerAgent)
             )
  end

  test "descriptor options remain portable when a runtime model is a closure" do
    closure = fn _plan, _opts -> {:ok, "closure"} end
    assert {:ok, prepared} = Inference.prepare(@bare, request("closure", closure), context(@bare))
    refute prepared.descriptor.recoverable?
    assert prepared.descriptor.recovery_reason == :runtime_model_binding_not_portable
    assert Descriptor.options(prepared.descriptor) == []
  end

  defp request(id, model) do
    Request.new(
      id: id,
      purpose: :response_generation,
      plan: plan(id),
      metadata: %{
        model: model,
        explicit_model_override?: true,
        llm_opts: [model: model]
      }
    )
  end

  defp selected_request(id, opts \\ []) do
    metadata = %{
      explicit_model_override?: false,
      llm_opts: Keyword.get(opts, :llm_opts, [])
    }

    Request.new(id: id, purpose: :response_generation, plan: plan(id), metadata: metadata)
  end

  defp stream_request(id, adapter_opts) do
    request(id, @good)
    |> then(fn request ->
      %{request | metadata: Map.put(request.metadata, :llm_opts, stream_opts(adapter_opts))}
    end)
  end

  defp stream_opts(adapter_opts) do
    [streaming?: true, plan_actions?: false, model: @good] ++ adapter_opts
  end

  defp context(agent, assigns \\ []) do
    %Context{
      agent: agent,
      input: Input.new("inference"),
      state: %State{},
      opts: [],
      assigns: Map.new(assigns)
    }
  end

  defp plan(text) do
    {:ok, plan} = Plan.compose(text, [], [:agent])
    plan
  end
end
