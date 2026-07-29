defmodule Spectre.Run do
  @moduledoc """
  Serializable continuation for one unit of Spectre work.

  A Run owns logical execution state only. Provider clients, processes,
  callbacks, memory values, and runtime options are deliberately re-resolved
  for every `Spectre.Runtime.advance/2` or `Spectre.Runtime.resume/3`.

  Hosts normally consume the public `Spectre.Turn` projection. Actor/runtime
  integrations can checkpoint a Run with `checkpoint/2` and restore it with
  `restore/2`.
  """

  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.Run.Codec
  alias Spectre.Run.Ref
  alias Spectre.Run.Value
  alias Spectre.State

  @run_version 1

  @enforce_keys [:id, :agent, :input, :state, :trace_id]
  defstruct run_version: @run_version,
            id: nil,
            agent: nil,
            input: nil,
            state: nil,
            result: nil,
            status: :ready,
            cursor: :turn,
            waiting: nil,
            revision: 0,
            step_id: nil,
            trace_id: nil,
            causation_id: nil,
            correlation_id: nil,
            metadata: %{},
            last_error: nil

  @type status :: :ready | :boundary | :awaiting | :complete | :failed
  @type cursor :: :turn | :policy | :effect | :complete

  @type t :: %__MODULE__{
          run_version: pos_integer(),
          id: String.t(),
          agent: module(),
          input: Input.t(),
          state: State.t(),
          result: Result.t() | nil,
          status: status(),
          cursor: cursor(),
          waiting: Spectre.Run.Boundary.t() | Spectre.Invocation.t() | nil,
          revision: non_neg_integer(),
          step_id: String.t() | nil,
          trace_id: String.t(),
          causation_id: String.t() | nil,
          correlation_id: String.t() | nil,
          metadata: map(),
          last_error: term()
        }

  @doc false
  @spec new(module(), Input.t(), State.t(), keyword()) :: t()
  def new(agent, %Input{} = input, %State{} = state, opts \\ [])
      when is_atom(agent) and not is_nil(agent) and is_list(opts) do
    id = Value.logical_id(Keyword.get(opts, :run_id), "run") || Spectre.Identity.uuid7()
    trace_id = Value.logical_id(Keyword.get(opts, :trace_id), "trace") || id

    %__MODULE__{
      id: id,
      agent: agent,
      input: input,
      state: state,
      trace_id: trace_id,
      causation_id: Value.logical_id(Keyword.get(opts, :causation_id), "cause"),
      correlation_id: Value.logical_id(Keyword.get(opts, :correlation_id), "correlation"),
      metadata: logical_metadata(Keyword.get(opts, :run_metadata, %{}))
    }
  end

  @doc false
  @spec validate_options(keyword()) :: :ok | {:error, term()}
  def validate_options(opts) when is_list(opts) do
    with :ok <- validate_logical_option(opts, :run_id),
         :ok <- validate_logical_option(opts, :trace_id),
         :ok <- validate_logical_option(opts, :causation_id),
         :ok <- validate_logical_option(opts, :correlation_id) do
      validate_metadata_option(opts)
    end
  end

  @doc """
  Builds the revision-fenced public reference for a Run boundary.
  """
  @spec ref(t(), Ref.kind(), String.t(), term()) :: Ref.t()
  def ref(%__MODULE__{} = run, kind, boundary_id, subject_id \\ nil) do
    Ref.new(run.id, run.revision, kind, boundary_id, subject_id)
  end

  @doc """
  Serializes a continuation after stripping transport-only envelope details.

  The codec rejects non-portable values in authoritative State or Result data
  rather than silently checkpointing process-local handles.
  """
  @spec checkpoint(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def checkpoint(%__MODULE__{} = run, opts \\ []), do: Codec.encode(run, opts)

  @doc """
  Restores and validates a Run checkpoint.
  """
  @spec restore(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def restore(binary, opts \\ []) when is_binary(binary), do: Codec.decode(binary, opts)

  @doc false
  @spec version() :: pos_integer()
  def version, do: @run_version

  defp validate_logical_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, nil} ->
        :ok

      {:ok, ""} ->
        {:error, {:invalid_run_option, key, :empty}}

      {:ok, value} ->
        case Value.validate(value, [key]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:invalid_run_option, key, reason}}
        end
    end
  end

  defp validate_metadata_option(opts) do
    case Keyword.get(opts, :run_metadata, %{}) do
      metadata when is_map(metadata) ->
        case Value.validate(metadata, [:run_metadata]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:invalid_run_option, :run_metadata, reason}}
        end

      _metadata ->
        {:error, {:invalid_run_option, :run_metadata, :not_a_map}}
    end
  end

  defp logical_metadata(metadata) when is_map(metadata), do: metadata
  defp logical_metadata(_metadata), do: %{}
end
