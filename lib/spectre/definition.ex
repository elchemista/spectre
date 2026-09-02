defmodule Spectre.Definition do
  @moduledoc """
  Immutable, portable definition used by the governed surface.

  Definitions contain declarative data only.  They do not embed evaluator
  functions, modules or callbacks capable of granting authority.  Revisions
  form an explicit content-addressed chain and become active only through a
  governance Act recorded by the Domain.
  """

  alias Spectre.Portable

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :namespace,
    :name,
    :revision,
    :previous_ref,
    :body,
    :declared_at
  ]

  @enforce_keys [
    :schema_version,
    :ref,
    :namespace,
    :name,
    :revision,
    :body,
    :declared_at
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            namespace: nil,
            name: nil,
            revision: nil,
            previous_ref: nil,
            body: %{},
            declared_at: nil

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          namespace: String.t(),
          name: String.t(),
          revision: pos_integer(),
          previous_ref: String.t() | nil,
          body: map(),
          declared_at: integer()
        }

  @doc "Builds and validates a declarative Definition."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = definition), do: definition |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :definition),
         attrs <- Map.put_new(attrs, :schema_version, @schema_version),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         definition = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(definition),
         :ok <- Portable.validate(canonical(definition)) do
      {:ok, definition}
    end
  end

  @doc "Returns the stable logical key shared by all revisions."
  @spec key(t()) :: {String.t(), String.t()}
  def key(%__MODULE__{} = definition), do: {definition.namespace, definition.name}

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = definition) do
    %{
      "schema_version" => definition.schema_version,
      "ref" => definition.ref,
      "namespace" => definition.namespace,
      "name" => definition.name,
      "revision" => definition.revision,
      "previous_ref" => definition.previous_ref,
      "body" => definition.body,
      "declared_at" => definition.declared_at
    }
  end

  @doc "Restores a Definition and verifies its content reference."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value), do: new(value)

  @doc "Returns the stable digest of the complete Definition."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = definition), do: definition |> canonical() |> Portable.digest!()

  @doc "Returns the reference derived from immutable Definition content."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = definition),
    do: Portable.content_ref!(:definition, content(definition))

  defp resolve_ref(ref, attrs),
    do: Portable.resolve_content_ref(:definition, ref, content(attrs))

  defp content(%__MODULE__{} = definition),
    do: definition |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    %{
      "schema_version" => Map.get(attrs, :schema_version, @schema_version),
      "namespace" => Map.get(attrs, :namespace),
      "name" => Map.get(attrs, :name),
      "revision" => Map.get(attrs, :revision),
      "previous_ref" => Map.get(attrs, :previous_ref),
      "body" => Map.get(attrs, :body, %{}),
      "declared_at" => Map.get(attrs, :declared_at)
    }
  end

  defp validate_record(%__MODULE__{} = definition) do
    cond do
      definition.schema_version != @schema_version ->
        {:error, {:unsupported_definition_schema_version, definition.schema_version}}

      not (is_integer(definition.revision) and definition.revision > 0) ->
        {:error, {:invalid_definition_revision, definition.revision}}

      definition.revision == 1 and not is_nil(definition.previous_ref) ->
        {:error, :initial_definition_has_previous_ref}

      definition.revision > 1 and is_nil(definition.previous_ref) ->
        {:error, :revised_definition_missing_previous_ref}

      not is_map(definition.body) or is_struct(definition.body) ->
        {:error, {:invalid_definition_body, Portable.shape(definition.body)}}

      not is_integer(definition.declared_at) ->
        {:error, {:invalid_definition_declared_at, definition.declared_at}}

      true ->
        with :ok <- Portable.validate_ref(definition.ref, :ref),
             :ok <- Portable.validate_non_empty_binary(definition.namespace, :namespace),
             :ok <- Portable.validate_non_empty_binary(definition.name, :name),
             :ok <- validate_optional_ref(definition.previous_ref, :previous_ref) do
          :ok
        end
    end
  end

  defp validate_optional_ref(nil, _field), do: :ok
  defp validate_optional_ref(value, field), do: Portable.validate_ref(value, field)
end
