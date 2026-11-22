defmodule Spectre.Server.Tool do
  @moduledoc false

  alias Spectre.Server.{ActivityBinding, Checkpoint, Command, Context, Failure}
  alias Spectre.Stack.{Binding, Definition, Tools}

  @public_options [:on_result, :timeout, :confirmation]

  def request(%Context{} = ctx, name, input, opts, expected) do
    command = %Command{kind: :tool, args: [name, input, expected], opts: opts}
    %{ctx | commands: ctx.commands ++ [command]}
  end

  def snapshot(server) do
    if function_exported?(server, :__spectre_server_tools__, 0),
      do: server.__spectre_server_tools__(),
      else: %{}
  end

  def adapter_modules(server) do
    server |> snapshot() |> Map.values() |> Enum.map(& &1.descriptor.adapter) |> Enum.uniq()
  end

  @spec scoped_adapter_modules(map()) :: MapSet.t(module())
  def scoped_adapter_modules(bindings) do
    for {_, %{scoped_only?: true, snapshot: %{descriptor: %{adapter: adapter}}}} <- bindings,
        into: MapSet.new(),
        do: adapter
  end

  def bindings!(state) do
    explicit =
      Map.new(snapshot(state.server), fn {name, expected} ->
        installation = installation!(state.agent, expected.installation_id)
        actual = Map.fetch!(Tools.table!([installation]), name)
        unless actual == expected, do: invalid!({:tool_contract_mismatch, name})
        validate_adapter!(expected.descriptor)
        validate_governed_bindings!(expected.descriptor, state.gam)
        {name, %{key: name, snapshot: expected, installation: installation}}
      end)

    Map.merge(scoped_bindings(state.agent), explicit)
  end

  defp scoped_bindings(agent) do
    with {:ok, %{stack: stack}} when not is_nil(stack) <- Spectre.Definition.fetch(agent),
         {:ok, definition} <- Definition.fetch(stack) do
      Enum.reduce(Tools.scoped_table!(definition.installations), %{}, fn
        {ref, %{key: key, snapshot: snapshot}}, bindings ->
          installation = installation!(agent, snapshot.installation_id)

          binding = %{
            key: key,
            snapshot: snapshot,
            installation: installation,
            scoped_only?: true
          }

          bindings |> Map.put(ref, binding) |> Map.put(key, binding)

        {ref, :ambiguous}, bindings ->
          Map.put(bindings, ref, :ambiguous)
      end)
    else
      _ -> %{}
    end
  end

  def normalize(
        state,
        %Command{kind: :call_tool, args: [{_, operation} = ref, input], opts: opts},
        event
      ) do
    case state.tool_bindings[ref] do
      %{key: key} ->
        binding = Map.fetch!(state.tool_bindings, key)
        normalize_request(state, binding, operation, input, opts, event, operation)

      unavailable ->
        reason =
          if unavailable == :ambiguous,
            do: :ambiguous_tool_operation,
            else: :unknown_tool_operation

        rejection(
          nil,
          Keyword.put_new(opts, :on_result, operation),
          {:tool_rejected, ref, operation, reason}
        )
    end
  end

  def normalize(state, %Command{kind: :tool, args: [name, input, expected], opts: opts}, event) do
    binding = Map.get(state.tool_bindings, name) || invalid!({:tool_not_registered, name})
    unless binding.snapshot == expected, do: invalid!({:tool_contract_mismatch, name})
    descriptor = binding.snapshot.descriptor
    {operation, payload} = selection(input, descriptor.default)
    normalize_request(state, binding, operation, payload, opts, event, name)
  end

  def normalize(_state, command, _event), do: {command, nil}

  defp normalize_request(state, binding, operation, payload, opts, event, tag) do
    validate_options!(opts)
    descriptor = binding.snapshot.descriptor
    validate_adapter!(descriptor)
    specification = Map.get(descriptor.operations, operation)
    validate_path_options!(specification, opts)
    tag = Keyword.get(opts, :on_result, tag)
    unless Checkpoint.validate_value(tag) == :ok, do: invalid!(:tool_result_tag_not_portable)

    unless Checkpoint.validate_value(Keyword.get(opts, :confirmation)) == :ok,
      do: invalid!(:tool_confirmation_not_portable)

    opts = Keyword.put(opts, :on_result, tag)
    origin = origin(binding, operation)

    prepared =
      cond do
        not ActivityBinding.allowed_tool?(state, {binding.snapshot.installation_id, operation}) ->
          {:error, :activity_tool_not_allowed}

        specification ->
          prepare(
            descriptor.adapter,
            operation,
            payload,
            binding,
            state.agent,
            event,
            specification
          )

        true ->
          {:error, :unknown_tool_operation}
      end

    case prepared do
      {:ok, args} -> normalized(specification, origin, args, opts)
      {:error, reason} -> rejected(origin, opts, reason)
    end
  end

  def invoke(state, identity, args, service_context) do
    binding = Map.fetch!(state.tool_bindings, identity.tool)
    descriptor = binding.snapshot.descriptor
    operation = identity.operation
    specification = Map.fetch!(descriptor.operations, operation)

    validate_identity!(binding, identity, specification)

    context = %{
      installation: binding.installation,
      service_context: service_context,
      config: binding.installation.config,
      checkpoint_ref: Checkpoint.tool_reference(state)
    }

    case Failure.capture(fn ->
           raw = descriptor.adapter.invoke(operation, args, context)
           descriptor.adapter.project(operation, raw)
         end) do
      {:ok, {:ok, result}} ->
        case Checkpoint.validate_value(result, max_bytes: specification.max_bytes) do
          :ok ->
            result

          {:error, reason} ->
            invocation_failure(
              identity,
              service_context,
              {:tool_result_not_portable, bounded(reason)}
            )
        end

      {:ok, {:error, reason}} ->
        invocation_failure(identity, service_context, {:tool_projection_failed, bounded(reason)})

      {:ok, _} ->
        invocation_failure(identity, service_context, :invalid_tool_projection)

      {:error, reason} ->
        invocation_failure(identity, service_context, {:tool_invocation_failed, bounded(reason)})
    end
  end

  defp invocation_failure(%{retry: :never} = identity, context, reason),
    do: unknown(identity, context.command_id, reason)

  defp invocation_failure(_identity, _context, reason), do: {:error, reason}

  def validate_persisted!(state) do
    migrated? = Map.get(state, :checkpoint_migrated, false)

    outbox =
      Map.new(state.outbox, fn {id, entry} ->
        {id, validate_entry!(state, entry, migrated?)}
      end)

    state |> Map.put(:outbox, outbox) |> Map.delete(:checkpoint_migrated)
  end

  defp validate_entry!(
         state,
         %{command: %Command{kind: :tool_call, args: [identity, _]}} = entry,
         migrated?
       ) do
    unless identity.retry in [:safe, :never], do: invalid!(:invalid_tool_retry)

    case matching_binding(state, identity) do
      nil ->
        changed_entry!(entry, migrated?, identity.tool)

      binding ->
        specification = Map.fetch!(binding.snapshot.descriptor.operations, identity.operation)
        validate_identity!(binding, identity, specification)
        entry
    end
  end

  defp validate_entry!(
         state,
         %{tool_origin: origin, command: %Command{kind: :propose, args: [host, _]}} = entry,
         migrated?
       ) do
    case matching_binding(state, origin) do
      nil ->
        changed_entry!(entry, migrated?, origin.tool)

      binding ->
        specification = Map.fetch!(binding.snapshot.descriptor.operations, origin.operation)

        unless specification.path == :governed and specification.operation == host,
          do: invalid!({:tool_contract_mismatch, origin.tool})

        entry
    end
  end

  defp validate_entry!(_state, entry, _migrated?), do: entry

  defp matching_binding(state, identity) do
    case Map.get(state.tool_bindings, identity.tool) do
      nil ->
        nil

      binding ->
        expected = origin(binding, identity.operation)
        if Map.delete(identity, :retry) == expected, do: binding
    end
  end

  defp changed_entry!(entry, migrated?, tool) do
    unless migrated? or Map.get(entry, :tool_contract_changed) == true,
      do: invalid!({:tool_contract_mismatch, tool})

    Map.put(entry, :tool_contract_changed, true)
  end

  defp validate_identity!(binding, identity, specification) do
    expected = origin(binding, identity.operation)

    unless specification.path == :cognitive and Map.get(specification, :retry) == identity.retry and
             expected == Map.delete(identity, :retry),
           do: invalid!({:tool_contract_mismatch, identity.tool})
  end

  def never?(%Command{kind: :tool_call, args: [%{retry: :never}, _]}), do: true
  def never?(_), do: false

  def unknown(identity, command_id, reason) do
    {:tool_unknown,
     %{
       command_id: command_id,
       tool: identity.tool,
       operation: identity.operation,
       reason: bounded(reason)
     }}
  end

  def bounded(reason) when is_atom(reason), do: reason
  def bounded(reason), do: inspect(reason, limit: 5, printable_limit: 256) |> String.slice(0, 512)

  defp prepare(adapter, operation, payload, binding, agent, event, specification) do
    trusted = %{
      agent: agent,
      routing:
        if(event, do: Map.take(event.routing, [:route_key, :scope, :protected]), else: %{}),
      config: binding.installation.config
    }

    case Failure.capture(fn -> adapter.prepare(operation, payload, trusted) end) do
      {:ok, {:ok, args}} -> validate_prepared(args, specification)
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _} -> {:error, :invalid_tool_preparation}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_prepared(args, %{path: :governed}) when not is_map(args),
    do: {:error, :governed_tool_arguments_must_be_map}

  defp validate_prepared(args, specification) do
    case Checkpoint.validate_value(args, max_bytes: specification.max_bytes) do
      :ok -> {:ok, args}
      {:error, reason} -> {:error, {:tool_arguments_not_portable, bounded(reason)}}
    end
  end

  defp normalized(%{path: :governed, operation: host_operation}, origin, args, opts) do
    command = %Command{kind: :propose, args: [host_operation, args], opts: opts}
    validated_command(command, origin)
  end

  defp normalized(%{path: :cognitive, retry: retry}, origin, args, opts) do
    identity = Map.put(origin, :retry, retry)
    command = %Command{kind: :tool_call, args: [identity, args], opts: opts}
    validated_command(command, origin)
  end

  defp validated_command(command, origin) do
    case Checkpoint.validate_value(command) do
      :ok ->
        {command, origin}

      {:error, reason} ->
        rejected(origin, command.opts, {:tool_command_not_portable, bounded(reason)})
    end
  end

  defp rejected(origin, opts, reason) do
    rejection(origin, opts, {:tool_rejected, origin.tool, origin.operation, bounded(reason)})
  end

  defp rejection(origin, opts, reason) do
    command = %Command{
      kind: :tool_rejected,
      args: [{:error, reason}],
      opts: Keyword.take(opts, [:on_result])
    }

    {command, origin}
  end

  defp origin(%{key: name, snapshot: snapshot} = binding, operation) do
    origin = %{
      tool: name,
      operation: bounded(operation),
      installation_id: snapshot.installation_id,
      descriptor_digest: snapshot.digest,
      installation_digest: snapshot.installation_digest
    }

    if Map.get(binding, :scoped_only?, false) do
      Map.put(origin, :adapter_digest, adapter_digest(snapshot.descriptor.adapter))
    else
      origin
    end
  end

  defp adapter_digest(module) do
    if Code.ensure_loaded?(module), do: Base.encode16(module.module_info(:md5), case: :lower)
  end

  defp selection(tuple, _default) when is_tuple(tuple) and tuple_size(tuple) > 0 do
    [operation | payload] = Tuple.to_list(tuple)
    {operation, payload}
  end

  defp selection(input, default), do: {default, input}

  defp validate_options!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- @public_options == [],
      do: invalid!(:invalid_tool_options)
  end

  defp validate_options!(_), do: invalid!(:invalid_tool_options)

  defp validate_path_options!(%{path: :governed}, opts) do
    if Keyword.has_key?(opts, :timeout), do: invalid!(:governed_timeout_owned_by_host)
  end

  defp validate_path_options!(%{path: :cognitive}, opts) do
    if Keyword.has_key?(opts, :confirmation),
      do: invalid!(:cognitive_tool_confirmation_not_supported)
  end

  defp validate_path_options!(_, _), do: :ok

  defp installation!(agent, id) do
    case Binding.installation(agent, id) do
      {:ok, installation} -> installation
      {:error, reason} -> invalid!(reason)
    end
  end

  defp validate_adapter!(descriptor) do
    module = descriptor.adapter
    required = [prepare: 3, project: 2]

    required =
      if Enum.any?(descriptor.operations, fn {_, operation} -> operation.path == :cognitive end),
        do: [{:invoke, 3} | required],
        else: required

    unless Code.ensure_loaded?(module) and
             Enum.all?(required, fn {function, arity} ->
               function_exported?(module, function, arity)
             end),
           do: invalid!({:invalid_tool_adapter, module})
  end

  defp validate_governed_bindings!(descriptor, gam) do
    for {_name, %{path: :governed, operation: operation}} <- descriptor.operations,
        do: validate_governed_binding!(gam, operation)
  end

  @spec validate_governed_binding!(term(), term()) :: :ok
  defp validate_governed_binding!({Spectre.Server.GAM.Managed, config}, _operation)
       when is_list(config) do
    # Installation exposes a helper, not authority to execute every operation.
    # Managed validates enabled effects at bootstrap and records a rejection
    # if a callback later proposes an operation outside that immutable allowlist.
    _server = Keyword.fetch!(config, :server)
    :ok
  end

  defp validate_governed_binding!({Spectre.Server.GAM, config}, operation) when is_list(config) do
    binding = config |> Keyword.get(:bindings, %{}) |> Map.get(operation)
    validate_candidate!(binding, operation)
  end

  defp validate_governed_binding!(_gam, operation),
    do: invalid!({:governed_tool_requires_standard_gam_bridge, operation})

  defp validate_candidate!(%{candidate: {module, function}}, operation)
       when is_atom(module) and is_atom(function) do
    unless Code.ensure_loaded?(module) and function_exported?(module, function, 3),
      do: invalid!({:invalid_governed_tool_binding, operation})
  end

  defp validate_candidate!(_, operation),
    do: invalid!({:unbound_governed_tool_operation, operation})

  defp invalid!(reason), do: raise(ArgumentError, "invalid Server tool: #{inspect(reason)}")
end
