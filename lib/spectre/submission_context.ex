defmodule Spectre.SubmissionContext do
  @moduledoc """
  Authenticated ingress context supplied separately from a candidate.

  Only the ingress adapter declared by the running Domain may produce a trusted
  context. The Sequencer authenticates through that adapter and adds a
  generation-bound, process-local seal. Scope opening, resumption and Candidate
  submission verify the seal as well as the fixed `ingress_ref`; merely building
  this public data structure does not cross the ingress boundary.

  The seal is deliberately excluded from the canonical representation. It is a
  live fencing mechanism, not durable Evidence or part of the Domain history.
  The context identifies the authenticated principal and host generation
  without carrying reusable source credentials. Authentication narrows mandate
  eligibility; it never creates authority.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Portable

  @schema_version 1
  @canonical_fields [
    :schema_version,
    :ref,
    :domain_ref,
    :scope_ref,
    :authenticated_principal_ref,
    :authentication_ref,
    :ingress_ref,
    :channel_ref,
    :session_ref,
    :host_generation
  ]
  @evidence_binding_fields [
    :submission_context_ref,
    :domain_ref,
    :scope_ref,
    :authenticated_principal_ref,
    :authentication_ref,
    :ingress_ref,
    :channel_ref,
    :session_ref,
    :host_generation
  ]
  @evidence_binding_keys Enum.map(@evidence_binding_fields, &Atom.to_string/1)
  @fields @canonical_fields ++ [:seal]
  @minimum_secret_bytes 32
  @seal_domain "spectre:submission-context:v1\0"

  @enforce_keys [
    :schema_version,
    :ref,
    :domain_ref,
    :scope_ref,
    :authenticated_principal_ref,
    :authentication_ref,
    :ingress_ref,
    :host_generation
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            domain_ref: nil,
            scope_ref: nil,
            authenticated_principal_ref: nil,
            authentication_ref: nil,
            ingress_ref: nil,
            channel_ref: nil,
            session_ref: nil,
            host_generation: nil,
            seal: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          domain_ref: String.t(),
          scope_ref: String.t(),
          authenticated_principal_ref: String.t(),
          authentication_ref: String.t(),
          ingress_ref: String.t(),
          channel_ref: String.t() | nil,
          session_ref: String.t() | nil,
          host_generation: non_neg_integer(),
          seal: String.t() | nil
        }

  @doc "Builds and validates an authenticated submission context."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = context), do: context |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :submission_context),
         attrs =
           attrs
           |> Map.put_new(:schema_version, @schema_version)
           |> Map.put_new(:seal, nil),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         context = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(context),
         :ok <- Portable.validate(canonical(context)) do
      {:ok, context}
    end
  end

  @doc "Returns the plain, string-keyed representation suitable for a decision record."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = context) do
    %{
      "schema_version" => context.schema_version,
      "ref" => context.ref,
      "domain_ref" => context.domain_ref,
      "scope_ref" => context.scope_ref,
      "authenticated_principal_ref" => context.authenticated_principal_ref,
      "authentication_ref" => context.authentication_ref,
      "ingress_ref" => context.ingress_ref,
      "channel_ref" => context.channel_ref,
      "session_ref" => context.session_ref,
      "host_generation" => context.host_generation
    }
  end

  @doc "Restores a context from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :submission_context)

  @doc "Returns the stable digest of the complete context."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = context), do: context |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = context),
    do: Portable.content_ref!(:submission_context, content(context))

  @doc "Returns the exact trusted context fields embedded in scoped Evidence."
  @spec evidence_bindings(t()) :: map()
  def evidence_bindings(%__MODULE__{} = context) do
    %{
      "submission_context_ref" => context.ref,
      "domain_ref" => context.domain_ref,
      "scope_ref" => context.scope_ref,
      "authenticated_principal_ref" => context.authenticated_principal_ref,
      "authentication_ref" => context.authentication_ref,
      "ingress_ref" => context.ingress_ref,
      "channel_ref" => context.channel_ref,
      "session_ref" => context.session_ref,
      "host_generation" => context.host_generation
    }
  end

  @doc "Adds application bindings without permitting trusted context fields to be supplied."
  @spec merge_evidence_bindings(t(), map()) :: {:ok, map()} | {:error, term()}
  def merge_evidence_bindings(context, additional \\ %{})

  def merge_evidence_bindings(%__MODULE__{} = context, additional) do
    with {:ok, context} <- new(context),
         :ok <- validate_additional_evidence_bindings(additional) do
      {:ok, Map.merge(additional, evidence_bindings(context))}
    end
  end

  def merge_evidence_bindings(_context, _additional),
    do: {:error, :invalid_evidence_submission_context}

  @doc "Restores and verifies a context from the trusted portion of Evidence bindings."
  @spec from_evidence_bindings(map()) :: {:ok, t()} | {:error, term()}
  def from_evidence_bindings(bindings) when is_map(bindings) and not is_struct(bindings) do
    with :ok <- canonical_evidence_binding_keys(bindings),
         {:ok, ref} <- Map.fetch(bindings, "submission_context_ref"),
         {:ok, domain_ref} <- Map.fetch(bindings, "domain_ref"),
         {:ok, scope_ref} <- Map.fetch(bindings, "scope_ref"),
         {:ok, principal_ref} <- Map.fetch(bindings, "authenticated_principal_ref"),
         {:ok, authentication_ref} <- Map.fetch(bindings, "authentication_ref"),
         {:ok, ingress_ref} <- Map.fetch(bindings, "ingress_ref"),
         {:ok, channel_ref} <- Map.fetch(bindings, "channel_ref"),
         {:ok, session_ref} <- Map.fetch(bindings, "session_ref"),
         {:ok, host_generation} <- Map.fetch(bindings, "host_generation") do
      new(%{
        ref: ref,
        domain_ref: domain_ref,
        scope_ref: scope_ref,
        authenticated_principal_ref: principal_ref,
        authentication_ref: authentication_ref,
        ingress_ref: ingress_ref,
        channel_ref: channel_ref,
        session_ref: session_ref,
        host_generation: host_generation
      })
    else
      :error -> {:error, :incomplete_evidence_submission_context}
      {:error, _reason} = error -> error
    end
  end

  def from_evidence_bindings(_bindings),
    do: {:error, :invalid_evidence_submission_context}

  @doc "Returns the complete scoped context in Evidence bindings, or `nil` when unscoped."
  @spec extract_evidence_context(map()) :: {:ok, t() | nil} | {:error, term()}
  def extract_evidence_context(bindings) when is_map(bindings) and not is_struct(bindings) do
    if Enum.any?(@evidence_binding_fields, &evidence_binding_present?(bindings, &1)) do
      from_evidence_bindings(bindings)
    else
      {:ok, nil}
    end
  end

  def extract_evidence_context(_bindings),
    do: {:error, :invalid_evidence_submission_context}

  @doc "Checks that scoped Evidence carries exactly this trusted context."
  @spec validate_evidence_bindings(t(), map()) :: :ok | {:error, term()}
  def validate_evidence_bindings(%__MODULE__{} = expected, bindings) do
    with {:ok, expected} <- new(expected),
         {:ok, actual} <- from_evidence_bindings(bindings),
         true <- canonical(actual) == canonical(expected) do
      :ok
    else
      false -> {:error, :evidence_submission_context_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def validate_evidence_bindings(_expected, _bindings),
    do: {:error, :invalid_evidence_submission_context}

  @doc false
  @spec seal(t(), binary()) :: {:ok, t()} | {:error, term()}
  def seal(%__MODULE__{} = context, secret)
      when is_binary(secret) and byte_size(secret) >= @minimum_secret_bytes do
    with {:ok, context} <- new(%{context | seal: nil}),
         {:ok, encoded} <- Value.encode(canonical(context)) do
      seal =
        :crypto.mac(:hmac, :sha256, secret, @seal_domain <> encoded)
        |> Base.url_encode64(padding: false)

      {:ok, %{context | seal: seal}}
    end
  end

  def seal(_context, _secret), do: {:error, :invalid_submission_context_seal_material}

  @doc false
  @spec verify_seal(t(), binary()) :: :ok | {:error, term()}
  def verify_seal(%__MODULE__{seal: supplied} = context, secret)
      when is_binary(supplied) and supplied != "" and is_binary(secret) and
             byte_size(secret) >= @minimum_secret_bytes do
    with {:ok, supplied} <- Base.url_decode64(supplied, padding: false),
         {:ok, encoded} <- Value.encode(canonical(context)) do
      expected = :crypto.mac(:hmac, :sha256, secret, @seal_domain <> encoded)

      if byte_size(supplied) == byte_size(expected) and :crypto.hash_equals(supplied, expected),
        do: :ok,
        else: {:error, :submission_context_authentication_failed}
    else
      :error -> {:error, :submission_context_authentication_failed}
      {:error, _reason} -> {:error, :submission_context_authentication_failed}
    end
  end

  def verify_seal(_context, _secret),
    do: {:error, :submission_context_authentication_failed}

  defp resolve_ref(ref, attrs),
    do: Portable.resolve_content_ref(:submission_context, ref, content(attrs))

  defp content(%__MODULE__{} = context), do: context |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    @canonical_fields
    |> Enum.reject(&(&1 == :ref))
    |> Map.new(fn field -> {Atom.to_string(field), Map.get(attrs, field)} end)
    |> Map.put("schema_version", Map.get(attrs, :schema_version, @schema_version))
  end

  defp validate_record(%__MODULE__{} = context) do
    cond do
      context.schema_version != @schema_version ->
        {:error, {:unsupported_submission_context_schema_version, context.schema_version}}

      not (is_integer(context.host_generation) and context.host_generation >= 0) ->
        {:error, {:invalid_host_generation, context.host_generation}}

      not is_nil(context.seal) and (not is_binary(context.seal) or context.seal == "") ->
        {:error, {:invalid_submission_context_seal, Portable.shape(context.seal)}}

      true ->
        with :ok <- Portable.validate_ref(context.ref, :ref),
             :ok <- Portable.validate_ref(context.domain_ref, :domain_ref),
             :ok <- Portable.validate_ref(context.scope_ref, :scope_ref),
             :ok <-
               Portable.validate_ref(
                 context.authenticated_principal_ref,
                 :authenticated_principal_ref
               ),
             :ok <- Portable.validate_ref(context.authentication_ref, :authentication_ref),
             :ok <- Portable.validate_ref(context.ingress_ref, :ingress_ref),
             :ok <- validate_optional_ref(context.channel_ref, :channel_ref),
             :ok <- validate_optional_ref(context.session_ref, :session_ref) do
          :ok
        end
    end
  end

  defp validate_optional_ref(nil, _field), do: :ok
  defp validate_optional_ref(value, field), do: Portable.validate_ref(value, field)

  defp validate_additional_evidence_bindings(bindings)
       when is_map(bindings) and not is_struct(bindings) do
    collision =
      Enum.find(@evidence_binding_fields, fn field ->
        Map.has_key?(bindings, field) or Map.has_key?(bindings, Atom.to_string(field))
      end)

    cond do
      not is_nil(collision) ->
        {:error, {:reserved_evidence_binding, collision}}

      true ->
        Portable.validate(bindings)
    end
  end

  defp validate_additional_evidence_bindings(_bindings),
    do: {:error, :invalid_additional_evidence_bindings}

  defp evidence_binding_present?(bindings, field) do
    Map.has_key?(bindings, field) or Map.has_key?(bindings, Atom.to_string(field))
  end

  defp canonical_evidence_binding_keys(bindings) do
    case Enum.find(@evidence_binding_fields, &Map.has_key?(bindings, &1)) do
      nil ->
        case Enum.find(@evidence_binding_keys, &(not Map.has_key?(bindings, &1))) do
          nil -> :ok
          missing -> {:error, {:missing_evidence_context_binding, missing}}
        end

      atom_key ->
        {:error, {:noncanonical_evidence_context_binding, atom_key}}
    end
  end
end
