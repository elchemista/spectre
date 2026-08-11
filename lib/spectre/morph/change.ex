defmodule Spectre.Morph.Change do
  @moduledoc """
  Transient pipeline value for one governed Agent change.

  Durable truth remains the published Candidate chain in the Definition Store;
  this value only carries ergonomic host context between explicit commits.
  """

  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Store
  alias Spectre.Governance.ChangeSet
  alias Spectre.Governance.EvaluationDelta
  alias Spectre.Instance.Activation
  alias Spectre.Morph.Surface
  alias Spectre.Projection.HumanReport

  @enforce_keys [:instance, :store, :agent, :activation, :surface, :actor_ref, :reason]
  defstruct [
    :instance,
    :store,
    :agent,
    :activation,
    :surface,
    :actor_ref,
    :reason,
    :ref,
    :report,
    :delta,
    :error,
    operations: [],
    mount_ids: [],
    evidence: %{},
    state: :draft
  ]

  @typedoc "The host-visible stage of the transient Morph workflow."
  @type state :: :draft | :evaluated | :approved | :rejected

  @typedoc "A transient view; durable truth remains in the Definition Store."
  @type t :: %__MODULE__{
          instance: GenServer.server(),
          store: Store.config() | nil,
          agent: module() | nil,
          activation: Activation.t() | nil,
          surface: Surface.t(),
          actor_ref: String.t() | nil,
          reason: String.t() | nil,
          ref: CandidateRef.t() | nil,
          report: HumanReport.t() | nil,
          delta: EvaluationDelta.t() | nil,
          error: term() | nil,
          operations: [map()],
          mount_ids: [String.t()],
          evidence: map(),
          state: state()
        }

  @doc false
  @spec append_operations(t(), [map()]) :: t()
  def append_operations(%__MODULE__{} = change, []), do: change

  def append_operations(%__MODULE__{} = change, operations) when is_list(operations) do
    case ensure_operation_capacity(change, length(operations)) do
      :ok -> append_bounded_operations(change, operations)
      {:error, reason} -> fail(change, reason)
    end
  end

  @doc false
  @spec ensure_operation_capacity(t(), non_neg_integer()) :: :ok | {:error, term()}
  def ensure_operation_capacity(%__MODULE__{} = change, additional)
      when is_integer(additional) and additional >= 0 do
    count = length(change.operations) + additional
    limit = ChangeSet.operation_limit()

    if count <= limit,
      do: :ok,
      else: {:error, {:governance_operation_limit_exceeded, count, limit}}
  end

  def ensure_operation_capacity(%__MODULE__{}, additional),
    do: {:error, {:invalid_morph_operation_count, additional}}

  @doc false
  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = change, reason), do: %{change | error: reason}

  @spec operation_mount_ids([map()]) :: MapSet.t(String.t())
  defp operation_mount_ids(operations) do
    operations
    |> Stream.map(&get_in(&1, ["payload", "mount_id"]))
    |> Stream.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
  end

  @spec append_bounded_operations(t(), [map()]) :: t()
  defp append_bounded_operations(change, operations) do
    mount_ids =
      change.mount_ids
      |> MapSet.new()
      |> MapSet.union(operation_mount_ids(operations))
      |> Enum.sort()

    # `operations` is an observable ordered field. Morph therefore batches all
    # derived cases and performs one bounded append per public proposal call.
    %{change | operations: change.operations ++ operations, mount_ids: mount_ids}
  end
end
