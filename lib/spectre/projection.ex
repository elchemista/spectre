defmodule Spectre.Projection do
  @moduledoc """
  Deterministic projection interface for canonical Definitions.

  Projection identity binds the Definition Ref, generator ID/version, optional
  evidence digest, and generated content. A generator change is therefore
  observable even when two generator implementations emit equal content.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Definition.Ref
  alias Spectre.Projection.Audit

  @callback id() :: String.t()
  @callback version() :: pos_integer()
  @callback project(Canonical.t(), keyword()) :: {:ok, term()} | {:error, term()}

  @enforce_keys [
    :definition_ref,
    :digest,
    :generator_id,
    :generator_version,
    :content
  ]
  defstruct [
    :definition_ref,
    :digest,
    :generator_id,
    :generator_version,
    :input_evidence_digest,
    :content
  ]

  @type t :: %__MODULE__{
          definition_ref: Ref.t(),
          digest: String.t(),
          generator_id: String.t(),
          generator_version: pos_integer(),
          input_evidence_digest: String.t() | nil,
          content: term()
        }

  @doc "Generates the exact Audit projection."
  @spec generate(Canonical.t()) :: {:ok, t()} | {:error, term()}
  def generate(%Canonical{} = canonical), do: generate(canonical, Audit, [])

  @doc "Generates a projection with the supplied deterministic generator."
  @spec generate(Canonical.t(), module()) :: {:ok, t()} | {:error, term()}
  def generate(%Canonical{} = canonical, generator), do: generate(canonical, generator, [])

  @doc "Generates a projection with explicit generator options."
  @spec generate(Canonical.t(), module(), keyword()) :: {:ok, t()} | {:error, term()}
  def generate(%Canonical{} = canonical, generator, opts)
      when is_atom(generator) and is_list(opts) do
    with :ok <- validate_generator(generator),
         {:ok, generator_id} <- generator_id(generator),
         {:ok, generator_version} <- generator_version(generator),
         {:ok, content} <- generator.project(canonical, opts),
         :ok <- validate_content(content),
         {:ok, evidence_digest} <- evidence_digest(Keyword.get(opts, :evidence)) do
      definition_ref = Canonical.ref(canonical)

      digest =
        projection_digest(
          definition_ref,
          generator_id,
          generator_version,
          evidence_digest,
          content
        )

      {:ok,
       %__MODULE__{
         definition_ref: definition_ref,
         digest: digest,
         generator_id: generator_id,
         generator_version: generator_version,
         input_evidence_digest: evidence_digest,
         content: content
       }}
    end
  end

  def generate(_canonical, generator, _opts),
    do: {:error, {:invalid_projection_generator, generator}}

  @doc "Verifies the digest and Definition binding of an existing projection."
  @spec verify(t(), Canonical.t()) :: :ok | {:error, term()}
  def verify(%__MODULE__{} = projection, %Canonical{} = canonical) do
    verify_ref(projection, Canonical.ref(canonical))
  end

  @doc false
  @spec verify_ref(t(), Ref.t()) :: :ok | {:error, term()}
  def verify_ref(%__MODULE__{} = projection, %Ref{} = definition_ref) do
    with true <- Ref.valid?(definition_ref),
         :ok <- validate_projection_shape(projection),
         :ok <- validate_content(projection.content) do
      expected =
        projection_digest(
          definition_ref,
          projection.generator_id,
          projection.generator_version,
          projection.input_evidence_digest,
          projection.content
        )

      cond do
        projection.definition_ref != definition_ref ->
          {:error, :projection_definition_mismatch}

        projection.digest != expected ->
          {:error, :projection_digest_mismatch}

        true ->
          :ok
      end
    else
      false -> {:error, :invalid_projection_definition_ref}
      {:error, _reason} = error -> error
    end
  end

  def verify_ref(projection, definition_ref),
    do: {:error, {:invalid_projection, shape(projection), shape(definition_ref)}}

  @spec validate_projection_shape(t()) :: :ok | {:error, term()}
  defp validate_projection_shape(projection) do
    cond do
      not is_binary(projection.generator_id) or projection.generator_id == "" ->
        {:error, :invalid_projection_generator_id}

      not is_integer(projection.generator_version) or projection.generator_version <= 0 ->
        {:error, :invalid_projection_generator_version}

      not is_nil(projection.input_evidence_digest) and
          not valid_digest?(projection.input_evidence_digest) ->
        {:error, :invalid_projection_input_evidence_digest}

      not valid_digest?(projection.digest) ->
        {:error, :invalid_projection_digest}

      true ->
        :ok
    end
  end

  @spec valid_digest?(term()) :: boolean()
  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64,
    do: match?({:ok, _bytes}, Base.decode16(digest, case: :lower))

  defp valid_digest?(_digest), do: false

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_atom(value), do: :atom
  defp shape(_value), do: :other

  @spec validate_generator(module()) :: :ok | {:error, term()}
  defp validate_generator(generator) do
    if Code.ensure_loaded?(generator) and function_exported?(generator, :id, 0) and
         function_exported?(generator, :version, 0) and
         function_exported?(generator, :project, 2) do
      :ok
    else
      {:error, {:invalid_projection_generator, generator}}
    end
  end

  @spec generator_id(module()) :: {:ok, String.t()} | {:error, term()}
  defp generator_id(generator) do
    case generator.id() do
      id when is_binary(id) and id != "" -> {:ok, id}
      id -> {:error, {:invalid_projection_generator_id, generator, id}}
    end
  end

  @spec generator_version(module()) :: {:ok, pos_integer()} | {:error, term()}
  defp generator_version(generator) do
    case generator.version() do
      version when is_integer(version) and version > 0 -> {:ok, version}
      version -> {:error, {:invalid_projection_generator_version, generator, version}}
    end
  end

  @spec validate_content(term()) :: :ok | {:error, term()}
  defp validate_content(content) do
    case Value.validate(content) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_projection, reason}}
    end
  end

  @spec evidence_digest(term()) :: {:ok, String.t() | nil} | {:error, term()}
  defp evidence_digest(nil), do: {:ok, nil}
  defp evidence_digest(evidence), do: Value.digest(evidence)

  @spec projection_digest(Ref.t(), String.t(), pos_integer(), String.t() | nil, term()) ::
          String.t()
  defp projection_digest(
         definition_ref,
         generator_id,
         generator_version,
         evidence_digest,
         content
       ) do
    Value.digest!(%{
      definition_ref: Ref.to_string(definition_ref),
      generator_id: generator_id,
      generator_version: generator_version,
      input_evidence_digest: evidence_digest,
      content: content
    })
  end
end
