defmodule Spectre.Erasure do
  @moduledoc """
  Immutable request and causal tombstone for deletion outside the ledger.

  The record does not claim that bytes disappeared merely because deletion was
  authorized.  Its source Act records the request; a later definitive Outcome
  is the evidence that an executor completed it.  Ledger digests and this
  causal description remain even when the referenced payload is gone.
  """

  alias Spectre.Portable

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :source_act_ref,
    :target_ref,
    :target_digest,
    :scope_ref,
    :affected_refs,
    :reason,
    :reduces_verifiability,
    :requested_at
  ]

  @draft_fields [
    :schema_version,
    :target_ref,
    :target_digest,
    :scope_ref,
    :affected_refs,
    :reason,
    :reduces_verifiability,
    :requested_at
  ]

  @enforce_keys [
    :schema_version,
    :ref,
    :source_act_ref,
    :target_ref,
    :target_digest,
    :affected_refs,
    :reason,
    :reduces_verifiability,
    :requested_at
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            source_act_ref: nil,
            target_ref: nil,
            target_digest: nil,
            scope_ref: nil,
            affected_refs: [],
            reason: nil,
            reduces_verifiability: false,
            requested_at: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          source_act_ref: String.t(),
          target_ref: String.t(),
          target_digest: String.t(),
          scope_ref: String.t() | nil,
          affected_refs: [String.t()],
          reason: String.t(),
          reduces_verifiability: boolean(),
          requested_at: integer()
        }

  @doc "Builds and validates an erasure request tied to its authorizing Act."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = erasure), do: erasure |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :erasure),
         attrs <- defaults(attrs),
         {:ok, affected_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :affected_refs), :affected_refs),
         attrs = Map.put(attrs, :affected_refs, affected_refs),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         erasure = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(erasure),
         :ok <- Portable.validate(canonical(erasure)) do
      {:ok, erasure}
    end
  end

  @doc "Returns the exact pre-Act material carried by a `data.erase` Candidate."
  @spec request_draft(map() | keyword() | t()) :: {:ok, map()} | {:error, term()}
  def request_draft(%__MODULE__{} = erasure),
    do: {:ok, canonical_draft(erasure)}

  def request_draft(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @draft_fields, :erasure_request),
         attrs <- defaults(attrs),
         {:ok, affected_refs} <-
           Portable.normalize_refs(Map.fetch!(attrs, :affected_refs), :affected_refs),
         draft = draft_content(Map.put(attrs, :affected_refs, affected_refs)),
         :ok <- validate_draft(draft),
         :ok <- Portable.validate(draft) do
      {:ok, draft}
    end
  end

  @doc "Materializes an immutable erasure record after the authorizing Act exists."
  @spec from_request_draft(map(), String.t()) :: {:ok, t()} | {:error, term()}
  def from_request_draft(draft, source_act_ref)
      when is_map(draft) and not is_struct(draft) and is_binary(source_act_ref) and
             source_act_ref != "" do
    with {:ok, normalized} <- request_draft(draft) do
      normalized
      |> Map.put("source_act_ref", source_act_ref)
      |> new()
    end
  end

  def from_request_draft(_draft, _source_act_ref),
    do: {:error, :invalid_erasure_request_draft}

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = erasure) do
    canonical_draft(erasure)
    |> Map.put("ref", erasure.ref)
    |> Map.put("source_act_ref", erasure.source_act_ref)
  end

  @doc "Restores an erasure record and verifies its content reference."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :erasure)

  @doc "Returns the stable digest of the complete erasure record."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = erasure), do: erasure |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference of an erasure record."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = erasure),
    do: Portable.content_ref!(:erasure, content(erasure))

  defp defaults(attrs) do
    attrs
    |> Map.put_new(:schema_version, @schema_version)
    |> Map.put_new(:scope_ref, nil)
    |> Map.put_new(:affected_refs, [])
    |> Map.put_new(:reduces_verifiability, false)
  end

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:erasure, ref, content(attrs))

  defp content(%__MODULE__{} = erasure), do: erasure |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    attrs
    |> draft_content()
    |> Map.put("source_act_ref", Map.get(attrs, :source_act_ref))
  end

  defp canonical_draft(%__MODULE__{} = erasure) do
    %{
      "schema_version" => erasure.schema_version,
      "target_ref" => erasure.target_ref,
      "target_digest" => erasure.target_digest,
      "scope_ref" => erasure.scope_ref,
      "affected_refs" => erasure.affected_refs,
      "reason" => erasure.reason,
      "reduces_verifiability" => erasure.reduces_verifiability,
      "requested_at" => erasure.requested_at
    }
  end

  defp draft_content(attrs) do
    %{
      "schema_version" => Map.get(attrs, :schema_version, @schema_version),
      "target_ref" => Map.get(attrs, :target_ref),
      "target_digest" => Map.get(attrs, :target_digest),
      "scope_ref" => Map.get(attrs, :scope_ref),
      "affected_refs" => Map.get(attrs, :affected_refs, []),
      "reason" => Map.get(attrs, :reason),
      "reduces_verifiability" => Map.get(attrs, :reduces_verifiability, false),
      "requested_at" => Map.get(attrs, :requested_at)
    }
  end

  defp validate_draft(draft) do
    with {:ok, erasure} <-
           draft
           |> Map.put("source_act_ref", "erasure-draft-source")
           |> new() do
      if canonical_draft(erasure) == draft,
        do: :ok,
        else: {:error, :noncanonical_erasure_request_draft}
    end
  end

  defp validate_record(%__MODULE__{} = erasure) do
    cond do
      erasure.schema_version != @schema_version ->
        {:error, {:unsupported_erasure_schema_version, erasure.schema_version}}

      not sha256?(erasure.target_digest) ->
        {:error, {:invalid_erasure_target_digest, erasure.target_digest}}

      not target_digest_matches?(erasure.target_ref, erasure.target_digest) ->
        {:error, {:erasure_target_digest_mismatch, erasure.target_ref, erasure.target_digest}}

      not is_binary(erasure.reason) or erasure.reason == "" ->
        {:error, {:invalid_erasure_reason, erasure.reason}}

      not is_boolean(erasure.reduces_verifiability) ->
        {:error, {:invalid_erasure_verifiability_flag, erasure.reduces_verifiability}}

      not is_integer(erasure.requested_at) ->
        {:error, {:invalid_erasure_requested_at, erasure.requested_at}}

      true ->
        with :ok <- Portable.validate_ref(erasure.ref, :ref),
             :ok <- Portable.validate_ref(erasure.source_act_ref, :source_act_ref),
             :ok <- Portable.validate_ref(erasure.target_ref, :target_ref),
             :ok <- Portable.validate_optional_ref(erasure.scope_ref, :scope_ref),
             :ok <- Portable.validate_refs(erasure.affected_refs, :affected_refs) do
          :ok
        end
    end
  end

  defp sha256?(value) when is_binary(value), do: String.match?(value, ~r/\A[0-9a-f]{64}\z/)
  defp sha256?(_value), do: false

  defp target_digest_matches?("payload:" <> digest, digest), do: sha256?(digest)
  defp target_digest_matches?(_target_ref, _digest), do: false
end
