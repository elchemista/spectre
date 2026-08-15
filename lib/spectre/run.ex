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

  alias Spectre.Canonical.Value, as: CanonicalValue
  alias Spectre.Definition
  alias Spectre.Definition.Canonical, as: CanonicalDefinition
  alias Spectre.Definition.Ref, as: DefinitionRef
  alias Spectre.Execution.Closure
  alias Spectre.Input
  alias Spectre.Result
  alias Spectre.Run.Codec
  alias Spectre.Run.Ref
  alias Spectre.Run.StartContinuation
  alias Spectre.Run.Value
  alias Spectre.State

  @run_version 3

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
            definition_ref: nil,
            activation_generation: 0,
            authority_epoch: 0,
            closure_digest: nil,
            deployment_requirement: nil,
            start_continuation: nil,
            inference_continuation: nil,
            metadata: %{},
            last_error: nil

  @type status :: :ready | :boundary | :awaiting | :complete | :failed
  @type cursor :: :turn | :policy | :effect | :inference | :complete

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
          definition_ref: DefinitionRef.t(),
          activation_generation: non_neg_integer(),
          authority_epoch: non_neg_integer(),
          closure_digest: String.t(),
          deployment_requirement: term() | nil,
          start_continuation: StartContinuation.t() | nil,
          inference_continuation: Spectre.Run.InferenceContinuation.t() | nil,
          metadata: map(),
          last_error: term()
        }

  @doc false
  @spec new(module(), Input.t(), State.t(), keyword()) :: t()
  def new(agent, %Input{} = input, %State{} = state, opts \\ [])
      when is_atom(agent) and not is_nil(agent) and is_list(opts) do
    id = Value.logical_id(Keyword.get(opts, :run_id), "run") || Spectre.Identity.uuid7()
    trace_id = Value.logical_id(Keyword.get(opts, :trace_id), "trace") || id
    definition_ref = definition_ref(agent, opts)

    %__MODULE__{
      id: id,
      agent: agent,
      input: input,
      state: state,
      trace_id: trace_id,
      causation_id: Value.logical_id(Keyword.get(opts, :causation_id), "cause"),
      correlation_id: Value.logical_id(Keyword.get(opts, :correlation_id), "correlation"),
      definition_ref: definition_ref,
      activation_generation: Keyword.get(opts, :activation_generation, 0),
      authority_epoch: Keyword.get(opts, :authority_epoch, 0),
      closure_digest: closure_digest(agent, definition_ref, opts),
      deployment_requirement: Keyword.get(opts, :deployment_requirement),
      metadata: logical_metadata(Keyword.get(opts, :run_metadata, %{}))
    }
  end

  @doc false
  @spec validate_options(keyword()) :: :ok | {:error, term()}
  def validate_options(opts) when is_list(opts) do
    with :ok <- validate_logical_option(opts, :run_id),
         :ok <- validate_logical_option(opts, :trace_id),
         :ok <- validate_logical_option(opts, :causation_id),
         :ok <- validate_logical_option(opts, :correlation_id),
         :ok <- validate_definition_ref_option(opts),
         :ok <- validate_non_negative_option(opts, :activation_generation),
         :ok <- validate_non_negative_option(opts, :authority_epoch),
         :ok <- validate_digest_option(opts, :closure_digest),
         :ok <- validate_portable_option(opts, :deployment_requirement) do
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

  @doc false
  @spec definition_ref(module(), keyword()) :: DefinitionRef.t()
  def definition_ref(agent, opts \\ []) do
    case Keyword.get(opts, :definition_ref) do
      %DefinitionRef{} = ref ->
        if DefinitionRef.valid?(ref), do: ref, else: raise_invalid_definition_ref(ref)

      value when is_binary(value) ->
        case DefinitionRef.parse(value) do
          {:ok, ref} -> ref
          {:error, _reason} -> raise_invalid_definition_ref(value)
        end

      nil ->
        compiled_definition_ref(agent)

      value ->
        raise_invalid_definition_ref(value)
    end
  end

  @doc false
  @spec legacy_definition_ref(module()) :: DefinitionRef.t()
  def legacy_definition_ref(agent) when is_atom(agent) and not is_nil(agent) do
    digest = CanonicalValue.digest!(%{"legacy_compiled_agent" => Atom.to_string(agent)})
    {:ok, ref} = DefinitionRef.parse("sha256:" <> digest)
    ref
  end

  @doc false
  @spec default_closure_digest(module(), DefinitionRef.t()) :: String.t()
  def default_closure_digest(agent, %DefinitionRef{} = definition_ref) do
    manifest = Definition.manifest!(agent)

    unless manifest.definition_ref == definition_ref do
      raise ArgumentError,
            "Definition Ref does not match the sealed compiled Manifest: " <>
              inspect(definition_ref)
    end

    Closure.digest(manifest.execution_closure)
  end

  @doc false
  @spec legacy_closure_digest(module(), DefinitionRef.t()) :: String.t()
  def legacy_closure_digest(agent, %DefinitionRef{} = definition_ref) do
    CanonicalValue.digest!(%{
      "mode" => "compiled_unsealed",
      "agent" => Atom.to_string(agent),
      "definition_ref" => DefinitionRef.to_string(definition_ref)
    })
  end

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

  defp compiled_definition_ref(agent) do
    case CanonicalDefinition.lower(agent) do
      {:ok, canonical} ->
        CanonicalDefinition.ref(canonical)

      {:error, reason} ->
        raise ArgumentError, "cannot seal compiled Definition: #{inspect(reason)}"
    end
  end

  defp closure_digest(agent, definition_ref, opts) do
    case Keyword.get(opts, :closure_digest) do
      nil -> default_closure_digest(agent, definition_ref)
      value when is_binary(value) and value != "" -> value
      value -> raise ArgumentError, "invalid Run closure digest: #{inspect(value)}"
    end
  end

  defp validate_definition_ref_option(opts) do
    case Keyword.fetch(opts, :definition_ref) do
      :error ->
        :ok

      {:ok, %DefinitionRef{} = ref} ->
        if DefinitionRef.valid?(ref),
          do: :ok,
          else: {:error, {:invalid_run_option, :definition_ref}}

      {:ok, value} when is_binary(value) ->
        case DefinitionRef.parse(value) do
          {:ok, _ref} -> :ok
          {:error, reason} -> {:error, {:invalid_run_option, :definition_ref, reason}}
        end

      {:ok, value} ->
        {:error, {:invalid_run_option, :definition_ref, value}}
    end
  end

  defp validate_non_negative_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, value} when is_integer(value) and value >= 0 -> :ok
      {:ok, value} -> {:error, {:invalid_run_option, key, value}}
    end
  end

  defp validate_digest_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> :ok
      {:ok, value} when is_binary(value) and value != "" -> :ok
      {:ok, value} -> {:error, {:invalid_run_option, key, value}}
    end
  end

  defp validate_portable_option(opts, key) do
    case Keyword.fetch(opts, key) do
      :error ->
        :ok

      {:ok, value} ->
        case Value.validate(value, [key]) do
          :ok -> :ok
          {:error, reason} -> {:error, {:invalid_run_option, key, reason}}
        end
    end
  end

  defp raise_invalid_definition_ref(value) do
    raise ArgumentError, "invalid Run Definition Ref: #{inspect(value)}"
  end
end
