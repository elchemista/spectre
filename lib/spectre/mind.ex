defmodule Spectre.Mind do
  @moduledoc """
  Capability-free boundary for application deliberation.

  A mind may route, plan, call application code and construct Candidates.  It
  receives no Grant, broker or ledger writer, and its result remains only a
  proposal until each Candidate independently crosses the kernel boundary.
  """

  alias Spectre.{Candidate, Disclosure, Portable}
  alias Spectre.Mind.Turn

  @callback ref() :: String.t()
  @callback deliberate(Turn.t(), keyword()) ::
              {:ok, Candidate.t() | map() | keyword() | [Candidate.t() | map() | keyword()]}
              | {:error, term()}

  @doc "Invokes a mind and normalizes its output to scope-bound Candidates."
  @spec deliberate(module(), Turn.t(), keyword()) ::
          {:ok, [Candidate.t()]} | {:error, term()}
  def deliberate(module, turn, opts \\ [])

  def deliberate(module, %Turn{} = turn, opts)
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, {^module, mind_ref}} <- resolve(module),
         true <- mind_ref == turn.mind_ref,
         {:ok, result} <- safe_deliberate(module, turn, opts),
         {:ok, candidates} <- normalize_result(result),
         :ok <- scope_bound(candidates, turn.scope_ref),
         :ok <- disclosures_bound(candidates, turn) do
      {:ok, candidates}
    else
      false -> {:error, {:mind_turn_binding_mismatch, module}}
      {:error, _reason} = error -> error
    end
  end

  def deliberate(_module, _turn, _opts), do: {:error, :invalid_mind_deliberation}

  @doc false
  @spec resolve(module()) :: {:ok, {module(), String.t()}} | {:error, term()}
  def resolve(module) when is_atom(module) and module not in [nil, true, false] do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :ref, 0),
         true <- function_exported?(module, :deliberate, 2),
         {:ok, ref} <- safe_ref(module),
         :ok <- Portable.validate_ref(ref, :mind_ref) do
      {:ok, {module, ref}}
    else
      false -> {:error, {:mind_unavailable, module}}
      {:error, _reason} = error -> error
    end
  end

  def resolve(module), do: {:error, {:mind_unavailable, module}}

  defp safe_ref(module) do
    case module.ref() do
      ref when is_binary(ref) and ref != "" -> {:ok, ref}
      _invalid -> {:error, {:invalid_mind_ref, module}}
    end
  rescue
    _exception -> {:error, {:mind_ref_failed, module}}
  catch
    _kind, _reason -> {:error, {:mind_ref_failed, module}}
  end

  defp safe_deliberate(module, turn, opts) do
    case module.deliberate(turn, opts) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_mind_result, module}}
    end
  rescue
    exception -> {:error, {:mind_failed, module, exception.__struct__}}
  catch
    kind, _reason -> {:error, {:mind_failed, module, kind}}
  end

  defp normalize_result(result) when is_list(result) do
    if Keyword.keyword?(result), do: normalize_one(result), else: normalize_many(result)
  end

  defp normalize_result(result), do: normalize_one(result)

  defp normalize_many(result) do
    if result == [] do
      {:ok, []}
    else
      Enum.reduce_while(result, {:ok, []}, fn value, {:ok, candidates} ->
        case Candidate.new(value) do
          {:ok, candidate} -> {:cont, {:ok, [candidate | candidates]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp normalize_one(result) do
    with {:ok, candidate} <- Candidate.new(result), do: {:ok, [candidate]}
  end

  defp scope_bound(candidates, scope_ref) do
    case Enum.find(candidates, &(&1.scope_ref != scope_ref)) do
      nil -> :ok
      candidate -> {:error, {:mind_candidate_scope_mismatch, candidate.ref, scope_ref}}
    end
  end

  defp disclosures_bound(candidates, turn) do
    case Enum.find(candidates, &(not disclosure_bound?(&1, turn))) do
      nil -> :ok
      candidate -> {:error, {:mind_candidate_disclosure_mismatch, candidate.ref}}
    end
  end

  defp disclosure_bound?(%Candidate{row: %{disclose: false}, disclosure: nil}, _turn), do: true

  defp disclosure_bound?(%Candidate{disclosure: %Disclosure{} = disclosure}, turn) do
    disclosure.source_evidence_refs == turn.evidence_refs and
      disclosure.labels == turn.context_labels
  end

  defp disclosure_bound?(_candidate, _turn), do: false
end
