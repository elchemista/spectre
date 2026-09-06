# Run with: mix run bench/authority_reads.exs [--quick]
# Pure read/resolve microbenchmark, NOT a governed lifecycle or persistence test.
defmodule Spectre.Bench.AuthorityReads do
  alias Spectre.{Candidate, Duty, Mandate, Row}
  alias Spectre.Domain.Event
  alias Spectre.GovernedAct.{AuthorityIndex, State}
  alias Spectre.Kernel.Authority
  alias Spectre.Kernel.Authority.Facts

  def run do
    {opts, [], []} = OptionParser.parse(System.argv(), strict: [quick: :boolean])
    quick? = Keyword.get(opts, :quick, false)
    sizes = if quick?, do: [0, 100], else: [0, 1_000, 10_000]

    inputs =
      for lane <- [:closed_duties, :foreign_mandates], n <- sizes, into: %{} do
        input = fixture(lane, n)
        full = resolve(input, &Facts.from_state/1)
        selected = resolve(input, &Facts.for_candidate(&1, input.candidate))
        true = full === selected
        {:ok, _authority} = selected
        true = Facts.current(input.state) === Facts.from_state(input.state)

        IO.inspect(%{
          lane: lane,
          historical_records: n,
          state_flat_bytes: flat_bytes(input.state),
          authority_index_flat_bytes: flat_bytes(input.state.read_index.authority),
          selected_facts_flat_bytes: flat_bytes(Facts.for_candidate(input.state, input.candidate))
        })

        {"#{lane}/#{n}", input}
      end

    Benchee.run(
      %{
        "exhaustive facts + resolve" => &resolve(&1, fn state -> Facts.from_state(state) end),
        "selected facts + resolve" => fn input ->
          resolve(input, &Facts.for_candidate(&1, input.candidate))
        end
      },
      inputs: inputs,
      time: if(quick?, do: 0.02, else: 1),
      warmup: if(quick?, do: 0, else: 0.2),
      memory_time: if(quick?, do: 0, else: 0.2),
      reduction_time: if(quick?, do: 0, else: 0.2),
      percentiles: [50, 95, 99]
    )
  end

  defp resolve(input, read),
    do: Authority.resolve(input.candidate, input.context, read.(input.state), 100)

  defp fixture(lane, size) do
    mandate = mandate("active", "worker")
    state = State.new("domain") |> issue(mandate)
    state = Enum.reduce(Enum.take(Stream.iterate(1, &(&1 + 1)), size), state, &seed(&2, lane, &1))

    {:ok, candidate} =
      Candidate.new(
        identity_key: "read",
        class: "app.read",
        row: %{read: true},
        proposer_ref: "worker",
        executor_ref: "executor",
        executor_contract_ref: "contract",
        accountable_ref: "owner",
        scope_ref: "scope",
        purpose_ref: "purpose",
        consequence: %{}
      )

    %{
      state: state,
      candidate: candidate,
      context: %{
        domain_ref: "domain",
        scope_ref: "scope",
        authenticated_principal_ref: "worker",
        authentication_ref: "auth",
        ingress_ref: "ingress",
        host_generation: 1
      }
    }
  end

  defp seed(state, :foreign_mandates, n), do: issue(state, mandate("foreign:#{n}", "other"))

  defp seed(state, :closed_duties, n) do
    {:ok, duty} =
      Duty.new(
        class: "app.review",
        cause_key: {:review, n},
        accountable: "owner",
        opened_at: 100,
        containment: %{
          "dispatch" => :blocked,
          "retry" => :forbidden,
          "consequence_digest" => "old-consequence:#{n}"
        }
      )

    state = %{state | duties: Map.put(state.duties, duty.cause_key, duty)}
    state = put_in(state.read_index.duties.by_ref[duty.ref], duty.cause_key)

    state =
      AuthorityIndex.record(state, %Event{type: "duty_opened", identity: duty.ref, data: %{}})

    state = %{state | duties: Map.put(state.duties, duty.cause_key, %{duty | status: :disposed})}

    AuthorityIndex.record(state, %Event{
      type: "duty_disposed",
      identity: "disposition:#{n}",
      data: %{"cause_key" => duty.cause_key}
    })
  end

  defp issue(state, mandate) do
    %{state | mandates: Map.put(state.mandates, mandate.ref, mandate)}
    |> AuthorityIndex.record(%Event{type: "mandate_issued", identity: mandate.ref, data: %{}})
  end

  # Deliberately generated typed records: no Genesis, authentic disposition Act,
  # Meter accounting or canonical content-ref validation is measured here.
  # End-to-end and malformed-ledger tests cover those independent boundaries.
  defp mandate(ref, holder) do
    struct(Mandate,
      ref: ref,
      grantor_ref: "controller",
      holder_ref: holder,
      accountable_ref: "owner",
      executor_refs: ["executor"],
      executor_contract_refs: ["contract"],
      scope_refs: ["scope"],
      classes: ["app.read"],
      ceiling: %Row{read: true},
      purpose_ref: "purpose",
      not_before: 90,
      expires_at: 200
    )
  end

  # Flattened term size is a diagnostic, not exclusive retained heap memory or
  # allocation per query. It intentionally counts shared subterms repeatedly.
  defp flat_bytes(term), do: :erts_debug.flat_size(term) * :erlang.system_info(:wordsize)
end

Spectre.Bench.AuthorityReads.run()
