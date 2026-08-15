defmodule Spectre.Prompt.Value do
  @moduledoc """
  Runtime prompt value paired with explicit trust and origin evidence.

  The wrapper lets a value cross an assigns or memory boundary without losing
  the evidence attached by its producer. Prompt materialization unwraps the
  value for rendering and copies only its trust, provenance and authenticity
  into the resulting typed fragment metadata.

  Evidence is descriptive: it never promotes runtime content to instruction
  trust and must not be used as an authorization decision by itself.
  """

  alias Spectre.Canonical.Value, as: CanonicalValue

  @trust_classes [:untrusted, :trusted, :system]

  @enforce_keys [:value, :trust, :provenance, :authenticity]
  defstruct [:value, :trust, :provenance, :authenticity]

  @type t :: %__MODULE__{
          value: term(),
          trust: :untrusted | :trusted | :system,
          provenance: map(),
          authenticity: map()
        }

  @doc false
  @spec new(term(), map()) :: t()
  def new(value, evidence) when is_map(evidence) and not is_struct(evidence) do
    prompt_value = %__MODULE__{
      value: value,
      trust: Map.get(evidence, :trust, :untrusted),
      provenance: Map.get(evidence, :provenance, %{}),
      authenticity: Map.get(evidence, :authenticity, %{})
    }

    case validate(prompt_value) do
      :ok -> prompt_value
      {:error, reason} -> raise ArgumentError, "invalid prompt value evidence: #{inspect(reason)}"
    end
  end

  @doc false
  @spec evidence(t()) :: map()
  def evidence(%__MODULE__{} = value) do
    %{
      trust: value.trust,
      provenance: value.provenance,
      authenticity: value.authenticity
    }
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = value) do
    cond do
      value.trust not in @trust_classes ->
        {:error, :invalid_prompt_value_trust}

      not plain_map?(value.provenance) ->
        {:error, :invalid_prompt_value_provenance}

      not plain_map?(value.authenticity) ->
        {:error, :invalid_prompt_value_authenticity}

      true ->
        CanonicalValue.validate(evidence(value))
    end
  end

  def validate(_value), do: {:error, :invalid_prompt_value}

  defp plain_map?(value), do: is_map(value) and not is_struct(value)
end
