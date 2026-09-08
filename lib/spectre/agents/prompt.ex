defmodule Spectre.Prompt do
  @moduledoc """
  Pure, bounded composition of prompt text with explicit source contributions.

      Prompt.compose(turn, [
        {:evidence, input.ref},
        {:text, "request", "Propose an answer; do not claim an effect happened."}
      ], max_bytes: 16_384)

  Contributions are ordered, not implicitly merged. Evidence must be visible
  to the Turn. `{:evidence, ref,
  text}` records an explicit local rendering of non-text input. `{:text, name,
  text}` is application-generated text, not observed Evidence or authority.
  All text must be UTF-8. Agent prompt declarations use their own compiled EEx
  renderer; this lower-level API only composes already rendered text. No EEx
  or executable template comes from ledger data.

  `text/1` joins the parts with two newlines. Alternatively a host can map
  `parts` to its provider's message format: this library assigns no provider
  roles or model options. The byte budget includes separators; it is not a
  tokenizer or an inference Meter. Overflow rejects the whole prompt, never
  silently drops context. Parts default to at most 64 and output to 65,536 bytes.

  Labels conservatively include the whole visible Turn, even when only some
  Evidence is quoted. Rendering cannot make input trusted or authorize its
  disclosure. This is not a `Spectre.Candidate.Template`, a provider call, or a
  streaming engine. Only an admitted Act may cross the governed I/O boundary.
  """

  alias Spectre.{Evidence, Label, Mind, Portable}
  alias Spectre.Mind.Turn
  alias Spectre.Router.Rule

  @defaults [max_bytes: 65_536, max_parts: 64]
  @enforce_keys [:turn_ref, :parts, :labels]
  defstruct @enforce_keys

  @type contribution ::
          {:evidence, String.t()}
          | {:evidence, String.t(), String.t()}
          | {:text, String.t(), String.t()}
  @type part :: %{
          required(:kind) => :evidence | :generated,
          required(:name) => String.t(),
          required(:text) => String.t(),
          optional(:evidence_ref) => String.t()
        }
  @type t :: %__MODULE__{turn_ref: String.t(), parts: [part()], labels: [Label.t()]}

  @doc "Composes explicitly selected text without I/O, clock reads or authority changes."
  @spec compose(Turn.t(), [contribution()], keyword() | map()) :: {:ok, t()} | {:error, term()}
  def compose(turn, contributions, opts \\ [])

  def compose(%Turn{} = turn, contributions, opts) when is_list(contributions) do
    with {:ok, limits} <- limits(opts),
         {:ok, _context} <- Turn.context(turn),
         {:ok, labels} <- Turn.labels(turn),
         {:ok, parts} <- collect(contributions, Map.new(turn.evidence, &{&1.ref, &1}), limits) do
      {:ok, %__MODULE__{turn_ref: turn.ref, parts: parts, labels: labels}}
    end
  end

  def compose(_turn, _contributions, _opts), do: {:error, :invalid_prompt_composition}

  @doc "Renders the already budget-checked parts; no template code is evaluated."
  @spec text(t()) :: String.t()
  def text(%__MODULE__{parts: parts}), do: Enum.map_join(parts, "\n\n", & &1.text)

  @doc "Returns the content reference of the exact text, order, origins and Turn labels."
  @spec ref(t()) :: String.t()
  def ref(%__MODULE__{} = prompt) do
    Portable.content_ref!(:prompt, %{
      "turn_ref" => prompt.turn_ref,
      "parts" =>
        Enum.map(prompt.parts, &Map.new(&1, fn {key, value} -> {Atom.to_string(key), value} end)),
      "labels" => Enum.map(prompt.labels, &Label.canonical/1)
    })
  end

  @doc """
  Builds optional derived provenance, without appending it or copying prompt text.

  The payload contains the content reference and contribution origins. Parents,
  conservative labels and authenticated bindings come from the Mind builder.
  Record it explicitly through `Spectre.record_derivation/4` before citing it
  in a new proposal. A digest is a binding, not proof of truth or anonymization.
  """
  @spec evidence(t(), Turn.t(), integer(), keyword() | map()) ::
          {:ok, Evidence.t()} | {:error, term()}
  def evidence(prompt, turn, observed_at, attrs \\ [])

  def evidence(%__MODULE__{turn_ref: ref} = prompt, %Turn{ref: ref} = turn, observed_at, attrs) do
    with {:ok, attrs} <-
           Portable.normalize_attrs(
             attrs,
             [:labels, :assumptions, :valid_from, :valid_until, :freshness_ms],
             :prompt_evidence
           ) do
      Mind.evidence(
        turn,
        observed_at,
        Map.merge(attrs, %{
          provenance: :derived,
          proposition: %{"kind" => "spectre.prompt", "turn_ref" => turn.ref},
          payload: %{
            "prompt_ref" => ref(prompt),
            "contributions" => Enum.map(prompt.parts, &Map.delete(&1, :text))
          }
        })
      )
    end
  end

  def evidence(_prompt, _turn, _observed_at, _attrs), do: {:error, :prompt_turn_mismatch}

  defp limits(opts) do
    with {:ok, attrs} <- Portable.normalize_attrs(opts, Keyword.keys(@defaults), :prompt),
         limits = Map.merge(Map.new(@defaults), attrs),
         true <- Enum.all?(limits, fn {_key, value} -> is_integer(value) and value > 0 end) do
      {:ok, limits}
    else
      false -> {:error, :invalid_prompt_limits}
      {:error, _} = error -> error
    end
  end

  defp collect(contributions, evidence, limits) do
    collect(contributions, evidence, limits, 0, 0, [])
  end

  defp collect([], _evidence, _limits, _bytes, _count, parts), do: {:ok, Enum.reverse(parts)}

  defp collect([_ | _], _evidence, %{max_parts: max}, _bytes, max, _parts),
    do: {:error, :prompt_part_limit_exceeded}

  defp collect([contribution | rest], evidence, limits, bytes, count, parts) do
    with {:ok, part} <- part(contribution, evidence),
         :ok <- validate_text(part.text),
         next_bytes = bytes + byte_size(part.text) + if(count == 0, do: 0, else: 2),
         true <- next_bytes <= limits.max_bytes do
      collect(rest, evidence, limits, next_bytes, count + 1, [part | parts])
    else
      false -> {:error, :prompt_byte_limit_exceeded}
      {:error, _} = error -> error
    end
  end

  defp collect(_improper, _evidence, _limits, _bytes, _count, _parts),
    do: {:error, :invalid_prompt_contributions}

  defp part({:evidence, ref}, evidence) do
    case Map.fetch(evidence, ref) do
      {:ok, record} -> part({:evidence, ref, record.payload}, evidence)
      :error -> {:error, {:prompt_evidence_outside_turn, ref}}
    end
  end

  defp part({:evidence, ref, text}, evidence) do
    if Map.has_key?(evidence, ref),
      do: {:ok, %{kind: :evidence, name: ref, evidence_ref: ref, text: text}},
      else: {:error, {:prompt_evidence_outside_turn, ref}}
  end

  defp part({:text, name, text}, _evidence) do
    with :ok <- Rule.path(name), do: {:ok, %{kind: :generated, name: name, text: text}}
  end

  defp part(_contribution, _evidence), do: {:error, :invalid_prompt_contribution}

  defp validate_text(text) when is_binary(text) do
    if String.valid?(text), do: :ok, else: {:error, :invalid_prompt_utf8}
  end

  defp validate_text(_text), do: {:error, :prompt_text_required}
end
