defmodule Spectre.Prompt.Predicate do
  @moduledoc false

  alias Spectre.Input
  alias Spectre.Operation.Registry
  alias Spectre.Operation.Spec
  alias Spectre.Provider.Call

  @spec ref_data(term()) :: {:ok, map()} | {:error, term()}
  def ref_data(ref) when is_atom(ref) and not is_nil(ref),
    do: {:ok, %{"predicate_ref" => Atom.to_string(ref)}}

  def ref_data(ref) when is_binary(ref) and ref != "", do: {:ok, %{"predicate_ref" => ref}}
  def ref_data(ref), do: {:error, {:invalid_prompt_predicate_ref, ref}}

  @spec validate_ref(module(), map()) :: :ok | {:error, term()}
  def validate_ref(agent, condition_ref) do
    with {:ok, ref} <- parse_ref(condition_ref),
         {:ok, %Spec{} = spec} <- Registry.resolve_spec(agent, ref),
         true <- Registry.predicate_spec?(spec) do
      :ok
    else
      false -> {:error, {:prompt_condition_not_pure_boolean, condition_ref}}
      {:error, _reason} = error -> error
    end
  end

  @spec evaluate(nil | map(), Input.t(), map(), keyword()) ::
          {:ok, boolean(), map()} | {:error, term()}
  def evaluate(nil, %Input{}, _context, _opts), do: {:ok, true, %{}}

  def evaluate(condition_ref, %Input{} = input, context, opts)
      when is_map(context) and is_list(opts) do
    with agent when is_atom(agent) and not is_nil(agent) <- Keyword.get(opts, :agent),
         {:ok, ref} <- parse_ref(condition_ref),
         {:ok, %Spec{} = spec} <- Registry.resolve_spec(agent, ref),
         true <- Registry.predicate_spec?(spec),
         {:ok, result} <- invoke(spec, input, context),
         true <- is_boolean(result) do
      {:ok, result, %{"predicate_ref" => stable_ref(spec.id), "matched" => result}}
    else
      nil -> {:error, :prompt_predicate_registry_required}
      false -> {:error, {:prompt_predicate_returned_non_boolean, condition_ref}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_ref(%{"predicate_ref" => ref}) when is_binary(ref) and ref != "", do: {:ok, ref}
  defp parse_ref(%{predicate_ref: ref}) when is_binary(ref) and ref != "", do: {:ok, ref}
  defp parse_ref(value), do: {:error, {:invalid_prompt_predicate_ref, value}}

  defp invoke(%Spec{} = spec, input, context) do
    payload = %{input: %{text: input.text, meta: input.meta}, context: context}

    Call.run(
      :prompt,
      fn -> normalize_reply(call_executor(spec.executor, payload, context, spec.id)) end,
      run_timeout: spec.timeout,
      purpose: :prompt_condition
    )
  end

  defp call_executor({module, function}, payload, context, id),
    do: call_executor(module, function, payload, context, id)

  defp call_executor(module, payload, context, id) when is_atom(module),
    do: call_executor(module, :execute, payload, context, id)

  defp call_executor(module, function, payload, context, id) do
    cond do
      not Code.ensure_loaded?(module) -> {:error, {:prompt_predicate_not_loaded, id}}
      function_exported?(module, function, 2) -> apply(module, function, [payload, context])
      function_exported?(module, function, 1) -> apply(module, function, [payload])
      true -> {:error, {:prompt_predicate_callback_missing, id}}
    end
  end

  defp normalize_reply({:ok, value}), do: {:ok, value}
  defp normalize_reply({:error, _reason} = error), do: error
  defp normalize_reply(value), do: {:ok, value}

  defp stable_ref(value) when is_atom(value), do: Atom.to_string(value)
  defp stable_ref(value), do: value
end
