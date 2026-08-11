defmodule SpectreInferenceContractTest.StringModel do
  @moduledoc false

  def complete(_prompt, opts) do
    notify(opts, :string)
    {:ok, "string-response"}
  end

  defp notify(opts, kind) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:inference_model, kind})
  end
end

defmodule SpectreInferenceContractTest.ResponseModel do
  @moduledoc false

  alias Spectre.Inference.Response

  def complete(_prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:inference_model, :response})

    {:ok,
     %Response{
       text: "typed-response",
       usage: %{input_tokens: 3},
       metadata: %{provider: :typed}
     }}
  end
end

defmodule SpectreInferenceContractTest.MapModel do
  @moduledoc false

  def complete(_prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:inference_model, :map})

    {:ok,
     %{
       text: "map-response",
       usage: %{input_tokens: 4},
       metadata: %{provider: :map}
     }}
  end
end

defmodule SpectreInferenceContractTest.FailingModel do
  @moduledoc false

  def complete(_prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:inference_model, :failing})
    {:error, :transient_provider_failure}
  end
end

defmodule SpectreInferenceContractTest.Selector do
  @moduledoc false

  @behaviour Spectre.Inference.Selector

  @impl true
  def select(request, profiles, ctx, _opts) do
    profile = Enum.at(profiles, min(request.attempt - 1, length(profiles) - 1))

    if pid = Map.get(ctx.assigns, :test_pid) do
      send(
        pid,
        {:inference_selection, request.attempt, request.previous_errors,
         Map.get(request.metadata, :previous_levels, [])}
      )
    end

    {:ok,
     %{
       request_id: request.id,
       level: profile.id,
       model: profile.model,
       reason: if(request.attempt == 1, do: :preferred, else: :fallback),
       selector: __MODULE__,
       profile_hash: profile.profile_hash,
       fallback_chain: Enum.map(profiles, & &1.id),
       attempt: request.attempt
     }}
  end
end

defmodule SpectreInferenceContractTest.Extension do
  @moduledoc false

  @behaviour Spectre.Extension

  alias Spectre.Inference.Profile

  @impl true
  def id, do: :contract_inference

  @impl true
  def inference_selector(_config) do
    profiles = [
      Profile.new(
        id: :fast,
        rank: 10,
        model: SpectreInferenceContractTest.FailingModel,
        supports: [:text],
        context_window: 16_000,
        privacy: :local,
        cost_tier: :low,
        latency_tier: :low
      ),
      Profile.new(
        id: :balanced,
        rank: 20,
        model: SpectreInferenceContractTest.StringModel,
        supports: [:text],
        context_window: 32_000,
        privacy: :local,
        cost_tier: :medium,
        latency_tier: :medium
      )
    ]

    {SpectreInferenceContractTest.Selector, profiles: profiles, max_attempts: 2}
  end
end

defmodule SpectreInferenceContractTest.InvalidExtension do
  @moduledoc false

  @behaviour Spectre.Extension

  @impl true
  def id, do: :invalid_contract_inference

  @impl true
  def inference_selector(_config), do: SpectreInferenceContractTest.MissingSelector
end

defmodule SpectreInferenceContractTest.MalformedProfilesExtension do
  @moduledoc false

  @behaviour Spectre.Extension

  @impl true
  def id, do: :malformed_inference_profiles

  @impl true
  def inference_selector(_config) do
    profile = %{
      id: :malformed,
      rank: 1,
      model: SpectreInferenceContractTest.StringModel,
      supports: 42,
      cost_tier: :low,
      latency_tier: :low
    }

    {SpectreInferenceContractTest.Selector, profiles: [profile]}
  end
end

defmodule SpectreInferenceContractTest.ForgedSelector do
  @moduledoc false
  @behaviour Spectre.Inference.Selector

  @impl true
  def select(request, [profile | _profiles], _ctx, _opts) do
    {:ok,
     %{
       request_id: request.id,
       level: profile.id,
       model: SpectreInferenceContractTest.MapModel,
       reason: :forged,
       selector: __MODULE__,
       profile_hash: profile.profile_hash,
       attempt: request.attempt
     }}
  end
end

defmodule SpectreInferenceContractTest.ForgedExtension do
  @moduledoc false
  @behaviour Spectre.Extension

  alias Spectre.Inference.Profile

  @impl true
  def id, do: :forged_inference_selection

  @impl true
  def inference_selector(_config) do
    profile =
      Profile.new(
        id: :sealed,
        rank: 10,
        model: SpectreInferenceContractTest.StringModel,
        supports: [:text],
        context_window: 16_000,
        privacy: :local,
        cost_tier: :low,
        latency_tier: :low
      )

    {SpectreInferenceContractTest.ForgedSelector, profiles: [profile]}
  end
end

defmodule SpectreInferenceContractTest.BareAgent do
  @moduledoc false

  use Spectre.Agent
end

defmodule SpectreInferenceContractTest.SelectedAgent do
  @moduledoc false

  use Spectre.Agent
  Spectre.Extension.register!(__MODULE__, SpectreInferenceContractTest.Extension)
end

defmodule SpectreInferenceContractTest.InvalidSelectorAgent do
  @moduledoc false

  use Spectre.Agent
  Spectre.Extension.register!(__MODULE__, SpectreInferenceContractTest.InvalidExtension)
end

defmodule SpectreInferenceContractTest.MalformedProfilesAgent do
  @moduledoc false

  use Spectre.Agent

  Spectre.Extension.register!(
    __MODULE__,
    SpectreInferenceContractTest.MalformedProfilesExtension
  )
end

defmodule SpectreInferenceContractTest.ForgedSelectorAgent do
  @moduledoc false

  use Spectre.Agent
  Spectre.Extension.register!(__MODULE__, SpectreInferenceContractTest.ForgedExtension)
end

defmodule SpectreInferenceContractTest do
  use ExUnit.Case, async: true

  alias Spectre.Context
  alias Spectre.Flow.Constraint, as: FlowConstraint
  alias Spectre.Inference
  alias Spectre.Inference.Constraints
  alias Spectre.Inference.Profile
  alias Spectre.Inference.Request
  alias Spectre.Inference.Response
  alias Spectre.Inference.Selection
  alias Spectre.Inference.Selector.Default
  alias Spectre.Input
  alias Spectre.Input.Source
  alias Spectre.Prompt.Plan
  alias Spectre.State

  test "compatibility completion normalizes strings, typed responses, and maps" do
    cases = [
      {SpectreInferenceContractTest.StringModel, "string-response", :string},
      {SpectreInferenceContractTest.ResponseModel, "typed-response", :response},
      {SpectreInferenceContractTest.MapModel, "map-response", :map}
    ]

    Enum.each(cases, fn {model, expected, notification} ->
      request = compatibility_request(model)

      assert {:ok, %Response{text: ^expected, selection: %Selection{} = selection} = response} =
               Inference.complete(
                 SpectreInferenceContractTest.BareAgent,
                 request,
                 context(SpectreInferenceContractTest.BareAgent)
               )

      assert selection.selector == Default
      assert selection.reason == :agent_default
      assert selection.request_id == request.id
      assert is_integer(response.latency_ms)
      assert response.latency_ms >= 0
      assert_receive {:inference_model, ^notification}
    end)
  end

  test "an explicit model override retains compatibility precedence over an extension" do
    request =
      compatibility_request(SpectreInferenceContractTest.StringModel,
        explicit_model_override?: true
      )

    assert {:ok, %Response{selection: %Selection{} = selection}} =
             Inference.complete(
               SpectreInferenceContractTest.SelectedAgent,
               request,
               context(SpectreInferenceContractTest.SelectedAgent)
             )

    assert selection.selector == Default
    assert selection.reason == :explicit_model_override
    refute_received {:inference_selection, _, _, _}
    assert_receive {:inference_model, :string}
  end

  test "a required profile cannot fall back to the compatibility selector" do
    request = compatibility_request(SpectreInferenceContractTest.StringModel)

    request = %{
      request
      | metadata: Map.put(request.metadata, "required_profile_ref", "balanced")
    }

    assert {:error, {:inference_required_profile_unavailable, "balanced"}} =
             Inference.complete(
               SpectreInferenceContractTest.BareAgent,
               request,
               context(SpectreInferenceContractTest.BareAgent)
             )

    refute_received {:inference_model, _}
  end

  test "an explicit model override cannot replace a required profile" do
    request =
      compatibility_request(SpectreInferenceContractTest.StringModel,
        explicit_model_override?: true
      )

    request = %{request | metadata: Map.put(request.metadata, :required_profile_ref, :balanced)}

    assert {:error, {:inference_required_profile_forbids_model_override, "balanced"}} =
             Inference.complete(
               SpectreInferenceContractTest.SelectedAgent,
               request,
               context(SpectreInferenceContractTest.SelectedAgent)
             )

    refute_received {:inference_selection, _, _, _}
    refute_received {:inference_model, _}
  end

  test "selected inference retries once with a new frozen selection" do
    request = selected_request()

    assert {:ok,
            %Response{
              text: "string-response",
              selection: %Selection{level: :balanced, attempt: 2, reason: :fallback}
            }} =
             Inference.complete(
               SpectreInferenceContractTest.SelectedAgent,
               request,
               context(SpectreInferenceContractTest.SelectedAgent)
             )

    assert_receive {:inference_selection, 1, [], []}
    assert_receive {:inference_model, :failing}

    assert_receive {:inference_selection, 2, [:transient_provider_failure], [:fast]}
    assert_receive {:inference_model, :string}
  end

  test "strict and exhausted requests fail without widening retry limits" do
    strict = selected_request(strict?: true)

    assert {:error, :transient_provider_failure} =
             Inference.complete(
               SpectreInferenceContractTest.SelectedAgent,
               strict,
               context(SpectreInferenceContractTest.SelectedAgent)
             )

    assert_receive {:inference_selection, 1, [], []}
    assert_receive {:inference_model, :failing}
    refute_received {:inference_selection, 2, _, _}

    exhausted = selected_request(max_attempts: 1)

    assert {:error, {:inference_attempts_exhausted, 1, :transient_provider_failure}} =
             Inference.complete(
               SpectreInferenceContractTest.SelectedAgent,
               exhausted,
               context(SpectreInferenceContractTest.SelectedAgent)
             )
  end

  test "an unavailable selector fails before invoking any model" do
    assert {:error, {:invalid_inference_selector, SpectreInferenceContractTest.MissingSelector}} =
             Inference.complete(
               SpectreInferenceContractTest.InvalidSelectorAgent,
               selected_request(),
               context(SpectreInferenceContractTest.InvalidSelectorAgent)
             )

    refute_received {:inference_model, _}
  end

  test "malformed profile and request data fail closed before model execution" do
    assert {:error, {:invalid_inference_profiles, _message}} =
             Inference.complete(
               SpectreInferenceContractTest.MalformedProfilesAgent,
               selected_request(),
               context(SpectreInferenceContractTest.MalformedProfilesAgent)
             )

    malformed_request = %{selected_request() | metadata: []}

    assert {:error, :invalid_inference_request_metadata} =
             Inference.complete(
               SpectreInferenceContractTest.SelectedAgent,
               malformed_request,
               context(SpectreInferenceContractTest.SelectedAgent)
             )

    invalid_opts = compatibility_request(SpectreInferenceContractTest.StringModel)
    invalid_opts = %{invalid_opts | metadata: Map.put(invalid_opts.metadata, :llm_opts, :invalid)}

    assert {:error, :invalid_inference_llm_options} =
             Inference.complete(
               SpectreInferenceContractTest.BareAgent,
               invalid_opts,
               context(SpectreInferenceContractTest.BareAgent)
             )

    refute_received {:inference_selection, _, _, _}
    refute_received {:inference_model, _}
  end

  test "the kernel rejects a selector that swaps the registered profile model" do
    assert {:error, :inference_selection_model_mismatch} =
             Inference.complete(
               SpectreInferenceContractTest.ForgedSelectorAgent,
               selected_request(),
               context(SpectreInferenceContractTest.ForgedSelectorAgent)
             )

    refute_received {:inference_model, _}
  end

  test "an exact required profile cannot be widened into selector fallback" do
    request = selected_request()
    request = %{request | metadata: Map.put(request.metadata, :required_profile_ref, :balanced)}

    assert {:error, {:inference_required_profile_mismatch, "balanced", "fast"}} =
             Inference.complete(
               SpectreInferenceContractTest.SelectedAgent,
               request,
               context(SpectreInferenceContractTest.SelectedAgent)
             )

    refute_received {:inference_model, _}
  end

  test "profiles enforce modality, structure, context, privacy, cost, latency, and rank" do
    fast =
      profile(
        id: :fast,
        rank: 10,
        supports: [:text, :structured_output],
        context_window: 1_000,
        privacy: :cloud,
        cost_tier: :medium,
        latency_tier: :low,
        metadata: %{estimated_latency_ms: 80}
      )

    deep =
      profile(
        id: :deep,
        rank: 30,
        supports: [:text, :structured_output],
        context_window: 4_000,
        privacy: :local,
        cost_tier: :high,
        latency_tier: :high
      )

    profiles = [fast, deep]

    assert Profile.compatible?(fast, profile_request(), profiles)
    refute Profile.compatible?(fast, profile_request(modalities: [:image]), profiles)

    refute Profile.compatible?(
             profile(supports: [:text]),
             profile_request(structured_output?: true),
             profiles
           )

    assert Profile.compatible?(fast, profile_request(structured_output?: true), profiles)

    refute Profile.compatible?(
             profile(context_window: nil),
             profile_request(context_tokens: 1),
             []
           )

    refute Profile.compatible?(fast, profile_request(context_tokens: 1_001), profiles)
    assert Profile.compatible?(fast, profile_request(context_tokens: 1_000), profiles)

    refute Profile.compatible?(fast, profile_request(privacy: :private_cloud_only), profiles)
    assert Profile.compatible?(deep, profile_request(privacy: :local_only), profiles)

    assert Profile.compatible?(
             profile(privacy: :private_cloud),
             profile_request(privacy: :private_cloud_only),
             []
           )

    refute Profile.compatible?(
             profile(privacy: :private_cloud),
             profile_request(privacy: :local_only),
             []
           )

    refute Profile.compatible?(fast, profile_request(maximum_cost_tier: :low), profiles)
    assert Profile.compatible?(fast, profile_request(maximum_cost_tier: :medium), profiles)
    refute Profile.compatible?(fast, profile_request(maximum_latency_ms: 79), profiles)
    assert Profile.compatible?(fast, profile_request(maximum_latency_ms: 80), profiles)
    assert Profile.compatible?(deep, profile_request(maximum_latency_ms: 1), profiles)
    refute Profile.compatible?(fast, profile_request(minimum_level: :deep), profiles)
    assert Profile.compatible?(deep, profile_request(minimum_level: :deep), profiles)
    refute Profile.compatible?(deep, profile_request(minimum_level: :unknown), profiles)
  end

  test "profile hashes exclude credentials and constructors validate incomplete profiles" do
    first = profile(metadata: %{api_key: "first", public: :same})
    second = profile(metadata: %{api_key: "second", public: :same})
    assert first.profile_hash == second.profile_hash
    assert "sha256:" <> digest = first.profile_hash
    assert byte_size(digest) == 64

    assert %Profile{profile_hash: hash} =
             Profile.new(%Profile{
               id: :raw,
               rank: 1,
               model: :raw_model,
               cost_tier: :low,
               latency_tier: :low
             })

    assert is_binary(hash)

    invalid_profiles = [
      [id: nil, rank: 1, model: :model, cost_tier: :low, latency_tier: :low],
      [id: :id, rank: nil, model: :model, cost_tier: :low, latency_tier: :low],
      [id: :id, rank: 1, model: nil, cost_tier: :low, latency_tier: :low],
      [id: :id, rank: 1, model: :model, privacy: :unknown, cost_tier: :low, latency_tier: :low],
      [id: :id, rank: 1, model: :model, cost_tier: :unknown, latency_tier: :low],
      [id: :id, rank: 1, model: :model, cost_tier: :low, latency_tier: :unknown],
      [id: :id, rank: 1, model: :model, cost_tier: :low, latency_tier: :low, metadata: []],
      [
        id: :id,
        rank: 1,
        model: :model,
        cost_tier: :low,
        latency_tier: :low,
        profile_hash: 42
      ]
    ]

    Enum.each(invalid_profiles, fn attrs ->
      assert_raise ArgumentError, fn -> Profile.new(attrs) end
    end)

    assert_raise ArgumentError, ~r/profile hash does not match/, fn ->
      Profile.new(
        id: :forged,
        rank: 1,
        model: :model,
        cost_tier: :low,
        latency_tier: :low,
        profile_hash: "sha256:forged"
      )
    end
  end

  test "request builders preserve typed modalities and monotonic constraints" do
    plan = plan("classify")

    source = %Source{
      kind: :test,
      metadata: %{"modalities" => [:text, :image, :image]}
    }

    ctx = %Context{
      agent: SpectreInferenceContractTest.BareAgent,
      input: %Input{text: "look", source: source},
      state: %State{},
      opts: [model: SpectreInferenceContractTest.StringModel]
    }

    response_request =
      Request.for_response(
        plan,
        ctx,
        model: SpectreInferenceContractTest.StringModel,
        context_tokens: 99
      )

    assert response_request.modalities == [:text, :image]
    assert response_request.constraints.context_tokens == 99
    assert response_request.metadata.agent_model == SpectreInferenceContractTest.StringModel

    classification =
      Request.for_classification(plan, %{input: nil},
        model: SpectreInferenceContractTest.StringModel
      )

    assert classification.modalities == [:text]
    assert classification.constraints.structured_output?
    assert classification.constraints.maximum_output_tokens == 8
    assert classification.constraints.context_tokens > 0

    flow_constraint =
      FlowConstraint.new(
        namespace: :prism,
        kind: :inference,
        values: [[privacy: :private_cloud_only, maximum_latency_ms: 100]]
      )

    merged =
      Constraints.from_options(
        [
          intelligence: :deep,
          prism: %{maximum_latency_ms: 200, maximum_cost_tier: :medium},
          strict: true,
          maximum_attempts: 3
        ],
        [flow_constraint]
      )

    assert merged.minimum_level == :deep
    assert merged.preferred_level == :deep
    assert merged.privacy == :private_cloud_only
    assert merged.maximum_latency_ms == 100
    assert merged.maximum_cost_tier == :medium
    assert merged.strict?
    assert merged.max_attempts == 3
  end

  test "request, response, selection, and constraint constructors reject invalid shapes" do
    plan = plan("validate")

    assert %Request{} =
             Request.new(
               id: "request",
               purpose: :test,
               plan: plan,
               modalities: :text
             )

    invalid_requests = [
      [id: "", purpose: :test, plan: plan],
      [id: "request", purpose: nil, plan: plan],
      [id: "request", purpose: :test, plan: nil],
      [id: "request", purpose: :test, plan: plan, attempt: 0],
      [id: "request", purpose: :test, plan: plan, modalities: ["text"]],
      [id: "request", purpose: :test, plan: plan, previous_errors: :invalid],
      [id: "request", purpose: :test, plan: plan, metadata: []]
    ]

    Enum.each(invalid_requests, fn attrs ->
      assert_raise ArgumentError, fn -> Request.new(attrs) end
    end)

    assert %Response{text: "plain"} = Response.new("plain")
    assert %Response{text: "typed"} = Response.new(%Response{text: "typed"})
    assert %Response{text: "listed"} = Response.new(text: "listed")
    assert_raise ArgumentError, fn -> Response.new(%{text: nil}) end
    assert_raise ArgumentError, fn -> Response.new(%{text: "bad", usage: []}) end

    assert %Selection{request_id: "request"} =
             Selection.new(request_id: "request", model: :model)

    assert %Selection{} =
             Selection.new(%Selection{request_id: "request", model: :model})

    assert_raise ArgumentError, fn -> Selection.new(request_id: "", model: :model) end
    assert_raise ArgumentError, fn -> Selection.new(request_id: "request", model: nil) end

    invalid_constraints = [
      [maximum_cost_tier: :unbounded],
      [structured_output?: :yes],
      [maximum_latency_ms: 0],
      [maximum_output_tokens: -1],
      [max_attempts: "two"]
    ]

    Enum.each(invalid_constraints, fn attrs ->
      assert_raise ArgumentError, fn -> Constraints.new(attrs) end
    end)

    assert Constraints.new(context_tokens: 0).context_tokens == 0
  end

  defp context(agent) do
    %Context{
      agent: agent,
      input: Input.new("inference"),
      state: %State{},
      opts: [test_pid: self()],
      assigns: %{test_pid: self()}
    }
  end

  defp compatibility_request(model, opts \\ []) do
    explicit? = Keyword.get(opts, :explicit_model_override?, false)

    Request.new(%{
      id: "compatibility-#{System.unique_integer([:positive])}",
      purpose: :response_generation,
      plan: plan("respond"),
      metadata: %{
        model: model,
        llm_opts: [model: model, test_pid: self()],
        explicit_model_override?: explicit?
      }
    })
  end

  defp selected_request(constraint_opts \\ []) do
    Request.new(%{
      id: "selected-#{System.unique_integer([:positive])}",
      purpose: :response_generation,
      plan: plan("respond"),
      constraints: Constraints.new(constraint_opts),
      metadata: %{
        llm_opts: [test_pid: self()],
        explicit_model_override?: false
      }
    })
  end

  defp profile(overrides) do
    defaults = [
      id: :profile,
      rank: 10,
      model: :model,
      supports: [:text, :structured_output],
      context_window: 2_000,
      privacy: :local,
      cost_tier: :low,
      latency_tier: :low,
      metadata: %{}
    ]

    defaults
    |> Keyword.merge(overrides)
    |> Profile.new()
  end

  defp profile_request(opts \\ []) do
    {modalities, constraints} = Keyword.pop(opts, :modalities, [:text])

    Request.new(%{
      id: "profile-#{System.unique_integer([:positive])}",
      purpose: :profile_test,
      plan: plan("profile"),
      modalities: modalities,
      constraints: Constraints.new(constraints)
    })
  end

  defp plan(text) do
    {:ok, plan} = Plan.compose(text, [], [:agent])
    plan
  end
end
