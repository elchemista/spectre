defmodule Spectre.Input.Source do
  @moduledoc """
  Provider-neutral origin attached to a normalized Spectre input.

  Optional channel and protocol packages use `kind` as their namespace and
  `mount` as the concrete configured endpoint. Identifiers remain opaque to
  the core. Trust is explicit and defaults to `:untrusted`; authentication
  evidence and provenance never promote content on their own.
  """

  @trust_classes [:untrusted, :trusted, :system]

  defstruct [
    :kind,
    :mount,
    :conversation_id,
    :actor_id,
    :reply_to,
    trust: :untrusted,
    provenance: %{},
    authenticity: %{},
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          kind: atom() | String.t(),
          mount: term(),
          conversation_id: term(),
          actor_id: term(),
          reply_to: term(),
          trust: :untrusted | :trusted | :system,
          provenance: map(),
          authenticity: map(),
          metadata: map()
        }

  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = source), do: source |> Map.from_struct() |> new()
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    source = struct(__MODULE__, normalize_fields(attrs))

    case validate(source) do
      :ok -> source
      {:error, reason} -> raise ArgumentError, validation_message(reason, source)
    end
  end

  @doc """
  Validates source evidence at trust and persistence boundaries.

  This is intentionally separate from `new/1`: checkpoint decoding can
  reconstruct a struct without invoking its constructor, so consumers must be
  able to re-establish the same invariants without raising.
  """
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = source) do
    with :ok <- validate_kind(source.kind),
         :ok <- validate_trust(source.trust),
         :ok <- validate_map(source.provenance, :provenance),
         :ok <- validate_map(source.authenticity, :authenticity) do
      validate_map(source.metadata, :metadata)
    end
  end

  def validate(_source), do: {:error, :invalid_input_source}

  @doc "Returns the closed trust classes understood by the core."
  @spec trust_classes() :: [:untrusted | :trusted | :system]
  def trust_classes, do: @trust_classes

  defp validate_kind(kind) when is_atom(kind) and not is_nil(kind), do: :ok

  defp validate_kind(kind) when is_binary(kind) do
    if kind != "" and String.valid?(kind) and not String.contains?(kind, <<0>>),
      do: :ok,
      else: {:error, :invalid_input_source_kind}
  end

  defp validate_kind(_kind), do: {:error, :invalid_input_source_kind}

  defp validate_trust(trust) when trust in @trust_classes, do: :ok
  defp validate_trust(_trust), do: {:error, :invalid_input_source_trust}

  defp validate_map(value, _field) when is_map(value) and not is_struct(value), do: :ok
  defp validate_map(_value, field), do: {:error, {:invalid_input_source_map, field}}

  defp validation_message(:invalid_input_source_kind, _source),
    do: "input source kind must be a non-empty atom or UTF-8 string"

  defp validation_message(:invalid_input_source_trust, source),
    do: "invalid input source trust: #{inspect(source.trust)}"

  defp validation_message({:invalid_input_source_map, field}, _source),
    do: "input source #{field} must be a map"

  defp validation_message(reason, _source), do: "invalid input source: #{inspect(reason)}"

  defp normalize_fields(attrs) do
    Enum.reduce(fields(), %{}, fn field, normalized ->
      case Map.fetch(attrs, field) do
        {:ok, value} -> Map.put(normalized, field, value)
        :error -> maybe_put_string_field(normalized, attrs, field)
      end
    end)
  end

  defp maybe_put_string_field(normalized, attrs, field) do
    case Map.fetch(attrs, Atom.to_string(field)) do
      {:ok, value} -> Map.put(normalized, field, value)
      :error -> normalized
    end
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
