defmodule Spectre.Prompt.Receipt do
  @moduledoc """
  Privacy-safe evidence for one effective governed prompt fragment.

  A receipt binds the exact Definition, source fragment, resolved input
  evidence and rendered bytes without exposing prompt or input content.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Ref
  alias Spectre.Prompt.Fragment

  @schema_version 1
  @generator_id "spectre.prompt.materializer"
  @generator_version 1
  @placement_fields [
    :scope,
    :target,
    :position,
    :trust,
    :visibility,
    :granted_priority,
    :budget_class,
    :token_cap
  ]

  @enforce_keys [
    :definition_ref,
    :prompt_ref,
    :fragment_digest,
    :rendered_digest,
    :input_evidence_digest,
    :generator_id,
    :generator_version,
    :bytes,
    :estimated_tokens,
    :placement,
    :provenance_digest,
    :digest
  ]
  defstruct schema_version: @schema_version,
            definition_ref: nil,
            prompt_ref: nil,
            fragment_digest: nil,
            rendered_digest: nil,
            input_evidence_digest: nil,
            generator_id: @generator_id,
            generator_version: @generator_version,
            bytes: 0,
            estimated_tokens: 0,
            placement: %{},
            provenance_digest: nil,
            digest: nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          definition_ref: String.t(),
          prompt_ref: term(),
          fragment_digest: String.t(),
          rendered_digest: String.t(),
          input_evidence_digest: String.t(),
          generator_id: String.t(),
          generator_version: pos_integer(),
          bytes: non_neg_integer(),
          estimated_tokens: non_neg_integer(),
          placement: map(),
          provenance_digest: String.t(),
          digest: String.t()
        }

  @doc false
  @spec new(Fragment.t(), String.t(), String.t(), term()) :: {:ok, t()} | {:error, term()}
  def new(%Fragment{} = fragment, rendered, definition_ref, evidence)
      when is_binary(rendered) and is_binary(definition_ref) and definition_ref != "" do
    with {:ok, evidence_digest} <- Value.digest(evidence),
         {:ok, provenance_digest} <- Value.digest(fragment.provenance) do
      data = %{
        schema_version: @schema_version,
        definition_ref: definition_ref,
        prompt_ref: stable_ref(fragment.id),
        fragment_digest: fragment.digest,
        rendered_digest: Value.digest!(rendered),
        input_evidence_digest: evidence_digest,
        generator_id: @generator_id,
        generator_version: @generator_version,
        bytes: byte_size(rendered),
        estimated_tokens: estimated_tokens(rendered),
        placement: %{
          scope: stable_ref(fragment.scope),
          target: fragment.target,
          position: fragment.position,
          trust: fragment.trust,
          visibility: fragment.visibility,
          granted_priority: fragment.granted_priority,
          budget_class: fragment.budget_class,
          token_cap: fragment.token_cap
        },
        provenance_digest: provenance_digest
      }

      with :ok <- validate_data(data) do
        {:ok, struct!(__MODULE__, Map.put(data, :digest, Value.digest!(data)))}
      end
    end
  end

  def new(%Fragment{}, rendered, definition_ref, _evidence),
    do: {:error, {:invalid_prompt_receipt_input, shape(rendered), definition_ref}}

  @doc "Returns the portable receipt representation."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = receipt), do: Map.from_struct(receipt)

  @doc "Restores and verifies a receipt from portable data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%__MODULE__{} = receipt), do: receipt |> to_data() |> from_data()

  def from_data(value) when is_map(value) do
    with {:ok, value} <- exact_fields(value, fields(), :prompt_receipt),
         value <- Map.update!(value, :prompt_ref, &stable_ref/1),
         {:ok, placement} <- exact_fields(value.placement, @placement_fields, :placement),
         value <- Map.put(value, :placement, normalize_placement(placement)),
         receipt <- struct!(__MODULE__, value),
         data <- receipt |> Map.from_struct() |> Map.delete(:digest),
         :ok <- validate_data(data),
         true <- valid_digest?(receipt.digest),
         true <- receipt.digest == Value.digest!(data) do
      {:ok, receipt}
    else
      false -> {:error, :prompt_receipt_digest_mismatch}
      {:error, _reason} = error -> error
    end
  rescue
    _error -> {:error, :invalid_prompt_receipt}
  end

  def from_data(value), do: {:error, {:invalid_prompt_receipt, shape(value)}}

  @spec estimated_tokens(String.t()) :: non_neg_integer()
  defp estimated_tokens(""), do: 0
  defp estimated_tokens(content), do: max(div(byte_size(content) + 3, 4), 1)

  @spec validate_data(map()) :: :ok | {:error, term()}
  defp validate_data(data) do
    with :ok <- validate_schema(data),
         :ok <- validate_generator(data),
         :ok <- validate_definition_ref(data.definition_ref),
         :ok <- validate_prompt_ref(data.prompt_ref),
         :ok <- validate_evidence_digests(data),
         :ok <- validate_bytes(data.bytes),
         :ok <- validate_token_estimate(data.estimated_tokens, data.bytes),
         :ok <- validate_placement(data.placement) do
      validate_portable(data)
    end
  end

  @spec validate_schema(map()) :: :ok | {:error, term()}
  defp validate_schema(%{schema_version: @schema_version}), do: :ok

  defp validate_schema(%{schema_version: schema_version}),
    do: {:error, {:unsupported_prompt_receipt_schema, schema_version}}

  @spec validate_generator(map()) :: :ok | {:error, term()}
  defp validate_generator(%{
         generator_id: @generator_id,
         generator_version: @generator_version
       }),
       do: :ok

  defp validate_generator(_data), do: {:error, :prompt_receipt_generator_mismatch}

  @spec validate_definition_ref(term()) :: :ok | {:error, term()}
  defp validate_definition_ref(definition_ref) do
    case Ref.parse(definition_ref) do
      {:ok, %Ref{}} -> :ok
      _other -> {:error, {:invalid_prompt_receipt_definition_ref, definition_ref}}
    end
  end

  @spec validate_prompt_ref(term()) :: :ok | {:error, term()}
  defp validate_prompt_ref(prompt_ref) do
    if valid_stable_ref?(prompt_ref),
      do: :ok,
      else: {:error, :invalid_prompt_receipt_prompt_ref}
  end

  @spec validate_evidence_digests(map()) :: :ok | {:error, term()}
  defp validate_evidence_digests(data) do
    digests = [
      data.fragment_digest,
      data.rendered_digest,
      data.input_evidence_digest,
      data.provenance_digest
    ]

    if Enum.all?(digests, &valid_digest?/1),
      do: :ok,
      else: {:error, :invalid_prompt_receipt_evidence_digest}
  end

  @spec validate_bytes(term()) :: :ok | {:error, term()}
  defp validate_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: :ok
  defp validate_bytes(bytes), do: {:error, {:invalid_prompt_receipt_bytes, bytes}}

  @spec validate_token_estimate(term(), non_neg_integer()) :: :ok | {:error, term()}
  defp validate_token_estimate(estimate, bytes) do
    if estimate == estimated_tokens_for_bytes(bytes),
      do: :ok,
      else: {:error, :invalid_prompt_receipt_token_estimate}
  end

  @spec validate_placement(term()) :: :ok | {:error, term()}
  defp validate_placement(placement) do
    if valid_placement?(placement),
      do: :ok,
      else: {:error, :invalid_prompt_receipt_placement}
  end

  @spec validate_portable(map()) :: :ok | {:error, term()}
  defp validate_portable(data) do
    case Value.validate(data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_prompt_receipt, reason}}
    end
  end

  @spec valid_placement?(map()) :: boolean()
  defp valid_placement?(placement) do
    valid_stable_ref?(placement.scope) and
      valid_placement_enums?(placement) and valid_token_cap?(placement.token_cap)
  end

  @spec valid_placement_enums?(map()) :: boolean()
  defp valid_placement_enums?(placement) do
    [
      {placement.target, [:instructions, :context, :task]},
      {placement.position, [:start, :end, :replace]},
      {placement.trust, [:instruction, :data]},
      {placement.visibility, [:private, :agent, :operator, :public]},
      {placement.granted_priority, [:low, :normal, :high]},
      {placement.budget_class, [:small, :standard, :large]}
    ]
    |> Enum.all?(fn {value, allowed} -> value in allowed end)
  end

  @spec valid_token_cap?(term()) :: boolean()
  defp valid_token_cap?(nil), do: true
  defp valid_token_cap?(token_cap), do: is_integer(token_cap) and token_cap > 0

  @spec exact_fields(map(), [atom()], atom()) :: {:ok, map()} | {:error, term()}
  defp exact_fields(value, expected, label) when is_map(value) and not is_struct(value) do
    allowed = expected ++ Enum.map(expected, &Atom.to_string/1)

    cond do
      Enum.any?(Map.keys(value), &(&1 not in allowed)) ->
        {:error, {:unknown_prompt_receipt_fields, label}}

      Enum.any?(expected, fn key ->
        Map.has_key?(value, key) and Map.has_key?(value, Atom.to_string(key))
      end) ->
        {:error, {:duplicate_prompt_receipt_fields, label}}

      Enum.any?(expected, fn key ->
        not Map.has_key?(value, key) and not Map.has_key?(value, Atom.to_string(key))
      end) ->
        {:error, {:missing_prompt_receipt_fields, label}}

      true ->
        {:ok,
         Map.new(expected, fn key ->
           {key, Map.get(value, key, Map.get(value, Atom.to_string(key)))}
         end)}
    end
  end

  defp exact_fields(_value, _expected, label),
    do: {:error, {:invalid_prompt_receipt_fields, label}}

  @spec normalize_placement(map()) :: map()
  defp normalize_placement(placement) do
    placement = Map.update!(placement, :scope, &stable_ref/1)

    [
      target: [:instructions, :context, :task],
      position: [:start, :end, :replace],
      trust: [:instruction, :data],
      visibility: [:private, :agent, :operator, :public],
      granted_priority: [:low, :normal, :high],
      budget_class: [:small, :standard, :large]
    ]
    |> Enum.reduce(placement, fn {field, allowed}, normalized ->
      Map.update!(normalized, field, &normalize_enum(&1, allowed))
    end)
  end

  @spec normalize_enum(term(), [atom()]) :: term()
  defp normalize_enum(value, allowed) when is_binary(value) do
    Enum.find(allowed, value, &(Atom.to_string(&1) == value))
  end

  defp normalize_enum(value, _allowed), do: value

  @spec stable_ref(term()) :: term()
  defp stable_ref(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp stable_ref(value), do: value

  @spec valid_stable_ref?(term()) :: boolean()
  defp valid_stable_ref?(value), do: is_binary(value) and value != ""

  @spec valid_digest?(term()) :: boolean()
  defp valid_digest?(digest) when is_binary(digest) and byte_size(digest) == 64 do
    match?({:ok, _bytes}, Base.decode16(digest, case: :lower))
  end

  defp valid_digest?(_digest), do: false

  @spec estimated_tokens_for_bytes(non_neg_integer()) :: non_neg_integer()
  defp estimated_tokens_for_bytes(0), do: 0
  defp estimated_tokens_for_bytes(bytes), do: max(div(bytes + 3, 4), 1)

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other
end
