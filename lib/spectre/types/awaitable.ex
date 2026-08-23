defmodule Spectre.Awaitable do
  @moduledoc """
  Runtime state waiting for a policy resolution.

  Awaitables are deliberately small. They identify what kind of input is
  needed, who may resolve it, and, when applicable, which effect they gate.
  """

  defstruct [
    :id,
    :kind,
    :name,
    :subject_id,
    :run_id,
    :label,
    :max_attempts,
    status: :open,
    attempts: 0,
    resolver: :conversation,
    metadata: %{}
  ]

  @type status :: :open | :accepted | :rejected | :cancelled | :expired
  @type resolver :: :conversation | :external

  @type t :: %__MODULE__{
          id: term(),
          kind: atom(),
          name: term(),
          status: status(),
          subject_id: term(),
          run_id: String.t() | nil,
          label: atom() | nil,
          attempts: non_neg_integer(),
          max_attempts: pos_integer() | nil,
          resolver: resolver(),
          metadata: map()
        }

  @doc """
  Opens a policy awaitable for an effect.

  `:conversation` is the compatibility default. `:external` keeps subsequent
  conversation turns on normal routing and requires a host-sourced decision.
  """
  @spec open_policy(term(), Spectre.Effect.t() | term(), keyword()) :: t()
  def open_policy(policy, subject, opts \\ []) when not is_nil(policy) do
    {subject_id, run_id} =
      case subject do
        %Spectre.Effect{id: id, run_id: run_id} -> {id, run_id}
        id -> {id, Keyword.get(opts, :run_id)}
      end

    %__MODULE__{
      id: Keyword.get(opts, :id, Spectre.Identity.uuid7()),
      kind: :policy,
      name: policy,
      subject_id: subject_id,
      run_id: run_id,
      max_attempts: Keyword.get(opts, :max_attempts),
      resolver: Keyword.get(opts, :resolver, :conversation),
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
  Marks an awaitable as expired.
  """
  @spec expire(t()) :: t()
  def expire(%__MODULE__{} = awaitable), do: %{awaitable | status: :expired}

  @doc """
  Increments the retry attempt counter.
  """
  @spec increment(t()) :: t()
  def increment(%__MODULE__{} = awaitable), do: %{awaitable | attempts: awaitable.attempts + 1}
end
