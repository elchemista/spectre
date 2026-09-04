defmodule Spectre.Interop do
  @moduledoc """
  Portable exchange boundary between independently governed Domains.

  An envelope carries only a Candidate and its Evidence closure. It cannot
  carry a Mandate, Decision, Act, Grant or execution capability. Receiving an
  envelope therefore does not import authority: the destination application's
  authenticated ingress decides how to attest the message as local Evidence,
  and every resulting proposal is evaluated under a local Mandate.

  Transport authentication, signatures, peer identity and label mapping remain
  adapter concerns. `inbound/2` only verifies canonical shape, content identity,
  destination binding and a self-contained Evidence lineage.
  """

  alias Spectre.{Candidate, Evidence, Portable}

  @schema_version 1
  @fields ~w(schema_version ref source_domain_ref destination_domain_ref candidate evidence)

  @typedoc "Canonical string-keyed value suitable for transport or an Evidence payload."
  @type envelope :: %{required(String.t()) => term()}

  @typedoc "Validated, capability-free contents of an inbound envelope."
  @type contents :: %{
          required(:ref) => String.t(),
          required(:source_domain_ref) => String.t(),
          required(:destination_domain_ref) => String.t(),
          required(:candidate) => Candidate.t(),
          required(:evidence) => [Evidence.t()]
        }

  @doc "Builds a content-addressed outbound Candidate + Evidence envelope."
  @spec outbound(
          String.t(),
          String.t(),
          Candidate.t() | map() | keyword(),
          [Evidence.t() | map() | keyword()]
        ) ::
          {:ok, envelope()} | {:error, term()}
  def outbound(source_domain_ref, destination_domain_ref, candidate, evidence)
      when is_list(evidence) do
    with :ok <- Portable.validate_ref(source_domain_ref, :source_domain_ref),
         :ok <- Portable.validate_ref(destination_domain_ref, :destination_domain_ref),
         {:ok, candidate} <- Candidate.new(candidate),
         {:ok, evidence} <- normalize_evidence(evidence),
         :ok <- validate_evidence_closure(candidate, evidence),
         content = content(source_domain_ref, destination_domain_ref, candidate, evidence),
         {:ok, ref} <- Portable.content_ref(:interop, content) do
      envelope = Map.put(content, "ref", ref)

      with :ok <- Portable.validate(envelope), do: {:ok, envelope}
    end
  end

  def outbound(_source_domain_ref, _destination_domain_ref, _candidate, _evidence),
    do: {:error, :invalid_interop_envelope}

  @doc "Validates an inbound envelope for the exact destination Domain."
  @spec inbound(envelope(), String.t()) :: {:ok, contents()} | {:error, term()}
  def inbound(envelope, expected_destination_domain_ref)
      when is_map(envelope) and not is_struct(envelope) do
    with :ok <- exact_keys(envelope),
         true <- envelope["schema_version"] == @schema_version,
         :ok <- Portable.validate_ref(envelope["source_domain_ref"], :source_domain_ref),
         :ok <- Portable.validate_ref(envelope["destination_domain_ref"], :destination_domain_ref),
         :ok <- Portable.validate_ref(expected_destination_domain_ref, :destination_domain_ref),
         true <- envelope["destination_domain_ref"] == expected_destination_domain_ref,
         {:ok, candidate} <- Candidate.from_canonical(envelope["candidate"]),
         {:ok, evidence} <- restore_evidence(envelope["evidence"]),
         :ok <- validate_evidence_closure(candidate, evidence),
         content =
           content(
             envelope["source_domain_ref"],
             envelope["destination_domain_ref"],
             candidate,
             evidence
           ),
         {:ok, expected_ref} <- Portable.content_ref(:interop, content),
         true <- envelope["ref"] == expected_ref,
         :ok <- Portable.validate(envelope) do
      {:ok,
       %{
         ref: expected_ref,
         source_domain_ref: envelope["source_domain_ref"],
         destination_domain_ref: expected_destination_domain_ref,
         candidate: candidate,
         evidence: evidence
       }}
    else
      false -> {:error, :interop_envelope_binding_mismatch}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_interop_envelope}
    end
  end

  def inbound(_envelope, _expected_destination_domain_ref),
    do: {:error, :invalid_interop_envelope}

  defp content(source_domain_ref, destination_domain_ref, candidate, evidence) do
    %{
      "schema_version" => @schema_version,
      "source_domain_ref" => source_domain_ref,
      "destination_domain_ref" => destination_domain_ref,
      "candidate" => Candidate.canonical(candidate),
      "evidence" => Enum.map(evidence, &Evidence.canonical/1)
    }
  end

  defp normalize_evidence(evidence) do
    evidence
    |> Enum.reduce_while({:ok, %{}}, fn value, {:ok, records} ->
      with {:ok, record} <- Evidence.new(value),
           false <- Map.has_key?(records, record.ref) do
        {:cont, {:ok, Map.put(records, record.ref, record)}}
      else
        true -> {:halt, {:error, :duplicate_interop_evidence}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, records |> Map.values() |> Enum.sort_by(& &1.ref)}
      {:error, _reason} = error -> error
    end
  end

  defp restore_evidence(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, records} ->
      case Evidence.from_canonical(value) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} ->
        records = Enum.reverse(records)

        if records == Enum.sort_by(records, & &1.ref),
          do: normalize_evidence(records),
          else: {:error, :noncanonical_interop_evidence_order}

      {:error, _reason} = error ->
        error
    end
  end

  defp restore_evidence(_values), do: {:error, :invalid_interop_evidence}

  defp validate_evidence_closure(candidate, evidence) do
    evidence_by_ref = Map.new(evidence, &{&1.ref, &1})
    available = evidence_by_ref |> Map.keys() |> MapSet.new()

    missing_candidate =
      candidate.evidence_refs
      |> MapSet.new()
      |> MapSet.difference(available)
      |> MapSet.to_list()
      |> Enum.sort()

    missing_parents =
      evidence
      |> Enum.flat_map(& &1.parent_refs)
      |> MapSet.new()
      |> MapSet.difference(available)
      |> MapSet.to_list()
      |> Enum.sort()

    reachable = reachable_evidence(candidate.evidence_refs, evidence_by_ref)

    unrelated =
      available
      |> MapSet.difference(reachable)
      |> MapSet.to_list()
      |> Enum.sort()

    cond do
      missing_candidate != [] ->
        {:error, {:interop_candidate_evidence_missing, missing_candidate}}

      missing_parents != [] ->
        {:error, {:interop_evidence_parents_missing, missing_parents}}

      unrelated != [] ->
        {:error, {:interop_unrelated_evidence, unrelated}}

      true ->
        validate_evidence_lineage(evidence, evidence_by_ref)
    end
  end

  defp validate_evidence_lineage(evidence, evidence_by_ref) do
    with :ok <- acyclic_evidence(evidence, evidence_by_ref) do
      Enum.reduce_while(evidence, :ok, fn record, :ok ->
        parents = Enum.map(record.parent_refs, &Map.fetch!(evidence_by_ref, &1))

        case Enum.find(parents, &(&1.observed_at > record.observed_at)) do
          nil ->
            {:cont, :ok}

          parent ->
            {:halt, {:error, {:interop_evidence_parent_from_future, record.ref, parent.ref}}}
        end
      end)
    end
  end

  defp acyclic_evidence(evidence, evidence_by_ref) do
    Enum.reduce_while(evidence, {:ok, MapSet.new()}, fn record, {:ok, complete} ->
      case visit_evidence(record.ref, evidence_by_ref, MapSet.new(), complete) do
        {:ok, complete} -> {:cont, {:ok, complete}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _complete} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp visit_evidence(ref, evidence_by_ref, visiting, complete) do
    cond do
      MapSet.member?(complete, ref) ->
        {:ok, complete}

      MapSet.member?(visiting, ref) ->
        {:error, {:interop_evidence_cycle, ref}}

      true ->
        visiting = MapSet.put(visiting, ref)

        evidence_by_ref
        |> Map.fetch!(ref)
        |> Map.fetch!(:parent_refs)
        |> Enum.reduce_while({:ok, complete}, fn parent_ref, {:ok, accumulated} ->
          case visit_evidence(parent_ref, evidence_by_ref, visiting, accumulated) do
            {:ok, accumulated} -> {:cont, {:ok, accumulated}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, accumulated} -> {:ok, MapSet.put(accumulated, ref)}
          {:error, _reason} = error -> error
        end
    end
  end

  defp reachable_evidence(seed_refs, evidence_by_ref) do
    walk_evidence(seed_refs, evidence_by_ref, MapSet.new())
  end

  defp walk_evidence([], _evidence_by_ref, visited), do: visited

  defp walk_evidence([ref | rest], evidence_by_ref, visited) do
    if MapSet.member?(visited, ref) do
      walk_evidence(rest, evidence_by_ref, visited)
    else
      parents =
        case Map.get(evidence_by_ref, ref) do
          %Evidence{parent_refs: parent_refs} -> parent_refs
          nil -> []
        end

      walk_evidence(rest ++ parents, evidence_by_ref, MapSet.put(visited, ref))
    end
  end

  defp exact_keys(envelope) do
    if map_size(envelope) == length(@fields) and Enum.all?(@fields, &Map.has_key?(envelope, &1)),
      do: :ok,
      else: {:error, :invalid_interop_envelope_fields}
  end
end
