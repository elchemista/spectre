defmodule Spectre.Duty.Disposition do
  @moduledoc false

  require Spectre.Portable

  alias Spectre.{Duty, Portable}

  @schema_version 1
  @kinds [:condition_met, :ratify, :repudiate, :compensate, :assign, :accept_loss]
  @discretionary_kinds @kinds -- [:condition_met]
  @meter_resolutions [:none, :settle, :release]
  @fields [
    :schema_version,
    :kind,
    :duty_ref,
    :opening_digest,
    :cause_key,
    :supporting_refs,
    :meter_resolution
  ]

  @enforce_keys @fields
  defstruct @fields

  @type kind ::
          :condition_met
          | :ratify
          | :repudiate
          | :compensate
          | :assign
          | :accept_loss

  @type meter_resolution :: :none | :settle | :release

  @type t :: %__MODULE__{
          schema_version: 1,
          kind: kind(),
          duty_ref: String.t(),
          opening_digest: String.t(),
          cause_key: term(),
          supporting_refs: [String.t()],
          meter_resolution: meter_resolution()
        }

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = disposition), do: disposition |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :duty_disposition),
         attrs = Map.put_new(attrs, :schema_version, @schema_version),
         {:ok, supporting_refs} <-
           Portable.normalize_refs(Map.get(attrs, :supporting_refs, []), :supporting_refs),
         disposition = struct(__MODULE__, Map.put(attrs, :supporting_refs, supporting_refs)),
         :ok <- validate(disposition),
         :ok <- Portable.validate(canonical(disposition)) do
      {:ok, disposition}
    end
  end

  @doc "Builds a disposition bound to the exact current opening of an open Duty."
  @spec for_duty(Duty.t(), kind(), [String.t()], meter_resolution()) ::
          {:ok, t()} | {:error, term()}
  def for_duty(duty, kind, supporting_refs, meter_resolution \\ :none)

  def for_duty(%Duty{} = duty, kind, supporting_refs, meter_resolution)
      when is_list(supporting_refs) do
    with {:ok, duty} <- Duty.new(duty),
         :ok <- open_duty(duty) do
      new(%{
        kind: kind,
        duty_ref: duty.ref,
        opening_digest: Duty.digest(duty),
        cause_key: duty.cause_key,
        supporting_refs: supporting_refs,
        meter_resolution: meter_resolution
      })
    end
  end

  def for_duty(_duty, _kind, _supporting_refs, _meter_resolution),
    do: {:error, :invalid_duty_disposition_source}

  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :duty_disposition)

  @spec from_consequence(term()) :: {:ok, t()} | {:error, term()}
  def from_consequence(%{"duty_disposition" => value} = consequence)
      when map_size(consequence) == 1 and Portable.is_plain_map(value) do
    with {:ok, disposition} <- from_canonical(value),
         true <- value == canonical(disposition) do
      {:ok, disposition}
    else
      false -> {:error, :noncanonical_duty_disposition}
      {:error, _reason} = error -> error
    end
  end

  def from_consequence(_consequence), do: {:error, :invalid_duty_disposition_consequence}

  @spec consequence(t()) :: map()
  def consequence(%__MODULE__{} = disposition),
    do: %{"duty_disposition" => canonical(disposition)}

  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = disposition) do
    Portable.canonical_fields(disposition, @fields)
  end

  @spec discretionary?(t()) :: boolean()
  def discretionary?(%__MODULE__{kind: kind}), do: kind in @discretionary_kinds

  defp open_duty(%Duty{status: :open, disposition_act_ref: nil}), do: :ok
  defp open_duty(%Duty{ref: ref}), do: {:error, {:duty_not_open, ref}}

  defp validate(%__MODULE__{} = disposition) do
    cond do
      disposition.schema_version != @schema_version ->
        {:error, {:unsupported_duty_disposition_schema_version, disposition.schema_version}}

      disposition.kind not in @kinds ->
        {:error, {:invalid_duty_disposition_kind, disposition.kind}}

      disposition.supporting_refs == [] ->
        {:error, :duty_disposition_supporting_refs_required}

      disposition.meter_resolution not in @meter_resolutions ->
        {:error, {:invalid_duty_meter_resolution, disposition.meter_resolution}}

      true ->
        with :ok <- Portable.validate_ref(disposition.duty_ref, :duty_ref),
             :ok <- validate_digest(disposition.opening_digest),
             :ok <- validate_cause_key(disposition.cause_key) do
          Portable.validate_refs(disposition.supporting_refs, :supporting_refs)
        end
    end
  end

  defp validate_cause_key(nil), do: {:error, :missing_duty_disposition_cause_key}
  defp validate_cause_key(value), do: Portable.validate(value)

  defp validate_digest(value) do
    if Portable.sha256_digest?(value),
      do: :ok,
      else: {:error, {:invalid_duty_opening_digest, value}}
  end
end
