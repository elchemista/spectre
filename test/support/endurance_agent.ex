defmodule Spectre.Test.EnduranceAgent do
  @moduledoc false

  defmodule Defaults do
    @moduledoc false
    use Spectre.Stack
    semantic_cache(:routing, learn: :review)
    adapter(:observer, :events, Spectre.Agent.Observer)
  end

  defmodule Refunds do
    @moduledoc false
    use Spectre.Skill, namespace: "endurance", name: "refunds"
    request(:refund, class: "refund.issue")

    flow :support do
      pipe_through(:text)
      router(via: [:regex, :string_bag], accept: 0.9)

      route(:refund,
        match: [regex: ~r/^refund (?<order_id>ORD-[0-9]+)$/, string_bag: ["refund my order"]]
      )
    end

    @impl true
    def handle_turn({:support, :refund, _captures}, _turn, state),
      do: {:request, :refund, state.consequence, %{state | count: state.count + 1}}

    @impl true
    def handle_result(_operation, result, _turn, state),
      do: {:ok, Map.put(state, :result, result.status)}
  end

  defmodule RefundWork do
    @moduledoc false
    use Spectre.Worker, namespace: "endurance", name: "refund-work"
    adapter(:observer, :events, Spectre.Agent.Observer)
    request(:refund, class: "refund.issue")

    @impl true
    def handle_work(%{payload: %{"event" => "ready"}}, _turn, state), do: {:ok, state}

    def handle_work(_input, _turn, state),
      do: {:request, :refund, state.consequence, %{state | count: state.count + 1}}

    @impl true
    def handle_result(_operation, result, _turn, state),
      do: {:ok, Map.put(state, :result, result.status)}
  end

  defmodule ReceiptWatch do
    @moduledoc false
    use Spectre.Vigil, namespace: "endurance", name: "receipt-watch"
    adapter(:observer, :events, Spectre.Agent.Observer)

    @impl true
    def handle_vigil(%{payload: %{"event" => "ready"}}, _turn, state), do: {:ok, state}

    def handle_vigil(
          %{payload: %{"outcome_ref" => ref, "status" => "succeeded"} = payload},
          turn,
          state
        ) do
      # A receipt from another Scope is not imported as ambient authority.
      # The host observes that receipt through this Vigil's ingress. Check the
      # resulting sealed observation, retaining the original causal reference.
      if Enum.any?(
           turn.mind_turn.evidence,
           &(&1.provenance == :observed and &1.payload === payload)
         ) do
        {:ok, %{state | count: state.count + 1, last_receipt: ref}}
      else
        {:error, :unbacked_receipt, state}
      end
    end
  end

  defmodule Support do
    @moduledoc false
    use Spectre.Agent, namespace: "endurance", name: "support", stack: Defaults

    skill(Refunds, as: :billing)
    skill(Refunds, as: :returns)
    worker(:refunds, RefundWork)
    vigil(:receipts, ReceiptWatch)

    prompt_root(Path.expand("prompts", __DIR__))
    prompt(:system, "Help <%= @customer %> with their order.")
    prompt(:safety, "A draft is not a delivered reply or an executed refund.")
    prompt(:refund_policy, "Refunds require governed admission and an observed receipt.")
    prompt(:receipt_policy, "Do not invent a payment receipt.")
    prompt(:task, file: "customer_reply.txt.eex")
    inject(:safety, into: :system, position: :start)

    # An actual local embedding model, not a fake LLM. The rendered prompt is
    # embedded by the executor only after the ordinary governed advance.
    ask(:index_reply, class: "model.embed", prompt: :system, task: :task, via: :encoder)
    adapter(:request, :encoder, Spectre.Test.EnduranceAgent.EmbeddingRequest)

    flow :support do
      pipe_through(:envelope)
      router(via: [:semantic_cache], cache: :routing, accept: 0.70, margin: 0.03)
      inject(:refund_policy, into: :system)
      route(:refund, cache: true, inject: :receipt_policy)
    end

    @impl true
    def handle_turn({:support, :refund, _source}, _turn, state),
      do: {:ask, :index_reply, state.assigns, %{state | count: state.count + 1}}

    def handle_turn({:support, :no_match, _input}, _turn, state), do: {:ok, state}

    @impl true
    def handle_result(_operation, result, _turn, state),
      do: {:ok, Map.put(state, :result, result.status)}
  end

  defmodule Envelope do
    @moduledoc false
    @behaviour Spectre.Input.Plug
    @impl true
    def call(%{payload: %{"text" => envelope}}, _opts), do: {:cont, envelope}
  end

  defmodule Executor do
    @moduledoc false
    @behaviour Spectre.Attempt.Executor
    alias Spectre.Attempt.Executor, as: ExecutorAPI

    @impl true
    defdelegate executor_ref(), to: Spectre.V04Test.Executor
    @impl true
    defdelegate contract_ref(), to: Spectre.V04Test.Executor

    @impl true
    def execute(act, attempt, _capability, opts) do
      # This host-owned effect journal is deliberately distinct from GAM.
      # It detects double execution even if the ledger looks self-consistent.
      result = perform(act.class, act.consequence)
      key = {act.ref, attempt.ref}

      :ok =
        Agent.get_and_update(opts[:journal], fn journal ->
          if Map.has_key?(journal, key) do
            {{:error, :duplicate_execution}, journal}
          else
            {:ok, Map.put(journal, key, result)}
          end
        end)

      send(opts[:observer], {:endurance_effect, self(), act, attempt, result})

      {:ok, evidence} =
        ExecutorAPI.outcome_evidence(act, attempt, :succeeded, Spectre.Clock.System.now(),
          payload: %{"receipt" => attempt.ref}
        )

      {:ok, %{evidence: [evidence], details_ref: "receipt:" <> attempt.ref}}
    end

    defp perform("model.embed", %{"prompt" => prompt}) do
      text = Enum.map_join(prompt["parts"], "\n", & &1["text"])
      {:ok, [vector]} = ExFastembed.embed_text([text])
      %{kind: :embedding, prompt: prompt, vector: vector}
    end

    defp perform("refund.issue", consequence),
      do: %{kind: :refund, cents: consequence["amount_cents"]}
  end

  defmodule EmbeddingRequest do
    @moduledoc false
    @behaviour Spectre.Agent.RequestBuilder

    @impl true
    def prepare({:ask, :index_reply}, prompt, _turn, opts) do
      {:ok,
       %{
         class: "model.embed",
         consequence: %{"prompt" => prompt, "target_ref" => Keyword.fetch!(opts, :target_ref)}
       }}
    end
  end
end
