defmodule Spectre.Agent.Turn do
  @moduledoc """
  Small handler context and its unsubmitted alternatives.

  The sealed Mind Turn carries authenticated input Evidence. Other fields are
  authoring state, not authority. A branch is resolved through compiled names,
  never by converting input strings into atoms. Requests deliberately do not
  duplicate this context, history or a Domain projection.
  """

  @enforce_keys [:ref, :input, :flow, :owner, :definition_ref, :mind_turn]
  defstruct @enforce_keys ++
              [branch: nil, selection: nil, result: nil, requests: [], context: %{}, routing: nil]

  @type t :: %__MODULE__{
          ref: String.t(),
          input: term(),
          flow: atom() | nil,
          owner: String.t(),
          definition_ref: String.t(),
          mind_turn: Spectre.Mind.Turn.t(),
          branch: atom() | nil,
          selection: Spectre.Router.Selection.t() | nil,
          result: map() | nil,
          requests: [Spectre.Instance.Request.t()],
          context: map(),
          routing: term()
        }
end
