defmodule SpectreProviderResilienceTest.GoodLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:good_llm, prompt, opts})
    {:ok, "ROUTE"}
  end
end

defmodule SpectreProviderResilienceTest.SlowLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:slow_llm_started, self()})
    Process.sleep(250)
    {:ok, "too late"}
  end
end

defmodule SpectreProviderResilienceTest.FallbackLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:fallback_llm, opts})
    {:ok, "fallback"}
  end
end

defmodule SpectreProviderResilienceTest.RaisingLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: raise("private adapter detail")
end

defmodule SpectreProviderResilienceTest.MalformedLLM do
  @moduledoc false
  @behaviour Spectre.LLM

  @impl Spectre.LLM
  def complete(_prompt, _opts), do: {:ok, 123}
end

defmodule SpectreProviderResilienceTest.SlowLocal do
  @moduledoc false

  def classify(_text, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:slow_local_started, self()})
    Process.sleep(250)

    {:ok,
     %{
       label: :ROUTE,
       accepted?: true,
       confidence: 0.99,
       margin: 0.4,
       strategy: :local_classifier
     }}
  end
end

defmodule SpectreProviderResilienceTest.MalformedLocal do
  @moduledoc false

  def classify(_text, _opts), do: {:ok, "not a classifier result"}
end

defmodule SpectreProviderResilienceTest.SlowEmbedding do
  @moduledoc false

  def embed(_text, opts) do
    if pid = Keyword.get(opts, :test_pid), do: send(pid, {:slow_embedding_started, self()})
    Process.sleep(250)
    {:ok, [1.0, 0.0]}
  end
end

defmodule SpectreProviderResilienceTest.Agent do
  @moduledoc false

  use Spectre.Agent

  classifier(SpectreProviderResilienceTest.GoodLLM,
    local: SpectreProviderResilienceTest.SlowLocal,
    local_classifier_timeout: 30_000,
    llm_opts: [llm_timeout: 30_000]
  )

  router(via: [:classifier, :llm_classifier], semantic_cache?: false)

  flow :resilience do
    on :ROUTE, via: [:classifier, :llm_classifier] do
      reply(:route)
    end
  end
end

defmodule SpectreProviderResilienceTest.EmbeddingAgent do
  @moduledoc false

  use Spectre.Agent

  embedding(SpectreProviderResilienceTest.SlowEmbedding, embedding_timeout: 30_000)
  router(via: [:embedding], semantic_cache?: false)

  flow :resilience do
    on :EMBEDDING_ROUTE, embedding: ["semantic example"], via: [:embedding] do
      reply(:embedding)
    end
  end
end

defmodule SpectreProviderResilienceTest do
  use ExUnit.Case, async: false

  alias Spectre.Provider.Call
  alias Spectre.Provider.Failure
  alias Spectre.Router
  alias Spectre.Router.LocalClassifier
  alias Spectre.Router.SemanticCache

  describe "shared provider call contract" do
    test "preserves valid success and adapter-declared error replies" do
      assert {:ok, %{answer: 42}} =
               Call.run(:llm, fn -> {:ok, %{answer: 42}} end, provider_timeout: 100)

      assert {:error, :provider_busy} =
               Call.run(:llm, fn -> {:error, :provider_busy} end, provider_timeout: 100)
    end

    test "normalizes exceptions, exits, throws, crashes, and malformed envelopes" do
      assert {:error, %Failure{provider: :llm, kind: :exception, reason: RuntimeError}} =
               Call.run(:llm, fn -> raise("private exception text") end)

      assert {:error, %Failure{provider: :llm, kind: :exit, reason: :private_exit}} =
               Call.run(:llm, fn -> exit({:private_exit, "private exit text"}) end)

      assert {:error, %Failure{provider: :llm, kind: :throw, reason: :private_throw}} =
               Call.run(:llm, fn -> throw({:private_throw, "private throw text"}) end)

      assert {:error, %Failure{provider: :llm, kind: :crash, reason: :killed}} =
               Call.run(:llm, fn -> Process.exit(self(), :kill) end)

      assert {:error, %Failure{provider: :llm, kind: :invalid_reply, reason: :binary}} =
               Call.run(:llm, fn -> "private malformed reply" end)
    end

    test "times out and terminates the local adapter worker without a late result" do
      test_pid = self()

      assert {:error,
              %Failure{
                provider: :llm,
                kind: :timeout,
                reason: :deadline_exceeded,
                timeout: 10,
                retryable?: true
              }} =
               Call.run(
                 :llm,
                 fn ->
                   send(test_pid, {:timeout_worker, self()})
                   Process.sleep(100)
                   send(test_pid, :late_provider_result)
                   {:ok, :late}
                 end,
                 provider_timeout: 10
               )

      assert_receive {:timeout_worker, worker}
      monitor = Process.monitor(worker)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
      refute_receive :late_provider_result, 120
    end

    test "terminates the adapter worker when its caller dies" do
      test_pid = self()

      caller =
        spawn(fn ->
          Call.run(
            :llm,
            fn ->
              send(test_pid, {:caller_worker, self()})
              Process.sleep(:infinity)
              {:ok, :unreachable}
            end,
            provider_timeout: :infinity
          )
        end)

      assert_receive {:caller_worker, worker}
      monitor = Process.monitor(worker)
      Process.exit(caller, :kill)

      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}
    end

    test "rejects invalid timeout configuration without invoking the adapter" do
      assert {:error,
              %Failure{
                provider: :llm,
                kind: :configuration,
                reason: {:invalid_timeout, 0}
              }} =
               Call.run(:llm, fn -> flunk("adapter must not run") end, llm_timeout: 0)
    end
  end

  describe "LLM boundary" do
    test "all supported model declarations use the same protected contract" do
      models = [
        SpectreProviderResilienceTest.GoodLLM,
        {SpectreProviderResilienceTest.GoodLLM, :complete},
        {SpectreProviderResilienceTest.GoodLLM, :complete, [marker: :tuple]},
        &SpectreProviderResilienceTest.GoodLLM.complete/2,
        fn prompt -> {:ok, "function:#{prompt}"} end
      ]

      Enum.each(models, fn model ->
        assert {:ok, text} =
                 Spectre.LLM.complete("contract", model: model, test_pid: self())

        assert is_binary(text)
      end)
    end

    test "uses fallback after a primary timeout and passes the normalized cause" do
      model =
        {SpectreProviderResilienceTest.SlowLLM, :complete,
         fallback: SpectreProviderResilienceTest.FallbackLLM, llm_timeout: 10}

      assert {:ok, "fallback"} =
               Spectre.LLM.complete("route me",
                 model: model,
                 test_pid: self()
               )

      assert_receive {:slow_llm_started, slow_worker}
      assert_receive {:fallback_llm, fallback_opts}
      assert %Failure{kind: :timeout, provider: :llm} = fallback_opts[:primary_error]
      refute Process.alive?(slow_worker)
    end

    test "sanitizes raised and malformed adapter responses" do
      assert {:error, %Failure{kind: :exception, reason: RuntimeError} = raised} =
               Spectre.LLM.complete("private prompt",
                 model: SpectreProviderResilienceTest.RaisingLLM
               )

      refute inspect(raised) =~ "private adapter detail"
      refute inspect(raised) =~ "private prompt"

      assert {:error, %Failure{kind: :invalid_reply, reason: :number}} =
               Spectre.LLM.complete("prompt",
                 model: SpectreProviderResilienceTest.MalformedLLM
               )
    end
  end

  describe "routing provider integration" do
    test "local classifier timeout falls through to LLM arbitration" do
      assert {:ok, receipt} =
               Router.evaluate(SpectreProviderResilienceTest.Agent, "route this",
                 test_pid: self(),
                 local_classifier_timeout: 10
               )

      assert receipt.outcome == :route
      assert receipt.label == :ROUTE
      assert receipt.strategy == :llm_classifier
      assert receipt.llm_called?
      assert_receive {:slow_local_started, local_worker}
      refute Process.alive?(local_worker)

      assert Enum.any?(receipt.attempts, fn attempt ->
               attempt.provider == :local_classifier and attempt.result == :error and
                 attempt.reason == :deadline_exceeded
             end)
    end

    test "local classifier rejects malformed success payloads" do
      assert {:error,
              %Failure{
                provider: :local_classifier,
                kind: :invalid_reply,
                reason: :binary
              }} =
               LocalClassifier.classify("text",
                 classifier_local: SpectreProviderResilienceTest.MalformedLocal
               )
    end

    test "embedding timeout degrades to clarification instead of failing routing" do
      assert {:ok, receipt} =
               Router.evaluate(SpectreProviderResilienceTest.EmbeddingAgent, "semantic request",
                 test_pid: self(),
                 embedding_timeout: 10
               )

      assert receipt.outcome == :clarify
      refute receipt.llm_called?
      assert_receive {:slow_embedding_started, embedding_worker}
      refute Process.alive?(embedding_worker)

      assert Enum.any?(receipt.attempts, fn attempt ->
               attempt.provider == :embedding and attempt.result == :skipped and
                 attempt.reason == :deadline_exceeded
             end)
    end

    test "semantic cache lookup timeout is normalized and cancellable" do
      test_pid = self()

      lookup = fn _text, _opts ->
        send(test_pid, {:semantic_worker, self()})
        Process.sleep(250)
        {:error, :late_miss}
      end

      assert {:error,
              %Failure{
                provider: :semantic_cache,
                kind: :timeout,
                reason: :deadline_exceeded
              }} =
               SemanticCache.lookup("lookup",
                 semantic_lookup: lookup,
                 semantic_cache_timeout: 10
               )

      assert_receive {:semantic_worker, worker}
      refute Process.alive?(worker)
    end
  end
end
