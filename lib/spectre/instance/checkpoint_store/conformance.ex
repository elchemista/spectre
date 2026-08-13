defmodule Spectre.Instance.CheckpointStore.Conformance do
  @moduledoc """
  Adapter-neutral conformance checks for an Instance Checkpoint Store.

  The runner writes two consecutive canonical checkpoints through
  `Spectre.Instance.CheckpointStore`, verifies semantic readback, reconciles an
  exact retry, proves that a stale writer cannot replace revision two, and
  races two revision-three writers to require a single CAS winner. It uses the
  real current checkpoint codec and Instance validator and has no ExUnit
  dependency.

  The Checkpoint Store behaviour deliberately leaves the adapter's conflict
  vocabulary open. The race therefore accepts any declared error from the
  losing writer, but rejects `{:ambiguous, reason}` because that outcome cannot
  prove there was only one commit.

  A run leaves revision three in storage. Callers must pass a fresh, isolated
  `Spectre.Instance.Ref`; adapter options belong in the ordinary store config.
  """

  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.Canonical.Validator
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Ref
  alias Spectre.State

  @type report :: %{
          required(:create) => :committed,
          required(:update) => :committed,
          required(:exact_retry) => :accepted | :readback_verified,
          required(:stale_write) => :rejected,
          required(:concurrent_cas) => :single_winner,
          required(:readback) => :verified,
          required(:revision) => 3,
          required(:checkpoint_digest) => String.t()
        }

  @doc "Runs the public CAS contract using a fresh Instance Ref."
  @spec run(CheckpointStore.config(), Ref.t()) :: {:ok, report()} | {:error, term()}
  def run(store, %Ref{} = ref) do
    with {:ok, store} <- normalize_store(store),
         {:ok, create, update, stale, contenders} <- checkpoints(ref),
         :not_found <- load(store, ref, :initial_load),
         :ok <- write(store, ref, create.json, 0, 1, :create),
         :ok <- readback(store, ref, create.digest, :create),
         {:ok, retry} <- exact_retry(store, ref, create),
         :ok <- write(store, ref, update.json, 1, 2, :update),
         :ok <- readback(store, ref, update.digest, :update),
         :ok <- reject_stale(store, ref, stale.json, update.digest),
         {:ok, winner_digest} <- concurrent_cas(store, ref, contenders) do
      {:ok,
       %{
         create: :committed,
         update: :committed,
         exact_retry: retry,
         stale_write: :rejected,
         concurrent_cas: :single_winner,
         readback: :verified,
         revision: 3,
         checkpoint_digest: winner_digest
       }}
    else
      {:error, {:checkpoint_store_conformance_failed, _phase, _code}} = error -> error
      {:ok, _checkpoint} -> failure(:initial_load, :reference_not_empty)
    end
  end

  def run(_store, _ref), do: failure(:options, :invalid_ref)

  @doc "Compares one checkpoint semantically through two store configurations."
  @spec read_after_restart(
          CheckpointStore.config(),
          CheckpointStore.config(),
          Ref.t()
        ) :: :ok | {:error, term()}
  def read_after_restart(before, after_restart, %Ref{} = ref) do
    with {:ok, before} <- normalize_store(before),
         {:ok, after_restart} <- normalize_store(after_restart),
         {:ok, checkpoint} <- load(before, ref, :restart_before),
         {:ok, report} <- verify(checkpoint, ref, :restart_before) do
      readback(after_restart, ref, report.digest, :restart_after)
    else
      :not_found -> failure(:restart_before, :checkpoint_not_found)
      {:error, {:checkpoint_store_conformance_failed, _phase, _code}} = error -> error
    end
  end

  def read_after_restart(_before, _after_restart, _ref),
    do: failure(:options, :invalid_ref)

  @spec checkpoints(Ref.t()) :: {:ok, map(), map(), map(), [map()]} | {:error, term()}
  defp checkpoints(%Ref{} = ref) do
    with {:ok, initial} <- initial_fixture(ref),
         {:ok, first} <- commit_fixture(initial, :create),
         {:ok, second} <- commit_fixture(first, :update),
         {:ok, stale} <- commit_fixture(first, :stale),
         {:ok, contender_a} <- commit_fixture(second, :contender_a),
         {:ok, contender_b} <- commit_fixture(second, :contender_b),
         {:ok, first} <- encode_fixture(first, ref),
         {:ok, second} <- encode_fixture(second, ref),
         {:ok, stale} <- encode_fixture(stale, ref),
         {:ok, contender_a} <- encode_fixture(contender_a, ref),
         {:ok, contender_b} <- encode_fixture(contender_b, ref) do
      {:ok, first, second, stale, [contender_a, contender_b]}
    else
      {:error, _reason} -> failure(:fixtures, :invalid_checkpoint)
    end
  end

  @spec initial_fixture(Ref.t()) :: {:ok, Canonical.t()} | {:error, term()}
  defp initial_fixture(%Ref{} = ref) do
    Canonical.new(%{
      flow: %State{conversation_id: ref.key},
      work: %{},
      vigil: %{},
      directive: %{},
      control: %{},
      correlations: %{instance_key: ref.key},
      events: %{records: [], ids: %{}}
    })
  end

  @spec commit_fixture(Canonical.t(), atom()) :: {:ok, Canonical.t()} | {:error, term()}
  defp commit_fixture(canonical, label) do
    revision = canonical.revision + 1

    with {:ok, correlations} <- Canonical.fetch(canonical, :correlations),
         {:ok, snapshot} <-
           Canonical.snapshot(canonical,
             read: [:correlations],
             write: [:correlations],
             id: "checkpoint-store-conformance-snapshot-#{label}",
             correlation_id: "checkpoint-store-conformance-#{label}"
           ),
         {:ok, change} <-
           Canonical.change(
             snapshot,
             %{correlations: Map.put(correlations, :conformance_marker, label)},
             id: "checkpoint-store-conformance-change-#{label}",
             provenance: %{source: :checkpoint_store_conformance},
             metadata: %{revision: revision, marker: label}
           ),
         {:ok, committed, _transition} <- Canonical.commit(canonical, change) do
      {:ok, committed}
    end
  end

  @spec encode_fixture(Canonical.t(), Ref.t()) ::
          {:ok, %{json: String.t(), digest: String.t()}} | {:error, term()}
  defp encode_fixture(canonical, ref) do
    with :ok <- Validator.validate(canonical, ref),
         {:ok, json} <- Codec.encode_json(canonical),
         {:ok, report} <- Foundation.verify_instance_checkpoint(json) do
      {:ok, %{json: json, digest: report.digest}}
    end
  end

  @spec normalize_store(CheckpointStore.config()) ::
          {:ok, {module(), keyword()}} | {:error, term()}
  defp normalize_store(store) do
    case CheckpointStore.normalize(store) do
      {:ok, {module, opts} = normalized} when is_atom(module) and is_list(opts) ->
        if Keyword.keyword?(opts), do: {:ok, normalized}, else: failure(:configuration, :invalid)

      _other ->
        failure(:configuration, :invalid)
    end
  end

  @spec exact_retry(
          {module(), keyword()},
          Ref.t(),
          %{json: String.t(), digest: String.t()}
        ) :: {:ok, :accepted | :readback_verified} | {:error, term()}
  defp exact_retry(store, ref, create) do
    result = CheckpointStore.persist(store, ref, create.json, 0, 1, [])

    with :ok <- readback(store, ref, create.digest, :exact_retry) do
      case result do
        :ok -> {:ok, :accepted}
        {:error, _reason} -> {:ok, :readback_verified}
      end
    end
  end

  @spec reject_stale({module(), keyword()}, Ref.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  defp reject_stale(store, ref, stale, current_digest) do
    case CheckpointStore.persist(store, ref, stale, 1, 2, []) do
      :ok -> failure(:stale_write, :accepted)
      {:error, _reason} -> readback(store, ref, current_digest, :stale_write)
    end
  end

  @spec concurrent_cas({module(), keyword()}, Ref.t(), [map()]) ::
          {:ok, String.t()} | {:error, term()}
  defp concurrent_cas(store, ref, contenders) do
    outcomes =
      contenders
      |> Task.async_stream(
        fn contender ->
          {contender.digest, CheckpointStore.persist(store, ref, contender.json, 2, 3, [])}
        end,
        ordered: false,
        max_concurrency: 2,
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    with {:ok, winner} <- race_winner(outcomes),
         :ok <- readback(store, ref, winner, :concurrent_cas) do
      {:ok, winner}
    end
  end

  @spec race_winner([term()]) :: {:ok, String.t()} | {:error, term()}
  defp race_winner([{:ok, {_left, :ok}}, {:ok, {_right, :ok}}]),
    do: failure(:concurrent_cas, :multiple_winners)

  defp race_winner([
         {:ok, {_winner, :ok}},
         {:ok, {_loser, {:error, {:ambiguous, _reason}}}}
       ]),
       do: failure(:concurrent_cas, :ambiguous_loser)

  defp race_winner([
         {:ok, {_loser, {:error, {:ambiguous, _reason}}}},
         {:ok, {_winner, :ok}}
       ]),
       do: failure(:concurrent_cas, :ambiguous_loser)

  defp race_winner([{:ok, {winner, :ok}}, {:ok, {_loser, {:error, _reason}}}]),
    do: {:ok, winner}

  defp race_winner([{:ok, {_loser, {:error, _reason}}}, {:ok, {winner, :ok}}]),
    do: {:ok, winner}

  defp race_winner([
         {:ok, {_left, {:error, _left_reason}}},
         {:ok, {_right, {:error, _right_reason}}}
       ]),
       do: failure(:concurrent_cas, :no_winner)

  defp race_winner(_outcomes), do: failure(:concurrent_cas, :callback_failed)

  @spec write(
          {module(), keyword()},
          Ref.t(),
          String.t(),
          non_neg_integer(),
          non_neg_integer(),
          atom()
        ) :: :ok | {:error, term()}
  defp write(store, ref, checkpoint, expected, revision, phase) do
    case CheckpointStore.persist(store, ref, checkpoint, expected, revision, []) do
      :ok -> :ok
      {:error, _reason} -> failure(phase, :write_rejected)
    end
  end

  @spec readback({module(), keyword()}, Ref.t(), String.t(), atom()) ::
          :ok | {:error, term()}
  defp readback(store, ref, expected_digest, phase) do
    with {:ok, checkpoint} <- load(store, ref, phase),
         {:ok, report} <- verify(checkpoint, ref, phase),
         true <- report.digest == expected_digest do
      :ok
    else
      false -> failure(phase, :readback_mismatch)
      :not_found -> failure(phase, :checkpoint_not_found)
      {:error, {:checkpoint_store_conformance_failed, _phase, _code}} = error -> error
    end
  end

  @spec load({module(), keyword()}, Ref.t(), atom()) ::
          :not_found | {:ok, String.t() | map()} | {:error, term()}
  defp load(store, ref, phase) do
    case CheckpointStore.load(store, ref, []) do
      :not_found -> :not_found
      {:ok, checkpoint} -> {:ok, checkpoint}
      {:error, _reason} -> failure(phase, :load_failed)
    end
  end

  @spec verify(String.t() | map(), Ref.t(), atom()) :: {:ok, map()} | {:error, term()}
  defp verify(checkpoint, ref, phase) do
    with {:ok, canonical} <- Codec.decode(checkpoint),
         :ok <- Validator.validate(canonical, ref),
         {:ok, report} <- Foundation.verify_instance_checkpoint(checkpoint) do
      {:ok, report}
    else
      {:error, _reason} -> failure(phase, :invalid_checkpoint)
    end
  end

  @spec failure(atom(), atom()) :: {:error, term()}
  defp failure(phase, code),
    do: {:error, {:checkpoint_store_conformance_failed, phase, code}}
end
