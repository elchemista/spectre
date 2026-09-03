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
  projection or trusted time.
  """

  alias Spectre.Candidate
  alias Spectre.Erasure
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Mandate

  @none "spectre:consequence-validator:none:v1"
  @erasure_request "spectre:consequence-validator:erasure-request:v1"
  @mandate_revocation "spectre:consequence-validator:mandate-revocation:v1"

  @validators [@none, @erasure_request, @mandate_revocation]
  @class_defaults %{
    "data.erase" => @erasure_request,
    "mandate.revoke" => @mandate_revocation
  }

  @type id :: String.t()

  @doc "Identifier for classes whose contract needs no projection-dependent rule."
  @spec none() :: id()
  def none, do: @none

  @doc "Returns the built-in default recorded for a class by a new Surface."
  @spec default_for_class(String.t()) :: id()
  def default_for_class(class) when is_binary(class), do: Map.get(@class_defaults, class, @none)

  @doc "Validates that an identifier names a deterministic built-in rule."
  @spec validate_id(term()) :: :ok | {:error, term()}
  def validate_id(id) when id in @validators, do: :ok
  def validate_id(id), do: {:error, {:unknown_consequence_validator, id}}

  @doc "Applies the validator selected by the active Surface."
  @spec validate(id(), Candidate.t(), map(), integer()) :: :ok | {:error, term()}
  def validate(@none, %Candidate{}, _projection, time) when is_integer(time), do: :ok

  def validate(@erasure_request, %Candidate{} = candidate, projection, time)
      when is_map(projection) and is_integer(time) do
    validate_erasure_request(candidate, projection, time)
  end

  def validate(@mandate_revocation, %Candidate{} = candidate, projection, time)
      when is_map(projection) and is_integer(time) do
    validate_mandate_revocation(candidate, projection, time)
  end

  def validate(id, %Candidate{}, _projection, _time) when id in @validators,
    do: {:error, :invalid_consequence_validator_input}

  def validate(id, _candidate, _projection, _time),
    do: {:error, {:unknown_consequence_validator, id}}

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
