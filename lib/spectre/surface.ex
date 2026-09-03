defmodule Spectre.Surface do
  @moduledoc """
  Versioned declaration of the consequence classes governed by a domain.

  Classification is a lookup, not an authority decision.  Missing classes are
  reported as `:unknown_class`; callers must never turn that result into an
  executable empty row.
  """

  alias Spectre.{Candidate, Portable, Presentation, Row}
  alias Spectre.Consequence.Contract
  alias Spectre.Consequence.Validator
  alias Spectre.Fallback.Policy

  @schema_version 1
  @fields [
    :schema_version,
    :ref,
    :revision,
    :declarations,
    :consequence_contracts,
    :consequence_validators,
    :presentation_required_classes,
    :fallbacks
  ]

  @enforce_keys [
    :schema_version,
    :ref,
    :revision,
    :declarations,
    :consequence_contracts,
    :consequence_validators,
    :presentation_required_classes,
    :fallbacks
  ]
  defstruct schema_version: @schema_version,
            ref: nil,
            revision: nil,
            declarations: %{},
            consequence_contracts: %{},
            consequence_validators: %{},
            presentation_required_classes: [],
            fallbacks: %{}

  @type class :: String.t()
  @type t :: %__MODULE__{
          schema_version: 1,
          ref: String.t(),
          revision: pos_integer(),
          declarations: %{class() => Row.t()},
          consequence_contracts: %{optional(class()) => Contract.t()},
          consequence_validators: %{optional(class()) => Validator.id()},
          presentation_required_classes: [class()],
          fallbacks: %{optional(class()) => Policy.t()}
        }

  @doc "Builds and validates a governed surface."
  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = surface), do: surface |> Map.from_struct() |> new()

  def new(attrs) do
    with {:ok, attrs} <- Portable.normalize_attrs(attrs, @fields, :surface),
         attrs =
           attrs
           |> Map.put_new(:schema_version, @schema_version)
           |> Map.put_new(:declarations, %{})
           |> Map.put_new(:consequence_contracts, %{})
           |> Map.put_new(:consequence_validators, %{})
           |> Map.put_new(:presentation_required_classes, [])
           |> Map.put_new(:fallbacks, %{}),
         {:ok, declarations} <- normalize_declarations(Map.fetch!(attrs, :declarations)),
         {:ok, consequence_contracts} <-
           normalize_consequence_contracts(
             Map.fetch!(attrs, :consequence_contracts),
             declarations
           ),
         {:ok, consequence_validators} <-
           normalize_consequence_validators(
             Map.fetch!(attrs, :consequence_validators),
             declarations
           ),
         {:ok, presentation_required_classes} <-
           normalize_presentation_required_classes(
             Map.fetch!(attrs, :presentation_required_classes),
             declarations
           ),
         {:ok, fallbacks} <- normalize_fallbacks(Map.fetch!(attrs, :fallbacks), declarations),
         attrs =
           attrs
           |> Map.put(:declarations, declarations)
           |> Map.put(:consequence_contracts, consequence_contracts)
           |> Map.put(:consequence_validators, consequence_validators)
           |> Map.put(:presentation_required_classes, presentation_required_classes)
           |> Map.put(:fallbacks, fallbacks),
         {:ok, ref} <- resolve_ref(Map.get(attrs, :ref), attrs),
         surface = struct(__MODULE__, Map.put(attrs, :ref, ref)),
         :ok <- validate_record(surface),
         :ok <- Portable.validate(canonical(surface)) do
      {:ok, surface}
    end
  end

  @doc "Looks up the declared row for a class."
  @spec classify(t(), class()) :: {:ok, Row.t()} | {:error, :unknown_class}
  def classify(%__MODULE__{declarations: declarations}, class) when is_binary(class) do
    case Map.fetch(declarations, class) do
      {:ok, row} -> {:ok, row}
      :error -> {:error, :unknown_class}
    end
  end

  def classify(%__MODULE__{}, _class), do: {:error, :unknown_class}

  @doc "Validates one Candidate against the class's closed consequence contract."
  @spec validate_consequence(t(), Candidate.t()) :: :ok | {:error, term()}
  def validate_consequence(%__MODULE__{} = surface, %Candidate{} = candidate) do
    case Map.fetch(surface.consequence_contracts, candidate.class) do
      {:ok, contract} ->
        Contract.validate(
          contract,
          candidate.consequence,
          %{
            subject_refs: candidate.subject_refs,
            target_refs: candidate.target_refs,
            destination_refs: disclosure_destinations(candidate),
            meter_requests: candidate.meter_requests
          }
        )

      :error ->
        if intrinsic_consequence_class?(candidate.class),
          do: :ok,
          else: {:error, {:consequence_contract_not_declared, candidate.class}}
    end
  end

  def validate_consequence(%__MODULE__{}, _candidate),
    do: {:error, :invalid_consequence_candidate}

  @doc "Validates projection- and time-dependent facts through the active Surface table."
  @spec validate_facts(t(), Candidate.t(), map(), integer()) :: :ok | {:error, term()}
  def validate_facts(%__MODULE__{} = surface, %Candidate{} = candidate, projection, time) do
    case Map.fetch(surface.consequence_validators, candidate.class) do
      {:ok, validator} -> Validator.validate(validator, candidate, projection, time)
      :error -> {:error, {:consequence_validator_not_declared, candidate.class}}
    end
  end

  def validate_facts(%__MODULE__{}, _candidate, _projection, _time),
    do: {:error, :invalid_consequence_validator_input}

  @doc "Returns whether the declared class requires materially bound consent."
  @spec presentation_required?(t(), class()) :: boolean()
  def presentation_required?(%__MODULE__{} = surface, class) when is_binary(class),
    do: class in surface.presentation_required_classes

  def presentation_required?(%__MODULE__{}, _class), do: false

  @doc "Returns the declared refusal policy, defaulting to explicit silence."
  @spec fallback(t(), class()) :: {:ok, Policy.t()} | {:error, :unknown_class}
  def fallback(%__MODULE__{} = surface, class) when is_binary(class) do
    if Map.has_key?(surface.declarations, class) do
      case Map.fetch(surface.fallbacks, class) do
        {:ok, policy} -> {:ok, policy}
        :error -> Policy.new(:silence)
      end
    else
      {:error, :unknown_class}
    end
  end

  def fallback(%__MODULE__{}, _class), do: {:error, :unknown_class}

  @doc "Returns the plain, string-keyed ledger representation."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = surface) do
    %{
      "schema_version" => surface.schema_version,
      "ref" => surface.ref,
      "revision" => surface.revision,
      "declarations" =>
        Map.new(surface.declarations, fn {class, row} -> {class, Row.canonical(row)} end),
      "consequence_contracts" =>
        Map.new(surface.consequence_contracts, fn {class, contract} ->
          {class, Contract.canonical(contract)}
        end),
      "consequence_validators" => surface.consequence_validators,
      "presentation_required_classes" => surface.presentation_required_classes,
      "fallbacks" =>
        Map.new(surface.fallbacks, fn {class, policy} -> {class, Policy.canonical(policy)} end)
    }
  end

  @doc "Restores a surface from its canonical map."
  @spec from_canonical(map()) :: {:ok, t()} | {:error, term()}
  def from_canonical(value),
    do: Portable.restore_canonical(value, &new/1, &canonical/1, :surface)

  @doc "Returns the stable digest of the complete surface."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = surface), do: surface |> canonical() |> Portable.digest!()

  @doc "Returns the content-derived reference, independent of an assigned `ref`."
  @spec content_ref(t()) :: String.t()
  def content_ref(%__MODULE__{} = surface),
    do: Portable.content_ref!(:surface, content(surface))

  defp normalize_declarations(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {class, row}, {:ok, declarations} ->
      with :ok <- Portable.validate_non_empty_binary(class, :class),
           {:ok, row} <- Row.new(row),
           true <- Row.dimensions(row) != [],
           :ok <- validate_presentation_class(class, row) do
        {:cont, {:ok, Map.put(declarations, class, row)}}
      else
        false -> {:halt, {:error, {:empty_governed_surface_row, class}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_declarations(value),
    do: {:error, {:invalid_surface_declarations, Portable.shape(value)}}

  defp normalize_consequence_contracts(value, declarations)
       when is_map(value) and not is_struct(value) do
    with {:ok, contracts} <- normalize_contract_entries(value, declarations),
         :ok <- complete_consequence_contracts(declarations, contracts) do
      {:ok, contracts}
    end
  end

  defp normalize_consequence_contracts(value, _declarations),
    do: {:error, {:invalid_surface_consequence_contracts, Portable.shape(value)}}

  defp normalize_contract_entries(value, declarations) do
    Enum.reduce_while(value, {:ok, %{}}, fn {class, contract}, {:ok, contracts} ->
      with :ok <- Portable.validate_non_empty_binary(class, :consequence_contract_class),
           true <- Map.has_key?(declarations, class),
           {:ok, contract} <- Contract.new(contract),
           :ok <- contract_covers_row(class, Map.fetch!(declarations, class), contract) do
        {:cont, {:ok, Map.put(contracts, class, contract)}}
      else
        false -> {:halt, {:error, {:consequence_contract_for_unknown_class, class}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp complete_consequence_contracts(declarations, contracts) do
    missing =
      declarations
      |> Map.keys()
      |> Enum.reject(&intrinsic_consequence_class?/1)
      |> Enum.reject(&Map.has_key?(contracts, &1))
      |> Enum.sort()

    if missing == [],
      do: :ok,
      else: {:error, {:missing_surface_consequence_contracts, missing}}
  end

  defp normalize_consequence_validators(value, declarations)
       when is_map(value) and not is_struct(value) do
    defaults =
      Map.new(declarations, fn {class, _row} ->
        {class, Validator.default_for_class(class)}
      end)

    Enum.reduce_while(value, {:ok, defaults}, fn {class, validator}, {:ok, validators} ->
      with :ok <- Portable.validate_non_empty_binary(class, :consequence_validator_class),
           true <- Map.has_key?(declarations, class),
           :ok <- Validator.validate_id(validator) do
        {:cont, {:ok, Map.put(validators, class, validator)}}
      else
        false -> {:halt, {:error, {:consequence_validator_for_unknown_class, class}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_consequence_validators(value, _declarations),
    do: {:error, {:invalid_surface_consequence_validators, Portable.shape(value)}}

  defp contract_covers_row(class, row, contract) do
    bound = Contract.binding_kinds(contract)

    required =
      []
      |> require_binding(row.attempt or row.read or row.write or row.govern, :target)
      |> require_binding(row.disclose, :destination)
      |> require_binding(row.spend, :meter)
      |> MapSet.new()

    missing = required |> MapSet.difference(bound) |> MapSet.to_list() |> Enum.sort()

    if missing == [],
      do: :ok,
      else: {:error, {:consequence_contract_missing_row_bindings, class, missing}}
  end

  defp require_binding(bindings, true, binding), do: [binding | bindings]
  defp require_binding(bindings, false, _binding), do: bindings

  defp validate_presentation_class(class, row) do
    dimensions = Row.dimensions(row)

    cond do
      class == Presentation.show_class() and dimensions != Presentation.show_dimensions() ->
        {:error, {:invalid_presentation_show_row, dimensions}}

      class != Presentation.show_class() and row.present ->
        {:error, {:present_dimension_reserved, class}}

      true ->
        :ok
    end
  end

  defp normalize_presentation_required_classes(value, declarations) do
    with {:ok, classes} <- Portable.normalize_refs(value, :presentation_required_classes),
         nil <- Enum.find(classes, &(not Map.has_key?(declarations, &1))),
         false <- Presentation.show_class() in classes do
      {:ok, classes}
    else
      class when is_binary(class) ->
        {:error, {:presentation_required_for_unknown_surface_class, class}}

      true ->
        {:error, :presentation_show_cannot_require_approval}

      {:error, _reason} = error ->
        error
    end
  end

  defp normalize_fallbacks(value, declarations)
       when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {class, policy}, {:ok, fallbacks} ->
      with :ok <- Portable.validate_non_empty_binary(class, :fallback_class),
           true <- Map.has_key?(declarations, class),
           {:ok, policy} <- Policy.new(policy) do
        {:cont, {:ok, Map.put(fallbacks, class, policy)}}
      else
        false -> {:halt, {:error, {:fallback_for_unknown_surface_class, class}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_fallbacks(value, _declarations),
    do: {:error, {:invalid_surface_fallbacks, Portable.shape(value)}}

  defp resolve_ref(ref, attrs), do: Portable.resolve_content_ref(:surface, ref, content(attrs))

  defp content(%__MODULE__{} = surface), do: surface |> canonical() |> Map.delete("ref")

  defp content(attrs) do
    %{
      "schema_version" => Map.get(attrs, :schema_version, @schema_version),
      "revision" => Map.get(attrs, :revision),
      "declarations" =>
        Map.new(Map.get(attrs, :declarations, %{}), fn {class, row} ->
          {class, Row.canonical(row)}
        end),
      "consequence_contracts" =>
        Map.new(Map.get(attrs, :consequence_contracts, %{}), fn {class, contract} ->
          {class, Contract.canonical(contract)}
        end),
      "consequence_validators" => Map.get(attrs, :consequence_validators, %{}),
      "presentation_required_classes" => Map.get(attrs, :presentation_required_classes, []),
      "fallbacks" =>
        Map.new(Map.get(attrs, :fallbacks, %{}), fn {class, policy} ->
          {class, Policy.canonical(policy)}
        end)
    }
  end

  defp validate_record(%__MODULE__{} = surface) do
    cond do
      surface.schema_version != @schema_version ->
        {:error, {:unsupported_surface_schema_version, surface.schema_version}}

      not (is_integer(surface.revision) and surface.revision >= 0) ->
        {:error, {:invalid_surface_revision, surface.revision}}

      true ->
        Portable.validate_ref(surface.ref, :ref)
    end
  end

  defp intrinsic_consequence_class?(class) do
    class in [
      "scope.open",
      "mandate.delegate",
      "mandate.devolve",
      "mandate.restrict",
      "mandate.revoke",
      "duty.dispose",
      "surface.revise",
      "host_profile.revise",
      "definition.revise",
      "data.declassify",
      "data.erase",
      Presentation.show_class()
    ]
  end

  defp disclosure_destinations(%Candidate{disclosure: nil}), do: []

  defp disclosure_destinations(%Candidate{disclosure: disclosure}),
    do: disclosure.destination_refs
end
