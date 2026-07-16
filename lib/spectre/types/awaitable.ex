defmodule Spectre.Awaitable do
  @moduledoc """
  Runtime state waiting for user input.

  Awaitables are deliberately small. They identify what kind of input is
  needed and, when applicable, which effect they are gating.
  """

  defstruct [
    :id,
    :kind,
    :name,
    :subject_id,
    :label,
    :max_attempts,
    status: :open,
    attempts: 0,
    metadata: %{}
  ]

  @type status :: :open | :accepted | :rejected | :cancelled | :expired

  @type t :: %__MODULE__{
          id: term(),
          kind: atom(),
          name: atom() | String.t() | nil,
          status: status(),
          subject_id: term(),
          label: atom() | nil,
          attempts: non_neg_integer(),
          max_attempts: pos_integer() | nil,
          metadata: map()
        }

  @doc """
  Opens a policy awaitable for an effect.
  """
  @spec open_policy(atom(), Spectre.Effect.t() | term(), keyword()) :: t()
  def open_policy(policy, subject, opts \\ []) when is_atom(policy) do
    subject_id =
      case subject do
        %Spectre.Effect{id: id} -> id
        id -> id
      end

    %__MODULE__{
      id: Keyword.get(opts, :id, Spectre.Identity.uuid7()),
      kind: :policy,
      name: policy,
      subject_id: subject_id,
      max_attempts: Keyword.get(opts, :max_attempts),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Marks an awaitable as accepted with the matched policy label.
  """
  @spec accept(t(), atom()) :: t()
  def accept(%__MODULE__{} = awaitable, label) do
    %{awaitable | status: :accepted, label: label}
  end

  @doc """
  Marks an awaitable as rejected with the matched policy label.
  """
  @spec reject(t(), atom()) :: t()
  def reject(%__MODULE__{} = awaitable, label) do
    %{awaitable | status: :rejected, label: label}
  end

  @doc """
  Marks an awaitable as cancelled.
  """
  @spec cancel(t()) :: t()
  def cancel(%__MODULE__{} = awaitable), do: %{awaitable | status: :cancelled}

  @doc """
  Increments the retry attempt counter.
  """
  @spec increment(t()) :: t()
  def increment(%__MODULE__{} = awaitable), do: %{awaitable | attempts: awaitable.attempts + 1}
end
