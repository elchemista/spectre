defmodule Spectre.Awaiting do
  @moduledoc """
  Runtime gate currently waiting for a user response.

  Awaiting markers are deliberately small. They identify the active policy and
  action id, while the full pending action stays in `Spectre.State.pending_action`.
  """

  defstruct [:kind, :policy, :action_id, attempts: 0, started_at: nil]

  @type t :: %__MODULE__{
          kind: :policy,
          policy: atom(),
          action_id: term(),
          attempts: non_neg_integer(),
          started_at: DateTime.t() | nil
        }

  @doc """
  Creates an awaiting marker for a policy gate.

      awaiting = Spectre.Awaiting.policy(:confirm_delete, pending_action.id)
  """
  @spec policy(atom(), term()) :: t()
  def policy(policy, action_id) when is_atom(policy) do
    %__MODULE__{
      kind: :policy,
      policy: policy,
      action_id: action_id,
      started_at: DateTime.utc_now()
    }
  end

  @doc """
  Increments the attempt counter for an awaiting gate.

      awaiting = Spectre.Awaiting.increment(awaiting)
  """
  @spec increment(t()) :: t()
  def increment(%__MODULE__{} = awaiting), do: %{awaiting | attempts: awaiting.attempts + 1}
end
