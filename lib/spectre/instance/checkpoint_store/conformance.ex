defmodule Spectre.Instance.CheckpointStore.Conformance do
  @moduledoc """
  Adapter-neutral conformance checks for an Instance Checkpoint Store.

  The runner writes two consecutive canonical checkpoints through
  `Spectre.Instance.CheckpointStore`, verifies semantic readback, reconciles an
  exact retry, proves that a stale writer cannot replace revision two, and
  races two revision-three writers to require a single CAS winner. It uses the
  real current checkpoint codec and has no ExUnit dependency.

  A run leaves revision three in storage. Callers must pass a fresh, isolated
  `Spectre.Instance.Ref`; adapter options belong in the ordinary store config.
  """

  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Ref

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
         {:ok, create, update, contenders} <- checkpoints(),
         :not_found <- load(store, ref, :initial_load),
         :ok <- write(store, ref, create.json, 0, 1, :create),
         :ok <- readback(store, ref, create.digest, :create),
         {:ok, retry} <- exact_retry(store, ref, create),
         :ok <- write(store, ref, update.json, 1, 2, :update),
         :ok <- readback(store, ref, update.digest, :update),
         :ok <- reject_stale(store, ref, create.json, update.digest),
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
         {:ok, report} <- verify(checkpoint, :restart_before) do
      readback(after_restart, ref, report.digest, :restart_after)
    else
      :not_found -> failure(:restart_before, :checkpoint_not_found)
      {:error, {:checkpoint_store_conformance_failed, _phase, _code}} = error -> error
    end
  end

  def read_after_restart(_before, _after_restart, _ref),
    do: failure(:options, :invalid_ref)

  @spec checkpoints() :: {:ok, map(), map(), [map()]} | {:error, term()}
  defp checkpoints do
    with {:ok, first} <- commit_fixture(Canonical.new(), 1, :create),
         {:ok, second} <- commit_fixture(first, 2, :update),
         {:ok, contender_a} <- commit_fixture(second, 3, :contender_a),
         {:ok, contender_b} <- commit_fixture(second, 3, :contender_b),
         {:ok, first} <- encode_fixture(first),
         {:ok, second} <- encode_fixture(second),
         {:ok, contender_a} <- encode_fixture(contender_a),
         {:ok, contender_b} <- encode_fixture(contender_b) do
      {:ok, first, second, [contender_a, contender_b]}
    else
      {:error, _reason} -> failure(:fixtures, :invalid_checkpoint)
    end
  end

  @spec commit_fixture(Canonical.t(), 1 | 2 | 3, atom()) ::
          {:ok, Canonical.t()} | {:error, term()}
  defp commit_fixture(canonical, revision, label) do
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

  @spec encode_fixture(Canonical.t()) ::
          {:ok, %{json: String.t(), digest: String.t()}} | {:error, term()}
  defp encode_fixture(canonical) do
    with {:ok, json} <- Codec.encode_json(canonical),
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
    case CheckpointStore.persist(store, ref, stale, 1, 1, []) do
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
        timeout: 30_000,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    winners = for {:ok, {digest, :ok}} <- outcomes, do: digest

    cond do
      Enum.any?(outcomes, &match?({:exit, _reason}, &1)) ->
        failure(:concurrent_cas, :callback_failed)

      winners == [] ->
        failure(:concurrent_cas, :no_winner)

      length(winners) > 1 ->
        failure(:concurrent_cas, :multiple_winners)

      true ->
        [winner] = winners

        case readback(store, ref, winner, :concurrent_cas) do
          :ok -> {:ok, winner}
          {:error, _reason} = error -> error
        end
    end
  end

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
         {:ok, report} <- verify(checkpoint, phase),
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

  @spec verify(String.t() | map(), atom()) :: {:ok, map()} | {:error, term()}
  defp verify(checkpoint, phase) do
    case Foundation.verify_instance_checkpoint(checkpoint) do
      {:ok, report} -> {:ok, report}
      {:error, _reason} -> failure(phase, :invalid_checkpoint)
    end
  end

  @spec failure(atom(), atom()) :: {:error, term()}
  defp failure(phase, code),
    do: {:error, {:checkpoint_store_conformance_failed, phase, code}}
end
