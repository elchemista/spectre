defmodule Spectre.Payload.Store do
  @moduledoc """
  Host boundary for content-addressed payloads kept outside the Domain ledger.

  A configured adapter must verify both presence and digest correspondence for
  the supplied `payload:<sha256>` reference. Spectre verifies live references
  during recovery and again before use. A durable erasure Attempt is the only
  reason a referenced payload may be absent; its ledger tombstone remains.
  """

  alias Spectre.{Act, Adapter, Disclosure, Portable}
  alias Spectre.Erasure.Analysis
  alias Spectre.GovernedAct.{ReadIndex, State}
  alias Spectre.Presentation

  @type ref :: String.t()
  @type config :: module() | {module(), keyword()}

  @callback verify(ref(), keyword()) :: :ok | {:error, :not_found | term()}

  @spec normalize(config() | nil) :: {:ok, {module(), keyword()} | nil} | {:error, term()}
  def normalize(nil), do: {:ok, nil}

  def normalize(module) when is_atom(module) and not is_nil(module),
    do: normalize({module, []})

  def normalize({module, opts})
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         :ok <- Adapter.validate(module, verify: 2) do
      {:ok, {module, opts}}
    else
      false -> {:error, :invalid_payload_store_options}
      {:error, _reason} -> {:error, {:payload_store_unavailable, module}}
    end
  end

  def normalize(_config), do: {:error, :invalid_payload_store}

  @spec verify(config() | nil, ref()) :: :ok | {:error, term()}
  def verify(config, ref) do
    with :ok <- validate_ref(ref),
         {:ok, normalized} <- normalize(config) do
      verify_normalized(normalized, ref)
    end
  end

  @doc "Verifies every payload which the durable projection still classifies as live."
  @spec verify_live_references(config() | nil, State.t()) :: :ok | {:error, term()}
  def verify_live_references(config, %State{} = state) do
    state
    |> referenced_payloads()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      result =
        case Analysis.execution_state(state, ref) do
          {:ok, :live} -> verify_live(config, ref)
          {:ok, state} when state in [:possibly_absent, :erased] -> :ok
          {:error, _reason} = error -> error
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def verify_live_references(_config, _facts), do: {:error, :invalid_payload_projection}

  @doc false
  @spec introduced_refs([map()]) :: [ref()]
  def introduced_refs(payloads) when is_list(payloads) do
    payloads
    |> Enum.flat_map(&introduced_payload_refs/1)
    |> Enum.uniq()
  end

  def introduced_refs(_payloads), do: []

  defp introduced_payload_refs(%{"type" => "evidence_recorded", "data" => data})
       when is_map(data),
       do: optional_ref(Map.get(data, "payload_ref"))

  defp introduced_payload_refs(%{"type" => "presentation_recorded", "data" => data})
       when is_map(data),
       do: optional_ref(Map.get(data, "rendered_payload_ref"))

  defp introduced_payload_refs(_payload), do: []

  @doc "Verifies refs at their point of use and reports causal unavailability explicitly."
  @spec verify_usable(config() | nil, State.t(), [ref()]) :: :ok | {:error, term()}
  def verify_usable(config, %State{} = state, refs) when is_list(refs) do
    refs
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      result =
        case Analysis.execution_state(state, ref) do
          {:ok, :live} -> verify(config, ref)
          {:ok, :possibly_absent} -> {:error, {:payload_temporarily_unavailable, ref}}
          {:ok, :erased} -> {:error, {:payload_redacted, ref}}
          {:error, _reason} = error -> error
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def verify_usable(_config, _facts, _refs), do: {:error, :invalid_payload_use}

  @doc "Verifies a newly introduced ref and prevents resurrection after an erasure Attempt."
  @spec verify_new_references(config() | nil, State.t(), [ref()]) :: :ok | {:error, term()}
  def verify_new_references(config, %State{} = state, refs) when is_list(refs) do
    refs
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn ref, :ok ->
      result =
        case Analysis.execution_state(state, ref) do
          {:ok, :live} -> verify(config, ref)
          {:ok, state} -> {:error, {:payload_reference_retired, ref, state}}
          {:error, _reason} = error -> error
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  def verify_new_references(_config, _facts, _refs),
    do: {:error, :invalid_new_payload_references}

  @doc "Returns external payload refs which must be usable before an Attempt is recorded."
  @spec act_payload_refs(State.t(), Act.t()) :: [ref()]
  def act_payload_refs(%State{} = state, %Act{} = act) do
    act_evidence_refs = evidence_payload_refs(act.evidence_refs, state)

    evidence_refs =
      act
      |> disclosure_evidence_refs()
      |> evidence_payload_refs(state)

    erasure_refs =
      case act.consequence do
        %{"erasure_request" => %{"target_ref" => ref}} -> [ref]
        _other -> []
      end

    presentation_refs =
      case Presentation.show_presentation_ref(act.consequence) do
        {:ok, ref} ->
          case Map.get(state.presentations, ref) do
            nil -> []
            presentation -> optional_ref(presentation.rendered_payload_ref)
          end

        {:error, _reason} ->
          []
      end

    (act_evidence_refs ++ evidence_refs ++ erasure_refs ++ presentation_refs)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def act_payload_refs(_facts, _act), do: []

  @doc "Returns payload refs still needed after an Attempt has made its target mutable."
  @spec post_attempt_payload_refs(State.t(), Act.t()) :: [ref()]
  def post_attempt_payload_refs(%State{} = state, %Act{} = act) do
    state
    |> act_payload_refs(act)
    |> Kernel.--(erasure_target_refs(act))
  end

  def post_attempt_payload_refs(_facts, _act), do: []

  @doc false
  @spec evidence_payload_refs([String.t()], State.t()) :: [ref()]
  def evidence_payload_refs(evidence_refs, %State{} = state) when is_list(evidence_refs) do
    evidence_refs
    |> Enum.flat_map(fn ref ->
      case Map.get(state.evidence, ref) do
        nil -> []
        evidence -> optional_ref(evidence.payload_ref)
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  def evidence_payload_refs(_evidence_refs, _facts), do: []

  defp verify_normalized(nil, ref), do: {:error, {:payload_store_required, ref}}

  defp verify_normalized({module, opts}, ref) do
    case Adapter.invoke(module, :verify, [ref, opts]) do
      {:ok, :ok} ->
        :ok

      {:ok, {:error, :not_found}} ->
        {:error, {:payload_not_found, ref}}

      {:ok, {:error, reason}} ->
        {:error, {:payload_verification_failed, ref, reason}}

      {:ok, _invalid} ->
        {:error, {:invalid_payload_store_response, module}}

      {:error, {:adapter_callback_exception, _, _, exception}} ->
        {:error, {:payload_store_exception, module, exception}}

      {:error, {:adapter_callback_failure, _, _, kind}} ->
        {:error, {:payload_store_failure, module, kind}}
    end
  end

  defp verify_live(config, ref) do
    case verify(config, ref) do
      {:error, {:payload_not_found, ^ref}} -> {:error, {:unexpected_missing_payload, ref}}
      result -> result
    end
  end

  defp referenced_payloads(state) do
    if ReadIndex.complete?(state) do
      state.read_index.payload_refs |> Enum.sort()
    else
      unindexed_payloads(state)
    end
  end

  defp unindexed_payloads(state) do
    evidence_refs =
      state.evidence
      |> Map.values()
      |> Enum.flat_map(&optional_ref(&1.payload_ref))

    presentation_refs =
      state.presentations
      |> Map.values()
      |> Enum.flat_map(&optional_ref(&1.rendered_payload_ref))

    (evidence_refs ++ presentation_refs) |> Enum.uniq() |> Enum.sort()
  end

  defp optional_ref(nil), do: []
  defp optional_ref(ref), do: [ref]

  defp disclosure_evidence_refs(%Act{disclosure: nil}), do: []

  defp disclosure_evidence_refs(%Act{disclosure: %Disclosure{} = disclosure}),
    do: disclosure.source_evidence_refs

  defp erasure_target_refs(%Act{} = act) do
    case act.consequence do
      %{"erasure_request" => %{"target_ref" => ref}} -> [ref]
      _other -> []
    end
  end

  defp validate_ref(ref) when is_binary(ref) do
    if Portable.validate_content_ref(ref, :payload, :payload_ref) == :ok,
      do: :ok,
      else: {:error, {:invalid_payload_ref, ref}}
  end

  defp validate_ref(ref), do: {:error, {:invalid_payload_ref, ref}}
end
