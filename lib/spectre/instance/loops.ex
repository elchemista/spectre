defmodule Spectre.Instance.Loops do
  @moduledoc """
  Committed operational-loop views for `Spectre.Instance`.

  Reads Work, Vigil and Directive loops out of the canonical sections,
  resolves selectors and caller visibility, and builds the reduced
  environments handed to `Spectre.Operation.Runtime`.
  """

  alias Spectre.Instance.Canonical
  alias Spectre.Instance.State, as: InstanceState
  alias Spectre.Operation.Control
  alias Spectre.Operation.Control.Command, as: ControlCommand
  alias Spectre.Operation.Event, as: OperationEvent
  alias Spectre.Operation.Loop, as: OperationLoop
  alias Spectre.Operation.Ref, as: OperationRef
  alias Spectre.Operation.View, as: OperationView
  alias Spectre.Run.Value

  @doc "Extracts a loop id from a public reference, raising on invalid shapes."
  @spec operation_id(OperationRef.t() | String.t() | term()) :: String.t()
  def operation_id(%OperationRef{id: id}), do: id
  def operation_id(id) when is_binary(id) and id != "", do: id

  def operation_id(value),
    do: raise(ArgumentError, "invalid operational loop reference: #{inspect(value)}")

  @doc "Maps a loop kind onto its canonical section name."
  @spec operation_section(OperationLoop.kind()) :: atom()
  def operation_section(:work), do: :work
  def operation_section(:vigil), do: :vigil
  def operation_section(:directive), do: :directive

  @doc "Fetches one committed loop and its Control across all sections."
  @spec operation_loop(InstanceState.t(), String.t()) ::
          {:ok, OperationLoop.t(), Control.t()} | {:error, :operation_loop_not_found}
  def operation_loop(%InstanceState{} = data, loop_id) do
    Enum.find_value(
      [:work, :vigil, :directive],
      {:error, :operation_loop_not_found},
      fn section ->
        case Map.get(canonical_value!(data, section), loop_id) do
          %OperationLoop{} = loop ->
            controls = canonical_value!(data, :control)
            control = Map.get(controls, loop.id, Control.new(loop.id))
            {:ok, loop, control}

          nil ->
            false
        end
      end
    )
  end

  @doc "Lists every committed loop with its Control, in stable creation order."
  @spec all_operation_loops(InstanceState.t()) :: [{OperationLoop.t(), Control.t()}]
  def all_operation_loops(%InstanceState{} = data) do
    controls = canonical_value!(data, :control)

    [:work, :vigil, :directive]
    |> Enum.flat_map(fn section -> Map.values(canonical_value!(data, section)) end)
    |> Enum.filter(&match?(%OperationLoop{}, &1))
    |> Enum.sort_by(&{&1.created_at, &1.id})
    |> Enum.map(fn loop -> {loop, Map.get(controls, loop.id, Control.new(loop.id))} end)
  end

  @doc "Reads one canonical section value, raising when the section is invalid."
  @spec canonical_value!(InstanceState.t(), atom()) :: term()
  def canonical_value!(%{canonical: canonical}, section) do
    case Canonical.fetch(canonical, section) do
      {:ok, value} ->
        value

      {:error, reason} ->
        raise "invalid canonical section #{inspect(section)}: #{inspect(reason)}"
    end
  end

  @doc "Authorizes caller visibility of one loop from subject and origin options."
  @spec authorize_loop(OperationLoop.t(), keyword()) ::
          :ok | {:error, :operation_loop_not_visible}
  def authorize_loop(loop, opts) do
    supplied_subject = Keyword.get(opts, :subject_id)
    origin = Keyword.get(opts, :origin)

    cond do
      not is_nil(supplied_subject) and supplied_subject != loop.subject_id ->
        {:error, :operation_loop_not_visible}

      is_nil(origin) ->
        :ok

      loop.visibility == :subject ->
        :ok

      origin == loop.origin or origin in loop.authorized_origins ->
        :ok

      true ->
        {:error, :operation_loop_not_visible}
    end
  end

  @doc "Returns true when the caller may read one committed operation event."
  @spec event_visible?(InstanceState.t(), OperationEvent.t(), keyword()) :: boolean()
  def event_visible?(%InstanceState{} = data, %OperationEvent{} = event, opts) do
    case operation_loop(data, event.loop_id) do
      {:ok, loop, _control} -> match?(:ok, authorize_loop(loop, opts))
      {:error, _reason} -> false
    end
  end

  @doc "Applies the optional kind/controller/status listing filters."
  @spec loop_filter?(OperationLoop.t(), keyword()) :: boolean()
  def loop_filter?(loop, opts) do
    kind = Keyword.get(opts, :kind)
    controller = Keyword.get(opts, :controller)
    status = Keyword.get(opts, :status)

    (is_nil(kind) or loop.kind == kind) and
      (is_nil(controller) or loop.controller == controller) and
      (is_nil(status) or loop.status in List.wrap(status))
  end

  @doc "Matches one loop against a resolve selector."
  @spec selector_matches?(OperationLoop.t(), term()) :: boolean()
  def selector_matches?(loop, nil), do: not OperationLoop.terminal?(loop)
  def selector_matches?(loop, %OperationRef{id: id}), do: loop.id == id
  def selector_matches?(loop, id) when is_binary(id), do: loop.id == id

  def selector_matches?(loop, selector) when is_list(selector),
    do: selector_matches?(loop, Map.new(selector))

  def selector_matches?(loop, selector) when is_map(selector) do
    selector = atomize_selector(selector)

    Enum.all?(selector, fn
      {:id, value} -> loop.id == value
      {:kind, value} -> loop.kind == value
      {:controller, value} -> loop.controller == value or loop.controller_id == value
      {:definition, value} -> loop.controller_id == value
      {:status, value} -> loop.status in List.wrap(value)
      {:phase, value} -> loop.phase == value
      {:origin, value} -> loop.origin == value
      {:turn_id, value} -> loop.source_turn_id == value
      {:correlation_id, value} -> loop.correlation_id == value
      {:active, true} -> not OperationLoop.terminal?(loop)
      {:active, false} -> OperationLoop.terminal?(loop)
      {_unknown, _value} -> false
    end)
  end

  def selector_matches?(_loop, _selector), do: false

  @doc "Builds and validates a portable loop-control command."
  @spec control_command(OperationLoop.t(), atom(), term(), keyword()) ::
          {:ok, ControlCommand.t()} | {:error, term()}
  def control_command(loop, action, payload, opts) do
    mode = Keyword.get(opts, :mode, :safe)

    if mode == :immediate and not Keyword.get(opts, :authorize_immediate?, false) do
      {:error, :immediate_loop_interruption_not_authorized}
    else
      command =
        ControlCommand.new(loop.id, action,
          id: Keyword.get(opts, :command_id, Spectre.Identity.uuid7()),
          payload: payload,
          mode: mode,
          desired_state: Keyword.get(opts, :desired_state),
          correlation_id: Keyword.get(opts, :correlation_id, Spectre.Identity.uuid7()),
          causation_id: Keyword.get(opts, :causation_id),
          provenance: Keyword.get(opts, :provenance, %{}),
          base_revision: Keyword.get(opts, :revision),
          metadata: Keyword.get(opts, :metadata, %{})
        )

      case Value.validate(command, [:loop_control, loop.id]) do
        :ok -> {:ok, command}
        {:error, reason} -> {:error, {:nonportable_loop_control, reason}}
      end
    end
  end

  @doc "Returns true when a start request describes the already committed loop."
  @spec same_loop_request?(OperationLoop.t(), OperationLoop.t()) :: boolean()
  def same_loop_request?(existing, requested) do
    existing.kind == requested.kind and existing.controller == requested.controller and
      existing.controller_version == requested.controller_version and
      existing.base_input == requested.base_input and
      existing.correlation_id == requested.correlation_id
  end

  @doc "Builds the snapshot-fenced environment for preparing one loop attempt."
  @spec operation_snapshot_env(InstanceState.t(), OperationLoop.t()) :: map()
  def operation_snapshot_env(%InstanceState{} = data, loop) do
    section = operation_section(loop.kind)

    {:ok, snapshot} =
      Canonical.snapshot(data.canonical,
        read: [:flow, :work, :vigil, :directive, :control, :correlations],
        write: [section],
        correlation_id: loop.correlation_id
      )

    operation_env(data,
      snapshot_id: snapshot.id,
      canonical_revision: snapshot.base_revision
    )
  end

  @doc "Builds the reduced environment handed to the operation runtime."
  @spec operation_env(InstanceState.t(), keyword()) :: map()
  def operation_env(%InstanceState{} = data, opts \\ []) do
    committed = %{
      work: committed_views(data, :work),
      vigil: committed_views(data, :vigil),
      directive: committed_views(data, :directive)
    }

    %{
      agent: data.agent,
      subject_id: data.subject.id,
      epoch: data.generation,
      snapshot_id: Keyword.get(opts, :snapshot_id, Spectre.Identity.uuid7()),
      canonical_revision: Keyword.get(opts, :canonical_revision, data.canonical.revision),
      committed: committed,
      now: System.system_time(:millisecond)
    }
  end

  defp committed_views(data, section) do
    controls = canonical_value!(data, :control)

    data
    |> canonical_value!(section)
    |> Map.new(fn {id, loop} ->
      {id, OperationView.from_loop(loop, Map.get(controls, id, Control.new(id)))}
    end)
  end

  defp atomize_selector(selector) do
    Map.new(selector, fn {key, value} ->
      normalized =
        case key do
          "id" -> :id
          "kind" -> :kind
          "controller" -> :controller
          "definition" -> :definition
          "status" -> :status
          "phase" -> :phase
          "origin" -> :origin
          "turn_id" -> :turn_id
          "correlation_id" -> :correlation_id
          "active" -> :active
          other -> other
        end

      {normalized, value}
    end)
  end
end
