defmodule Spectre.GAM.Attempt.Executor do
  @moduledoc """
  Executes one already-committed governed Act.

  Implementations are Zone X adapters. They receive no authority to alter the
  Act; `capability` is the short-lived host handle released only after the
  corresponding Attempt has been committed.

  Results cross back into the governed record layer, so they contain only
  validated `Spectre.GAM.Evidence` and an opaque, non-empty `details_ref`. Raw
  provider replies, exceptions, credentials and reusable bearer material are
  not valid result metadata. Evidence may be empty only for an ambiguous result.

  `use Spectre.GAM.Attempt.Executor, executor_ref: "executor:payments",
  contract_ref: "contract:payments:v1"` declares the behaviour and overridable
  identity callbacks. Both references are explicit. It supplies no `execute/4`
  implementation, credentials, retry policy or Outcome classification.
  """

  alias Spectre.GAM.{Act, Attempt, Evidence, Outcome, Portable}
  alias Spectre.GAM.Attempt.Binding
  alias Spectre.GAM.Attempt.Evidence, as: AttemptEvidence

  @outcome_statuses Outcome.statuses()

  @evidence_fields [
    :ref,
    :proposition,
    :stance,
    :provenance,
    :parent_refs,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :assumptions,
    :labels,
    :payload,
    :payload_ref,
    :provisional
  ]
  @outcome_evidence_fields [
    :ref,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :labels,
    :payload,
    :payload_ref
  ]

  @type observation :: %{
          required(:evidence) => Evidence.t() | [Evidence.t()],
          required(:details_ref) => String.t()
        }

  @type result ::
          {:ok, observation()}
          | {:error, :failed, observation()}
          | {:error, :definitive_no_effect, observation()}
          | {:error, :ambiguous, observation()}

  @doc "Builds executor-attested Evidence with the Act and Attempt bindings forced."
  @spec evidence(Act.t(), Attempt.t(), integer(), map() | keyword()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def evidence(%Act{} = act, %Attempt{} = attempt, observed_at, attrs)
      when is_integer(observed_at) do
    with {:ok, act} <- Act.new(act),
         {:ok, attempt} <- Attempt.new(attempt),
         {:ok, attrs} <-
           Portable.normalize_attrs(attrs, @evidence_fields, :executor_evidence),
         attrs =
           attrs
           |> Map.put_new(:provenance, :observed)
           |> Map.put_new(:parent_refs, []),
         {:ok, evidence} <-
           attrs
           |> Map.put(:issuer_ref, act.executor_ref)
           |> Map.put(:source_ref, act.executor_ref)
           |> Map.put(:observed_at, observed_at)
           |> Map.put(:bindings, Binding.evidence_bindings(act, attempt))
           |> Evidence.new(),
         :ok <- AttemptEvidence.validate(evidence, act, attempt) do
      {:ok, evidence}
    end
  end

  def evidence(_act, _attempt, _observed_at, _attrs),
    do: {:error, :invalid_executor_evidence}

  @doc "Builds a final Evidence attestation for one exact Outcome classification."
  @spec outcome_evidence(
          Act.t(),
          Attempt.t(),
          Outcome.status(),
          integer(),
          map() | keyword()
        ) :: {:ok, Evidence.t()} | {:error, term()}
  def outcome_evidence(%Act{} = act, %Attempt{} = attempt, status, observed_at, attrs)
      when status in @outcome_statuses and is_integer(observed_at) do
    with {:ok, act} <- Act.new(act),
         {:ok, attempt} <- Attempt.new(attempt),
         {:ok, attrs} <-
           Portable.normalize_attrs(
             attrs,
             @outcome_evidence_fields,
             :executor_outcome_evidence
           ) do
      attrs
      |> Map.merge(%{
        proposition: Outcome.proposition(status, act.ref, attempt.ref, act.executor_contract_ref),
        stance: Outcome.evidence_stance(status),
        provenance: :observed,
        parent_refs: [],
        assumptions: [],
        provisional: false
      })
      |> then(&evidence(act, attempt, observed_at, &1))
    end
  end

  def outcome_evidence(_act, _attempt, _status, _observed_at, _attrs),
    do: {:error, :invalid_executor_outcome_evidence}

  @doc "Returns the stable executor identity accepted by this adapter."
  @callback executor_ref() :: String.t()

  @doc "Returns the immutable contract revision implemented by this adapter."
  @callback contract_ref() :: String.t()

  @doc "Invokes the admitted Act using its Attempt and scoped capability, then reports the observed result."
  @callback execute(Act.t(), Attempt.t(), term(), keyword()) :: result()

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour Spectre.GAM.Attempt.Executor
      opts = Spectre.GAM.Adapter.use_options!(opts, [:executor_ref, :contract_ref])
      @spectre_executor_ref Keyword.fetch!(opts, :executor_ref)
      @spectre_executor_contract_ref Keyword.fetch!(opts, :contract_ref)

      @impl true
      def executor_ref, do: @spectre_executor_ref

      @impl true
      def contract_ref, do: @spectre_executor_contract_ref

      defoverridable executor_ref: 0, contract_ref: 0
    end
  end
end
