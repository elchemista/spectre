defmodule Spectre.Server.Contracts do
  @moduledoc """
  Optional application contracts expressed as ordinary Server callbacks.

  `assigns_schema/0` returns nil or a field map. Fields are required unless their
  type is `{:optional, type}`; undeclared assigns remain permitted. Types are
  `:any`, `:string`, `:integer`, `:number`, `:boolean`, `:atom`, `:map`, `:list`,
  `{:enum, values}`, `{:list, type}`, `{:map, fields}`, `{:tuple, types}` and
  `{:one_of, types}` for alternative result shapes.

  `continuation_contracts/0` returns nil or a map from explicit `on_result` tags
  to these same schemas. Use tuple and enum types to describe tagged results.
  A declared empty map rejects all explicit continuation tags. Built-in implicit
  callbacks remain available. These checks do not prove arbitrary Elixir handler
  exhaustiveness or infer contracts from catch-all clauses.
  """
  alias Spectre.Flow.Port, as: FlowPort
  alias Spectre.Server.{Command, ContractError}

  @type schema ::
          atom()
          | {:optional, schema()}
          | {:enum, [term()]}
          | {:list, schema()}
          | {:map, map()}
          | {:tuple, [schema()]}
          | {:one_of, [schema()]}

  @doc "Validates contract declarations before starting application work."
  @spec validate_configuration!(module()) :: :ok
  def validate_configuration!(server) do
    for callback <- [:assigns_schema, :continuation_contracts] do
      case declaration(server, callback) do
        nil ->
          :ok

        fields when is_map(fields) and not is_struct(fields) ->
          Enum.each(fields, &validate_field!(&1, callback))

        _ ->
          raise ArgumentError, "#{callback} must return nil or a map"
      end
    end

    :ok
  end

  defp validate_field!({key, type}, callback) do
    unless is_atom(key) and valid_type?(type),
      do: raise(ArgumentError, "invalid #{callback} declaration")
  end

  @doc "Checks application assigns without returning values in diagnostics."
  @spec validate_assigns(module(), map()) :: :ok | {:error, map()}
  def validate_assigns(server, assigns) do
    case declaration(server, :assigns_schema) do
      nil -> :ok
      fields -> check({:map, fields}, assigns, [])
    end
  end

  @doc false
  @spec validate_assigns!(module(), map()) :: :ok
  def validate_assigns!(server, assigns) do
    case validate_assigns(server, assigns) do
      :ok -> :ok
      {:error, details} -> raise ContractError, details: Map.put(details, :contract, :assigns)
    end
  end

  @doc false
  @spec validate_commands!(module(), [Command.t()]) :: :ok
  def validate_commands!(server, commands) do
    contracts = declaration(server, :continuation_contracts)

    if is_map(contracts) do
      Enum.each(commands, &validate_command!(&1, contracts))
    end

    :ok
  end

  defp validate_command!(command, contracts) do
    case Keyword.fetch(command.opts, :on_result) do
      {:ok, tag} ->
        unless Map.has_key?(contracts, tag),
          do:
            raise(ContractError,
              details: %{contract: :continuation, reason: :undeclared_tag, tag: safe_tag(tag)}
            )

      :error ->
        :ok
    end
  end

  @doc false
  @spec validate_result!(module(), term(), term(), map()) :: :ok
  def validate_result!(server, tag, result, correlation) do
    contracts = declaration(server, :continuation_contracts)

    case is_map(contracts) && Map.fetch(contracts, tag) do
      {:ok, type} ->
        case check(type, result, []) do
          :ok ->
            :ok

          {:error, details} ->
            details = Map.merge(details, %{contract: :continuation, tag: safe_tag(tag)})
            raise ContractError, details: Map.merge(details, correlation)
        end

      _ ->
        :ok
    end
  end

  @doc "Checks retained explicit continuations before recovery or a hot upgrade."
  @spec validate_retained(module(), map()) :: :ok | {:error, map()}
  def validate_retained(server, retained) do
    validate_retained!(server, retained)
  rescue
    error in ContractError -> {:error, error.details}
  end

  @doc false
  @spec validate_retained!(module(), map()) :: :ok
  def validate_retained!(server, retained) do
    if is_map(declaration(server, :continuation_contracts)) do
      for {_id, entry} <- Map.get(retained, :outbox, %{}),
          do: validate_retained_entry!(server, entry)

      for {_id, entry} <- Map.get(retained, :inbox, %{}),
          do: validate_retained_worker!(server, Map.get(entry, :worker, %{}))

      for {_id, worker} <- Map.get(retained, :workers, %{}),
          do: validate_retained_worker!(server, worker)

      for {_id, pending} <- Map.get(retained, :pending, %{}),
          do: validate_retained_pending!(server, retained, pending)
    end

    :ok
  end

  defp validate_retained_pending!(server, retained, pending) do
    source = get_in(retained, [:operations, Map.get(pending, :command_id)])
    if is_map(source), do: validate_retained_entry!(server, source)

    # Older reply waits used their ID as the implicit tag. Consent waits
    # without provenance are checked through their retained source above.
    explicit =
      Map.get(
        pending,
        :explicit_on_result,
        Map.get(pending, :kind) == :reply and
          Map.get(pending, :on_result) != Map.get(pending, :id)
      )

    owner = continuation_owner(server, Map.get(pending, :origin))
    if explicit, do: validate_tag!(owner, Map.get(pending, :on_result))
  end

  @spec validate_retained_entry!(module(), map()) :: :ok
  defp validate_retained_entry!(server, %{command: %Command{opts: opts}} = entry) do
    explicit =
      Map.get(
        entry,
        :explicit_on_result,
        not Map.has_key?(entry, :tool_origin) and Keyword.has_key?(opts, :on_result)
      )

    owner = continuation_owner(server, Map.get(entry, :event))
    if explicit, do: validate_tag!(owner, Keyword.get(opts, :on_result)), else: :ok
  end

  defp validate_retained_entry!(_server, _entry), do: :ok

  @spec validate_retained_worker!(module(), map()) :: :ok
  defp validate_retained_worker!(server, worker) do
    opts = Map.get(worker, :opts, [])

    explicit =
      Map.get(
        worker,
        :explicit_on_result,
        Map.get(worker, :kind) != :tool and Keyword.has_key?(opts, :on_result)
      )

    owner = continuation_owner(server, Map.get(worker, :event))
    if explicit, do: validate_tag!(owner, Map.get(worker, :tag)), else: :ok
  end

  defp continuation_owner(server, %{routing: %{route: route}}) do
    case FlowPort.owner(route) do
      {_, _, module} -> module
      nil -> server
    end
  end

  defp continuation_owner(server, _event), do: server

  @spec validate_tag!(module(), term()) :: :ok
  defp validate_tag!(server, tag),
    do: validate_commands!(server, [%Command{kind: :generate, args: [], opts: [on_result: tag]}])

  @spec declaration(module(), atom()) :: nil | map()
  defp declaration(server, callback) do
    if function_exported?(server, callback, 0), do: apply(server, callback, []), else: nil
  end

  @spec valid_type?(term()) :: boolean()
  defp valid_type?(type)
       when type in [:any, :string, :integer, :number, :boolean, :atom, :map, :list], do: true

  defp valid_type?({:optional, type}), do: valid_type?(type)
  defp valid_type?({:list, type}), do: valid_type?(type)

  defp valid_type?({:enum, values}) when is_list(values),
    do: Enum.all?(values, &(is_atom(&1) or is_number(&1)))

  defp valid_type?({:one_of, types}) when is_list(types) and types != [],
    do: Enum.all?(types, &valid_type?/1)

  defp valid_type?({:tuple, types}) when is_list(types), do: Enum.all?(types, &valid_type?/1)

  defp valid_type?({:map, fields}) when is_map(fields) and not is_struct(fields),
    do: Enum.all?(fields, fn {key, type} -> is_atom(key) and valid_type?(type) end)

  defp valid_type?(_), do: false

  @spec check(schema(), term(), list()) :: :ok | {:error, map()}
  defp check({:optional, type}, value, path), do: check(type, value, path)
  defp check({:enum, values} = type, value, path), do: matched(value in values, type, value, path)

  defp check({:one_of, types} = type, value, path) do
    matched(Enum.any?(types, &(check(&1, value, path) == :ok)), type, value, path)
  end

  defp check({:map, fields}, value, path) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(fields, :ok, fn {key, type}, :ok ->
      result = check_field(value, key, type, path)

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp check({:list, type}, value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
      case check(type, item, path ++ [index]) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check({:tuple, types} = type, value, path) when is_tuple(value) do
    if tuple_size(value) == length(types) do
      Enum.zip(types, Tuple.to_list(value))
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {{item_type, item}, index}, :ok ->
        check_item(item_type, item, path ++ [index])
      end)
    else
      matched(false, type, value, path)
    end
  end

  defp check(:any, _value, _path), do: :ok
  defp check(:string, value, _path) when is_binary(value), do: :ok
  defp check(:integer, value, _path) when is_integer(value), do: :ok
  defp check(:number, value, _path) when is_number(value), do: :ok
  defp check(:boolean, value, _path) when is_boolean(value), do: :ok
  defp check(:atom, value, _path) when is_atom(value), do: :ok
  defp check(:map, value, _path) when is_map(value) and not is_struct(value), do: :ok
  defp check(:list, value, _path) when is_list(value), do: :ok
  defp check(type, value, path), do: matched(false, type, value, path)

  defp check_item(type, value, path) do
    case check(type, value, path) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp check_field(value, key, type, path) do
    case Map.fetch(value, key) do
      {:ok, item} -> check(type, item, path ++ [key])
      :error -> missing_field(type, path ++ [key])
    end
  end

  defp missing_field({:optional, _}, _path), do: :ok
  defp missing_field(_type, path), do: {:error, %{path: path, reason: :missing_field}}

  @spec matched(boolean(), schema(), term(), list()) :: :ok | {:error, map()}
  defp matched(true, _, _, _), do: :ok

  defp matched(false, type, value, path),
    do: {:error, %{path: path, reason: :type_mismatch, expected: type, received: shape(value)}}

  @spec shape(term()) :: atom()
  defp shape(value) when is_binary(value), do: :string
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_number(value), do: :number
  defp shape(_), do: :other

  @spec safe_tag(term()) :: atom()
  defp safe_tag(tag) when is_atom(tag), do: tag
  defp safe_tag(_), do: :non_atom_tag
end
