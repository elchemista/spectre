defmodule Spectre.Attempt do
  @moduledoc """
  Durable proof that an exact-bound grant was consumed before capability release.

  Only a digest of the grant nonce is persisted.  The bearer grant, raw nonce,
  credentials and handles are deliberately absent from this portable record.
  `generation` is the host generation which minted and consumed that Grant. It
  can differ from the admission generation frozen in the Act when an admitted,
  still-unattempted Act is safely resumed after a host restart.
  """

  require Spectre.Portable

  alias Spectre.{Id, Portable}

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :act_ref,
    :executor_ref,
    :material_digest,
    :generation,
    :grant_nonce_digest,
    :started_at
  ]

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          act_ref: String.t(),
          executor_ref: String.t(),
          material_digest: String.t(),
          generation: non_neg_integer(),
          grant_nonce_digest: String.t(),
          started_at: integer()
        }

  @doc "Builds and validates an attempt record."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = attempt), do: attempt |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :attempt),
         attrs = Map.put_new(attrs, :schema_version, @schema_version),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         attempt = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(attempt),
         :ok <- Portable.validate(canonical(attempt)) do
      {:ok, attempt}
    end
  end

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = attempt) do
    Portable.canonical_fields(attempt, @fields)
  end

  @doc "Restores an attempt from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :attempt)

  @doc "Returns the stable digest of the complete attempt."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = attempt), do: attempt |> canonical() |> Portable.digest!()

  defp resolve_ref(ref, _attrs) do
    if Id.valid?(ref), do: {:ok, ref}, else: {:error, {:invalid_attempt_ref, ref}}
  end

  defp validate_record(%__MODULE__{} = attempt) do
    cond do
      attempt.schema_version != @schema_version ->
        {:error, {:unsupported_attempt_schema_version, attempt.schema_version}}

      not Portable.is_non_negative_integer(attempt.generation) ->
        {:error, {:invalid_attempt_generation, attempt.generation}}

      not is_integer(attempt.started_at) ->
        {:error, {:invalid_attempt_started_at, attempt.started_at}}

      true ->
        with :ok <- Portable.validate_ref(attempt.ref, :ref),
             :ok <- Portable.validate_ref(attempt.act_ref, :act_ref),
             :ok <- Portable.validate_ref(attempt.executor_ref, :executor_ref),
             :ok <- Portable.validate_non_empty_binary(attempt.material_digest, :material_digest) do
          Portable.validate_non_empty_binary(attempt.grant_nonce_digest, :grant_nonce_digest)
        end
    end
  end
end
