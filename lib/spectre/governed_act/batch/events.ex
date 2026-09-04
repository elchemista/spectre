defmodule Spectre.GovernedAct.Batch.Events do
  @moduledoc """
  Positional queries over a verified ledger batch.

  Ledger verification guarantees contiguous, zero-based `batch_index` values,
  so semantic validators can express adjacency directly without each family
  reimplementing record decoding and event matching.
  """

  alias Spectre.Canonical.Record
  alias Spectre.Domain.Event

  @doc false
  @spec at([Event.t()], integer()) :: Event.t() | nil
  def at(_events, index) when index < 0, do: nil
  def at(events, index), do: Enum.at(events, index)

  @doc false
  @spec after?([Event.t()], String.t(), String.t(), integer()) :: boolean()
  def after?(events, type, identity, index) do
    Enum.any?(events, fn event ->
      event.type == type and event.identity == identity and event.batch_index > index
    end)
  end

  @doc false
  @spec sequence?([Event.t()], [{String.t(), String.t(), map()}], non_neg_integer()) :: boolean()
  def sequence?(events, expected, first_index) do
    expected
    |> Enum.with_index(first_index)
    |> Enum.all?(fn {{type, identity, data}, index} ->
      manual_at?(events, index, type, identity, data)
    end)
  end

  @doc false
  @spec record_at?([Event.t()], integer(), String.t(), module(), struct()) :: boolean()
  def record_at?(events, index, type, module, expected) do
    case at(events, index) do
      %{type: ^type, identity: identity, data: data} ->
        identity == Record.ref(expected) and Record.decode(module, data) == {:ok, expected}

      _missing_or_different ->
        false
    end
  end

  @doc false
  @spec embedded_at?(
          [Event.t()],
          integer(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          module(),
          struct()
        ) :: boolean()
  def embedded_at?(
        events,
        index,
        type,
        act_ref,
        relation_ref,
        relation_key,
        record_key,
        module,
        expected
      ) do
    case at(events, index) do
      %{type: ^type, identity: identity, data: data} ->
        identity == Record.ref(expected) and data["act_ref"] == act_ref and
          data[relation_key] == relation_ref and
          Record.decode(module, data[record_key]) == {:ok, expected}

      _missing_or_different ->
        false
    end
  end

  @doc false
  @spec manual_at?([Event.t()], integer(), String.t(), String.t(), map()) :: boolean()
  def manual_at?(events, index, type, identity, expected_data) do
    case at(events, index) do
      %{type: ^type, identity: ^identity, data: data} ->
        Enum.all?(expected_data, fn {key, value} -> data[key] == value end)

      _missing_or_different ->
        false
    end
  end
end
