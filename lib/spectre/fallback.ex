defmodule Spectre.Fallback do
  @moduledoc """
  Fail-closed handling for a declared refusal policy.

  A fallback is either silence or a fresh Candidate built from a static
  template. It applies only to `:refused`: `:undecidable` and `:unknown_class`
  remain distinct queryable outcomes. It never reuses the refused Candidate's
  Evidence, Presentation or resolved Mandate. The returned Candidate still
  crosses normal admission and receives no special authority. A Decision
  produced for a fallback is not eligible for another fallback, preventing
  recursive chains.
  """

  alias Spectre.Candidate
  alias Spectre.Decision
  alias Spectre.Fallback.Policy
  alias Spectre.SubmissionContext

  @type result :: :silence | {:candidate_template | :governed_handoff, Candidate.t()}

  @doc "Materializes the one declared response to an explicitly refused Decision."
  @spec materialize(Policy.t() | map() | atom(), Decision.t(), SubmissionContext.t()) ::
          {:ok, result()} | {:error, term()}
  def materialize(policy, %Decision{} = decision, %SubmissionContext{} = context) do
    with {:ok, policy} <- Policy.new(policy),
         {:ok, decision} <- Decision.new(decision),
         {:ok, context} <- SubmissionContext.new(context),
         :ok <- refused(decision),
         :ok <- not_recursive(decision),
         :ok <- decision_context(decision, context) do
      materialize_policy(policy, decision, context)
    end
  end

  def materialize(_policy, _decision, _context), do: {:error, :invalid_fallback_input}

  defp materialize_policy(%Policy{mode: :silence}, _decision, _context),
    do: {:ok, :silence}

  defp materialize_policy(%Policy{} = policy, decision, context) do
    attrs =
      policy.template
      |> Map.put("identity_key", "fallback:" <> decision.ref)
      |> Map.put("proposer_ref", context.authenticated_principal_ref)
      |> Map.put("scope_ref", context.scope_ref)

    with {:ok, candidate} <- Candidate.new(attrs), do: {:ok, {policy.mode, candidate}}
  end

  defp refused(%Decision{outcome: :refused}), do: :ok
  defp refused(%Decision{outcome: outcome}), do: {:error, {:fallback_not_applicable, outcome}}

  defp not_recursive(%Decision{candidate_identity_key: "fallback:" <> _suffix}),
    do: {:error, :recursive_fallback_forbidden}

  defp not_recursive(%Decision{}), do: :ok

  defp decision_context(decision, context) do
    durable_context =
      ~w(domain_ref scope_ref authenticated_principal_ref authentication_ref ingress_ref channel_ref session_ref)a

    case Enum.find(durable_context, &(Map.fetch!(decision, &1) != Map.fetch!(context, &1))) do
      nil -> :ok
      field -> {:error, {:fallback_context_mismatch, field}}
    end
  end
end

defmodule Spectre.Fallback.Policy do
  @moduledoc """
  Portable refusal policy embedded in a governed Surface declaration.

  Templates omit occurrence identity, proposer and Scope.  Those values are
  bound to the refused Decision's authenticated context at materialization.
  Evidence, consent, Presentation and requested Mandate default to empty/nil
  rather than being copied from the refused proposal.
  """

  alias Spectre.Candidate
  alias Spectre.Portable

  @schema_version 1
  @modes [:silence, :candidate_template, :governed_handoff]
  @fields [:schema_version, :mode, :template]
  @template_fields [
    :class,
    :consequence,
    :row,
    :requested_mandate_ref,
    :executor_ref,
    :accountable_ref,
    :subject_refs,
    :target_refs,
    :purpose_ref,
    :purpose_params,
    :consent,
    :evidence_refs,
    :disclosure,
    :presentation_ref,
    :meter_requests,
    :executor_contract_ref,
    :observation_window_ms
  ]

  @enforce_keys [:schema_version, :mode, :template]
  defstruct @enforce_keys

  @type mode :: :silence | :candidate_template | :governed_handoff
  @type t :: %__MODULE__{schema_version: 1, mode: mode(), template: map() | nil}

  @doc "Builds and validates a fallback policy."
  @spec new(t() | map() | keyword() | atom()) :: {:ok, t()} | {:error, term()}
  def new(:silence), do: {:ok, %__MODULE__{schema_version: 1, mode: :silence, template: nil}}
  def new(%__MODULE__{} = policy), do: policy |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :fallback_policy),
         attrs <- Map.put_new(attrs, :schema_version, @schema_version),
         mode <- Map.get(attrs, :mode),
         {:ok, template} <- normalize_template(mode, Map.get(attrs, :template)),
         policy = struct(__MODULE__, Map.put(attrs, :template, template)),
         :ok <- validate(policy),
         :ok <- Portable.validate(canonical(policy)) do
      {:ok, policy}
    end
  end

  @doc "Returns the exact value embedded in a Surface."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = policy) do
    %{
      "schema_version" => policy.schema_version,
      "mode" => policy.mode,
      "template" => policy.template
    }
  end

  @doc "Restores a policy while rejecting noncanonical templates."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value) when is_map(value) and not is_struct(value) do
    with {:ok, policy} <- new(value),
         true <- value == canonical(policy) do
      {:ok, policy}
    else
      false -> {:error, :noncanonical_fallback_policy}
      {:error, _reason} = error -> error
    end
  end

  def from_canonical(_value), do: {:error, :invalid_fallback_policy}

  defp normalize_template(:silence, nil), do: {:ok, nil}

  defp normalize_template(mode, value)
       when mode in [:candidate_template, :governed_handoff] do
    with {:ok, attrs} <- Portable.normalize_attrs(value, @template_fields, :fallback_template),
         attrs <- fallback_defaults(attrs),
         {:ok, candidate} <-
           attrs
           |> Map.put(:identity_key, "fallback-template")
           |> Map.put(:proposer_ref, "fallback-template-proposer")
           |> Map.put(:scope_ref, "fallback-template-scope")
           |> Candidate.new() do
      {:ok,
       candidate
       |> Candidate.canonical()
       |> Map.drop(~w(schema_version ref identity_key material_digest proposer_ref scope_ref))}
    end
  end

  defp normalize_template(_mode, _value), do: {:error, :invalid_fallback_template}

  defp fallback_defaults(attrs) do
    attrs
    |> Map.put_new(:requested_mandate_ref, nil)
    |> Map.put_new(:subject_refs, [])
    |> Map.put_new(:target_refs, [])
    |> Map.put_new(:purpose_params, %{})
    |> Map.put_new(:consent, nil)
    |> Map.put_new(:evidence_refs, [])
    |> Map.put_new(:disclosure, nil)
    |> Map.put_new(:presentation_ref, nil)
    |> Map.put_new(:meter_requests, %{})
    |> Map.put_new(:observation_window_ms, 0)
  end

  defp validate(%__MODULE__{} = policy) do
    cond do
      policy.schema_version != @schema_version ->
        {:error, {:unsupported_fallback_policy_schema_version, policy.schema_version}}

      policy.mode not in @modes ->
        {:error, {:invalid_fallback_mode, policy.mode}}

      policy.mode == :silence and not is_nil(policy.template) ->
        {:error, :silence_fallback_has_template}

      policy.mode != :silence and not is_map(policy.template) ->
        {:error, :fallback_template_required}

      true ->
        :ok
    end
  end
end
