defmodule Spectre.Ingress do
  @moduledoc """
  Authenticated boundary that creates a `Spectre.SubmissionContext`.

  A Domain is wired to exactly one ingress module. `ref/0` must return that
  adapter's stable, non-secret identity; every context and observed Evidence
  produced by the adapter carries the same reference. Candidate payloads and
  ordinary call options are intentionally absent from authentication. They
  cannot select the authenticated principal or replace the Domain's adapter.

  This contract describes the mediated same-BEAM boundary. It does not turn a
  shared VM into a sandbox; stronger deployments isolate the ingress and make
  its authentication mechanism independently verifiable.
  """

  alias Spectre.{Adapter, Evidence, Portable, SubmissionContext}

  @required_callbacks [ref: 0, authenticate: 5, observe: 4]
  @evidence_fields [
    :ref,
    :proposition,
    :stance,
    :issuer_ref,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :bindings,
    :assumptions,
    :labels,
    :payload,
    :payload_ref,
    :provisional
  ]

  @typedoc "Validated module and its stable ingress reference."
  @type binding :: {module(), String.t()}

  @doc "Returns this adapter's stable identity within SubmissionContext records."
  @callback ref() :: String.t()

  @callback authenticate(String.t(), String.t(), term(), non_neg_integer(), keyword()) ::
              {:ok, SubmissionContext.t()} | {:error, term()}

  @callback observe(SubmissionContext.t(), term(), integer(), keyword()) ::
              {:ok, Evidence.t() | [Evidence.t()]} | {:error, term()}

  @doc "Builds observed Evidence with every trusted ingress binding forced by the context."
  @spec evidence(SubmissionContext.t(), integer(), map() | keyword()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def evidence(%SubmissionContext{} = context, observed_at, attrs)
      when is_integer(observed_at) do
    with {:ok, context} <- SubmissionContext.new(context),
         {:ok, attrs} <- Portable.normalize_attrs(attrs, @evidence_fields, :ingress_evidence),
         {:ok, bindings} <-
           SubmissionContext.merge_evidence_bindings(
             context,
             Map.get(attrs, :bindings, %{})
           ) do
      attrs
      |> Map.put(:source_ref, context.ingress_ref)
      |> Map.put(:provenance, :observed)
      |> Map.put(:parent_refs, [])
      |> Map.put(:observed_at, observed_at)
      |> Map.put(:bindings, bindings)
      |> Evidence.new()
    end
  end

  def evidence(_context, _observed_at, _attrs),
    do: {:error, :invalid_ingress_evidence}

  @doc false
  @spec resolve(module()) :: {:ok, binding()} | {:error, term()}
  def resolve(module) when is_atom(module) and not is_nil(module) do
    with :ok <- validate_adapter(module), do: resolve_ref(module)
  end

  def resolve(invalid), do: {:error, {:invalid_ingress, Portable.shape(invalid)}}

  @doc false
  @spec observe(module(), SubmissionContext.t(), term(), integer(), keyword()) ::
          {:ok, [Evidence.t()]} | {:error, term()}
  def observe(module, %SubmissionContext{} = context, input, observed_at, opts)
      when is_integer(observed_at) and is_list(opts) do
    with true <- Keyword.keyword?(opts),
         {:ok, {^module, ingress_ref}} <- resolve(module),
         true <- ingress_ref == context.ingress_ref,
         {:ok, result} <- call_observer(module, context, input, observed_at, opts),
         {:ok, evidence} <- normalize_observation(result),
         :ok <- validate_observation(evidence, context, ingress_ref, observed_at) do
      {:ok, evidence}
    else
      false -> {:error, :invalid_ingress_observation_options_or_binding}
      {:error, _reason} = error -> error
    end
  end

  def observe(_module, _context, _input, _observed_at, _opts),
    do: {:error, :invalid_ingress_observation}

  defp validate_adapter(module) do
    case Adapter.validate(module, @required_callbacks) do
      :ok ->
        :ok

      {:error, {:adapter_callback_missing, ^module, callback, arity}} ->
        {:error, {:ingress_callback_unavailable, module, callback, arity}}

      {:error, _reason} ->
        {:error, {:ingress_module_unavailable, module}}
    end
  end

  defp resolve_ref(module) do
    case Adapter.invoke(module, :ref, []) do
      {:ok, ref} ->
        case Portable.validate_ref(ref, :ingress_ref) do
          :ok -> {:ok, {module, ref}}
          {:error, _reason} -> {:error, {:invalid_ingress_ref, module, Portable.shape(ref)}}
        end

      {:error, _reason} ->
        {:error, {:ingress_ref_unavailable, module}}
    end
  end

  defp call_observer(module, context, input, observed_at, opts) do
    case Adapter.invoke(module, :observe, [context, input, observed_at, opts]) do
      {:ok, {:ok, evidence}} ->
        {:ok, evidence}

      {:ok, {:error, _reason} = error} ->
        error

      {:ok, _invalid} ->
        {:error, :invalid_ingress_observation_response}

      {:error, {:adapter_callback_exception, _, _, exception}} ->
        {:error, {:ingress_observation_exception, exception}}

      {:error, {:adapter_callback_failure, _, _, kind}} ->
        {:error, {:ingress_observation_failure, kind}}
    end
  end

  defp normalize_observation(evidence) do
    evidence
    |> then(&if(is_list(&1), do: &1, else: [&1]))
    |> case do
      [] ->
        {:error, :empty_ingress_observation}

      values ->
        case Evidence.normalize_unique(values) do
          {:error, {:duplicate_evidence, _ref}} -> {:error, :duplicate_ingress_evidence}
          result -> result
        end
    end
  end

  defp validate_observation(evidence, context, ingress_ref, observed_at) do
    case Enum.find_value(evidence, fn record ->
           observation_error(record, context, ingress_ref, observed_at)
         end) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp observation_error(record, context, ingress_ref, observed_at) do
    case SubmissionContext.validate_evidence_bindings(context, record.bindings) do
      :ok ->
        observation_record_error(record, ingress_ref, observed_at)

      {:error, reason} ->
        {:ingress_evidence_context_mismatch, record.ref, reason}
    end
  end

  defp observation_record_error(record, ingress_ref, observed_at) do
    cond do
      record.provenance != :observed ->
        {:ingress_evidence_not_observed, record.ref}

      record.source_ref != ingress_ref ->
        {:ingress_evidence_source_mismatch, record.ref}

      record.parent_refs != [] ->
        {:observed_ingress_evidence_has_parents, record.ref}

      record.observed_at > observed_at ->
        {:ingress_evidence_from_future, record.ref}

      true ->
        nil
    end
  end
end
