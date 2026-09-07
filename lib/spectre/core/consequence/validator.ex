defmodule Spectre.Consequence.Validator do
  @moduledoc """
  Closed registry of pure, portable consequence validators.

  A `Spectre.Surface` records one validator identifier for every declared
  consequence class.  The identifier, rather than a module or callback, is
  durable data: admission and an independent auditor can therefore replay the
  same rule without executing application code from the ledger.

  Ordinary application classes use `none/0`; their complete material shape is
  still enforced by `Spectre.Consequence.Contract`.  Validators in this module
  exist only for core transitions whose validity depends on the current
  projection or trusted time. Their immutable class binding comes from
  `Spectre.GovernedAct.Class`, not from a callback named in ledger data.
  """

  alias Spectre.{Act, Candidate, Decision}
  alias Spectre.Erasure
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.GovernedAct.Class, as: GovernedClass
  alias Spectre.GovernedAct.{Fold, State}
  alias Spectre.Kernel.Commit
  alias Spectre.Mandate

  @none "spectre:consequence-validator:none:v1"

  @type id :: String.t()

  @doc "Identifier for classes whose contract needs no projection-dependent rule."
  @spec none() :: id()
  def none, do: @none

  @doc "Returns the built-in default recorded for a class by a new Surface."
  @spec default_for_class(String.t()) :: id()
  def default_for_class(class) when is_binary(class) do
    case GovernedClass.validator(class) do
      {:ok, validator} -> validator
      :application -> @none
    end
  end

  @doc "Validates that an identifier names a deterministic built-in rule."
  @spec validate_id(term()) :: :ok | {:error, term()}
  def validate_id(@none), do: :ok

  def validate_id(id) when is_binary(id) do
    if GovernedClass.validator_id?(id),
      do: :ok,
      else: {:error, {:unknown_consequence_validator, id}}
  end

  def validate_id(id), do: {:error, {:unknown_consequence_validator, id}}

  @doc "Validates the immutable class-to-validator binding recorded by a Surface."
  @spec validate_binding(String.t(), term()) :: :ok | {:error, term()}
  def validate_binding(class, id) when is_binary(class) do
    expected = default_for_class(class)

    if id == expected,
      do: :ok,
      else: {:error, {:invalid_consequence_validator_binding, class, id, expected}}
  end

  def validate_binding(class, id),
    do: {:error, {:invalid_consequence_validator_binding, class, id}}

  @doc "Applies the validator selected by the active Surface."
  @spec validate(id(), Candidate.t(), map(), integer()) :: :ok | {:error, term()}
  def validate(id, %Candidate{} = candidate, projection, time)
      when is_map(projection) and is_integer(time) do
    with :ok <- validate_id(id),
         :ok <- validate_binding(candidate.class, id) do
      validate_facts(id, candidate, projection, time)
    end
  end

  def validate(id, _candidate, _projection, _time) do
    with :ok <- validate_id(id), do: {:error, :invalid_consequence_validator_input}
  end

  @doc "Checks an admitted intrinsic transition against a provisional projection."
  @spec validate_transition(id(), Candidate.t(), Decision.t(), Act.t(), State.t()) ::
          :ok | {:error, term()}
  def validate_transition(
        id,
        %Candidate{} = candidate,
        %Decision{outcome: :admitted} = decision,
        %Act{} = act,
        %State{} = projection
      ) do
    with :ok <- validate_id(id) do
      validate_committable_transition(id, candidate, decision, act, projection)
    end
  end

  def validate_transition(id, %Candidate{}, %Decision{}, %Act{}, %State{}) do
    with :ok <- validate_id(id), do: {:error, :invalid_consequence_transition}
  end

  def validate_transition(id, _candidate, _decision, _act, _projection) do
    with :ok <- validate_id(id), do: {:error, :invalid_consequence_transition_input}
  end

  defp validate_facts(_id, %Candidate{class: "data.erase"} = candidate, projection, time) do
    validate_erasure_request(candidate, projection, time)
  end

  defp validate_facts(_id, %Candidate{class: "mandate.revoke"} = candidate, projection, time) do
    validate_mandate_revocation(candidate, projection, time)
  end

  defp validate_facts(_id, %Candidate{}, _projection, _time), do: :ok

  defp validate_committable_transition(id, candidate, decision, act, projection) do
    with :ok <- validate_binding(candidate.class, id),
         true <- act.class == candidate.class,
         {:ok, payloads} <- Commit.payloads(projection, decision, act),
         {:ok, _projection} <- Fold.apply_payloads(projection, payloads, act.committed_at) do
      :ok
    else
      false -> {:error, :consequence_transition_class_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp validate_erasure_request(
         %Candidate{consequence: %{"erasure_request" => draft}} = candidate,
         projection,
         time
       )
       when map_size(candidate.consequence) == 1 do
    with {:ok, canonical} <- Erasure.request_draft(draft),
         true <- canonical == draft,
         true <- canonical["scope_ref"] == candidate.scope_ref,
         true <- canonical["target_ref"] in candidate.target_refs,
         true <- canonical["requested_at"] <= time,
         :ok <- ErasureAnalysis.requestable?(projection, canonical["target_ref"]),
         :ok <- ErasureAnalysis.validate_request(projection, canonical) do
      :ok
    else
      false -> {:error, :invalid_erasure_request}
      {:error, _reason} = error -> error
    end
  end

  defp validate_erasure_request(%Candidate{}, _projection, _time),
    do: {:error, :invalid_erasure_request}

  defp validate_mandate_revocation(
         %Candidate{
           consequence: %{"mandate_revoke" => %{"mandate_ref" => mandate_ref} = command}
         } = candidate,
         projection,
         time
       )
       when map_size(candidate.consequence) == 1 and map_size(command) == 1 do
    with true <- candidate.target_refs == [mandate_ref],
         {:ok, mandate} <- Map.fetch(projection.mandates, mandate_ref),
         {:ok, mandate} <- Mandate.new(mandate),
         true <- candidate.proposer_ref in Map.fetch!(mandate.revocation, "controller_refs"),
         true <- mandate.not_before <= time and time < mandate.expires_at,
         false <- Map.has_key?(projection.revocations, mandate_ref) do
      :ok
    else
      _invalid -> {:error, :invalid_mandate_revocation}
    end
  end

  defp validate_mandate_revocation(%Candidate{}, _projection, _time),
    do: {:error, :invalid_mandate_revocation}
end
