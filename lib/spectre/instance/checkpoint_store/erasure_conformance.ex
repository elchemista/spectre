defmodule Spectre.Instance.CheckpointStore.ErasureConformance do
  @moduledoc """
  Executable conformance gate for Checkpoint Store erasure adapters.

  The runner proves present and absent erasure, marker read-back, idempotency,
  post-erasure write rejection, and an erase-versus-CAS race with one
  authoritative outcome. It has no ExUnit dependency and leaves private
  markers under three derived, isolated Instance references.
  """

  alias Spectre.Foundation.Conformance, as: Foundation
  alias Spectre.Instance.Canonical
  alias Spectre.Instance.Canonical.Codec
  alias Spectre.Instance.CheckpointStore
  alias Spectre.Instance.Erasure.Request
  alias Spectre.Instance.Erasure.Status
  alias Spectre.Instance.Ref
  alias Spectre.State

  @contract_version 1

  @type report :: %{
          required(:contract_version) => pos_integer(),
          required(:present_erasure) => :verified,
          required(:absent_erasure) => :verified,
          required(:idempotency) => :verified,
          required(:post_erasure_write) => :rejected,
          required(:race) => :erase_won | :write_won,
          required(:marker_digest) => String.t()
        }

  @doc "Returns the Checkpoint Store erasure contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc "Runs the complete erasure contract using a fresh Instance Ref."
  @spec run(CheckpointStore.config(), Ref.t(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def run(store, ref, opts \\ [])

  def run(store, %Ref{} = ref, opts) when is_list(opts) do
    with :ok <- options(opts),
         {:ok, store} <- normalize_store(store),
         :ok <- capability(store),
         {:ok, create, update} <- fixtures(ref),
         :ok <- initially_empty(store, ref, :present_initial),
         :ok <- write(store, ref, create, 0, :present_create),
         {:ok, request} <- request(ref, create, opts, "present"),
         {:ok, :erased} <- erase(store, ref, request, :present_erase),
         {:ok, marker} <- erased_readback(store, ref, request, :present_readback),
         {:ok, :already_erased} <- erase(store, ref, request, :idempotent_retry),
         :ok <- reject_write(store, ref, update, create.revision, :post_erasure_write),
         :ok <- absent_erasure(store, ref, opts),
         {:ok, race} <- race(store, ref, opts) do
      {:ok,
       %{
         contract_version: @contract_version,
         present_erasure: :verified,
         absent_erasure: :verified,
         idempotency: :verified,
         post_erasure_write: :rejected,
         race: race,
         marker_digest: Status.digest(marker)
       }}
    else
      {:error, {:checkpoint_store_erasure_conformance_failed, _phase, _code}} = error -> error
    end
  end

  def run(_store, _ref, _opts), do: failure(:options, :invalid_arguments)

  defp absent_erasure(store, ref, opts) do
    absent_ref = Ref.new(ref.agent_ref, {:checkpoint_erasure_absent, ref.key})

    with :ok <- initially_empty(store, absent_ref, :absent_initial),
         {:ok, request} <- request(absent_ref, nil, opts, "absent"),
         {:ok, :erased} <- erase(store, absent_ref, request, :absent_erase),
         {:ok, _status} <- erased_readback(store, absent_ref, request, :absent_readback),
         {:ok, create, _update} <- fixtures(absent_ref) do
      reject_write(store, absent_ref, create, 0, :absent_post_erasure_write)
    end
  end

  defp race(store, ref, opts) do
    race_ref = Ref.new(ref.agent_ref, {:checkpoint_erasure_race, ref.key})

    with :ok <- initially_empty(store, race_ref, :race_initial),
         {:ok, create, update} <- fixtures(race_ref),
         :ok <- write(store, race_ref, create, 0, :race_create),
         {:ok, request} <- request(race_ref, create, opts, "race") do
      outcomes =
        [
          fn -> {:erase, CheckpointStore.erase(store, race_ref, request, [])} end,
          fn ->
            {:write,
             CheckpointStore.persist(
               store,
               race_ref,
               update.json,
               create.revision,
               update.revision,
               []
             )}
          end
        ]
        |> Task.async_stream(& &1.(),
          ordered: false,
          max_concurrency: 2,
          timeout: Keyword.get(opts, :timeout, 5_000),
          on_timeout: :kill_task
        )
        |> Enum.to_list()

      race_outcome(store, race_ref, request, update, outcomes)
    end
  end

  defp race_outcome(store, ref, request, _update, outcomes)
       when outcomes in [
              [ok: {:erase, {:ok, :erased}}, ok: {:write, {:error, :instance_erased}}],
              [ok: {:write, {:error, :instance_erased}}, ok: {:erase, {:ok, :erased}}]
            ] do
    case erased_readback(store, ref, request, :race_erase_readback) do
      {:ok, _status} -> {:ok, :erase_won}
      {:error, _reason} = error -> error
    end
  end

  defp race_outcome(store, ref, request, update, outcomes) do
    normalized = Enum.map(outcomes, &normalize_race_outcome/1)

    case Map.new(normalized) do
      %{erase: {:ok, :erased}, write: {:error, _reason}} ->
        case erased_readback(store, ref, request, :race_erase_readback) do
          {:ok, _status} -> {:ok, :erase_won}
          {:error, _reason} = error -> error
        end

      %{erase: {:error, erase_reason}, write: :ok} ->
        if ambiguous?(erase_reason) do
          failure(:race, :ambiguous_erase_loser)
        else
          verify_write_winner(store, ref, update)
        end

      %{erase: {:ok, _status}, write: :ok} ->
        failure(:race, :multiple_winners)

      %{erase: {:error, _reason}, write: {:error, _other}} ->
        failure(:race, :no_winner)

      _invalid ->
        failure(:race, :invalid_outcomes)
    end
  end

  defp normalize_race_outcome({:ok, {operation, result}}), do: {operation, result}
  defp normalize_race_outcome({:exit, _reason}), do: {:task, :exit}
  defp normalize_race_outcome(_invalid), do: {:task, :invalid}

  defp verify_write_winner(store, ref, update) do
    case {CheckpointStore.load(store, ref, []), CheckpointStore.erasure_status(store, ref, [])} do
      {{:ok, checkpoint}, :not_erased} ->
        case Foundation.verify_instance_checkpoint(checkpoint, ref) do
          {:ok, %{digest: digest}} when digest == update.digest -> {:ok, :write_won}
          _invalid -> failure(:race, :write_readback_mismatch)
        end

      _other ->
        failure(:race, :write_readback_mismatch)
    end
  end

  defp initially_empty(store, ref, phase) do
    case {CheckpointStore.load(store, ref, []), CheckpointStore.erasure_status(store, ref, [])} do
      {:not_found, :not_erased} -> :ok
      _other -> failure(phase, :reference_not_empty)
    end
  end

  defp erased_readback(store, ref, request, phase) do
    case {CheckpointStore.load(store, ref, []), CheckpointStore.erasure_status(store, ref, [])} do
      {:not_found, {:ok, %Status{} = status}} ->
        if status.instance_key == ref.key and status.erasure_id == request.erasure_id,
          do: {:ok, status},
          else: failure(phase, :marker_mismatch)

      {{:ok, _checkpoint}, _status} ->
        failure(phase, :checkpoint_still_present)

      _other ->
        failure(phase, :marker_missing)
    end
  end

  defp erase(store, ref, request, phase) do
    case CheckpointStore.erase(store, ref, request, []) do
      {:ok, status} when status in [:erased, :already_erased] -> {:ok, status}
      {:error, _reason} -> failure(phase, :erase_rejected)
    end
  end

  defp write(store, ref, fixture, expected, phase) do
    case CheckpointStore.persist(store, ref, fixture.json, expected, fixture.revision, []) do
      :ok -> :ok
      {:error, _reason} -> failure(phase, :write_rejected)
    end
  end

  defp reject_write(store, ref, fixture, expected, phase) do
    case CheckpointStore.persist(store, ref, fixture.json, expected, fixture.revision, []) do
      :ok -> failure(phase, :write_accepted)
      {:error, {:ambiguous, _reason}} -> failure(phase, :ambiguous_rejection)
      {:error, _reason} -> :ok
    end
  end

  defp request(ref, fixture, opts, label) do
    attrs = [
      erasure_id: "checkpoint-erasure-conformance-#{label}-#{ref.key}",
      expected_revision: fixture && fixture.revision,
      checkpoint_digest: fixture && fixture.digest,
      owner_fencing_token: Keyword.get(opts, :owner_fencing_token, 11),
      requested_at: Keyword.get(opts, :now, 1)
    ]

    case Request.new(ref, attrs) do
      {:ok, request} -> {:ok, request}
      {:error, _reason} -> failure(:fixtures, :invalid_erasure_request)
    end
  end

  defp fixtures(ref) do
    with {:ok, initial} <-
           Canonical.new(%{
             flow: %State{conversation_id: ref.key},
             work: %{},
             vigil: %{},
             directive: %{},
             control: %{},
             correlations: %{instance_key: ref.key},
             events: %{records: [], ids: %{}}
           }),
         {:ok, create} <- commit(initial, ref, :create),
         {:ok, update} <- commit(create.canonical, ref, :update) do
      {:ok, Map.delete(create, :canonical), Map.delete(update, :canonical)}
    else
      {:error, _reason} -> failure(:fixtures, :invalid_checkpoint)
    end
  end

  defp commit(canonical, ref, label) do
    with {:ok, correlations} <- Canonical.fetch(canonical, :correlations),
         {:ok, snapshot} <-
           Canonical.snapshot(canonical,
             read: [:correlations],
             write: [:correlations],
             id: "checkpoint-erasure-snapshot-#{label}",
             correlation_id: "checkpoint-erasure-#{label}"
           ),
         {:ok, change} <-
           Canonical.change(
             snapshot,
             %{correlations: Map.put(correlations, :erasure_marker, label)},
             id: "checkpoint-erasure-change-#{label}",
             provenance: %{source: :checkpoint_store_erasure_conformance},
             metadata: %{revision: canonical.revision + 1}
           ),
         {:ok, committed, _transition} <- Canonical.commit(canonical, change),
         {:ok, json} <- Codec.encode_json(committed),
         {:ok, report} <- Foundation.verify_instance_checkpoint(json, ref) do
      {:ok,
       %{
         canonical: committed,
         json: json,
         revision: report.revision,
         digest: report.digest
       }}
    end
  end

  defp normalize_store(store) do
    case CheckpointStore.normalize(store) do
      {:ok, {module, store_opts} = normalized}
      when is_atom(module) and is_list(store_opts) ->
        if Keyword.keyword?(store_opts),
          do: {:ok, normalized},
          else: failure(:configuration, :invalid_store)

      _invalid ->
        failure(:configuration, :invalid_store)
    end
  end

  defp capability(store) do
    case CheckpointStore.erasure_capability(store) do
      :ok -> :ok
      {:error, _reason} -> failure(:configuration, :erasure_unsupported)
    end
  end

  defp options(opts) do
    with :ok <- keyword_options(opts),
         :ok <- known_options(opts),
         :ok <- positive_option(opts, :owner_fencing_token, 11, :invalid_fencing_token),
         :ok <- non_negative_option(opts, :now, 1, :invalid_now) do
      positive_option(opts, :timeout, 5_000, :invalid_timeout)
    end
  end

  defp keyword_options(opts) do
    if Keyword.keyword?(opts), do: :ok, else: failure(:options, :invalid_keyword)
  end

  defp known_options(opts) do
    if Keyword.keys(opts) -- [:owner_fencing_token, :now, :timeout] == [],
      do: :ok,
      else: failure(:options, :unknown_options)
  end

  defp positive_option(opts, key, default, code) do
    value = Keyword.get(opts, key, default)
    if is_integer(value) and value > 0, do: :ok, else: failure(:options, code)
  end

  defp non_negative_option(opts, key, default, code) do
    value = Keyword.get(opts, key, default)
    if is_integer(value) and value >= 0, do: :ok, else: failure(:options, code)
  end

  defp ambiguous?({:ambiguous, _reason}), do: true
  defp ambiguous?(_reason), do: false

  defp failure(phase, code),
    do: {:error, {:checkpoint_store_erasure_conformance_failed, phase, code}}
end
