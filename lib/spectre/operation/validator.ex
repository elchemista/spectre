defmodule Spectre.Operation.Validator do
  @moduledoc """
  Safe validation boundary for registered operation input, output and updates.

  Validators declared on an operation spec may be primitive type atoms
  (`:map`, `:binary`, …), a module exporting `validate/1`, or an explicit
  `{module, function}` pair. Custom validators are invoked defensively: a
  missing module, a raise or a throw becomes a tagged `{:error, reason}`
  instead of crashing the caller.
  """

  @primitive [:any, :map, :list, :binary, :integer, :number, :atom, :boolean]

  @doc """
  Validates `value` against a declared validator.

  A `nil` validator accepts everything. Custom validators may reply with
  `:ok`, `true`, `{:ok, _}`, `false` or `{:error, reason}`; any other reply
  is reported as `{:error, {:invalid_operation_validation_reply, ...}}`.
  """
  @spec validate(term(), term(), term()) :: :ok | {:error, term()}
  def validate(nil, _value, _field), do: :ok
  def validate(:any, _value, _field), do: :ok
  def validate(:map, value, _field) when is_map(value), do: :ok
  def validate(:list, value, _field) when is_list(value), do: :ok
  def validate(:binary, value, _field) when is_binary(value), do: :ok
  def validate(:integer, value, _field) when is_integer(value), do: :ok
  def validate(:number, value, _field) when is_number(value), do: :ok
  def validate(:atom, value, _field) when is_atom(value) and not is_nil(value), do: :ok
  def validate(:boolean, value, _field) when is_boolean(value), do: :ok

  def validate(type, value, field) when type in @primitive,
    do: {:error, {:invalid_operation_value, field, type, shape(value)}}

  def validate({module, function}, value, field)
      when is_atom(module) and is_atom(function) do
    invoke(module, function, value, field)
  end

  def validate(module, value, field) when is_atom(module) and not is_nil(module) do
    invoke(module, :validate, value, field)
  end

  def validate(validator, _value, field),
    do: {:error, {:invalid_operation_validator, field, validator}}

  @doc """
  Checks that `value` belongs to a declared domain of allowed values.

  A `nil` domain accepts everything.
  """
  @spec domain([term()] | nil, term(), term()) :: :ok | {:error, term()}
  def domain(nil, _value, _field), do: :ok

  def domain(values, value, field) when is_list(values) do
    if value in values,
      do: :ok,
      else: {:error, {:operation_value_outside_domain, field, value}}
  end

  @spec invoke(module(), atom(), term(), term()) :: :ok | {:error, term()}
  defp invoke(module, function, value, field) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:operation_validator_not_loaded, field, module}}

      not function_exported?(module, function, 1) ->
        {:error, {:operation_validator_missing, field, module, function}}

      true ->
        normalize(apply(module, function, [value]), field)
    end
  rescue
    error -> {:error, {:operation_validator_exception, field, module, function, error.__struct__}}
  catch
    kind, reason ->
      {:error, {:operation_validator_failure, field, module, function, kind, reason}}
  end

  @spec normalize(term(), term()) :: :ok | {:error, term()}
  defp normalize(:ok, _field), do: :ok
  defp normalize(true, _field), do: :ok
  defp normalize({:ok, _value}, _field), do: :ok
  defp normalize(false, field), do: {:error, {:operation_validation_failed, field}}

  defp normalize({:error, reason}, field),
    do: {:error, {:operation_validation_failed, field, reason}}

  defp normalize(other, field),
    do: {:error, {:invalid_operation_validation_reply, field, shape(other)}}

  @spec shape(term()) :: atom() | {:tuple, non_neg_integer()}
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_integer(value), do: :integer
  defp shape(value) when is_number(value), do: :number
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: {:tuple, tuple_size(value)}
  defp shape(_value), do: :other
end
