defmodule Spectre.Stack.DSL do
  @moduledoc """
  Parser helper for package-local Stack declarations.

  Stack keeps package blocks as unexpanded AST. An installable package calls
  this helper with its own closed vocabulary and receives evaluated arguments
  without importing package verbs into the Stack or Agent namespace.
  """

  @type arities :: non_neg_integer() | [non_neg_integer()] | Range.t()

  @doc """
  Compiles a package block into ordered `{form, arguments}` entries.
  """
  @spec compile!(Macro.t() | nil, Macro.Env.t(), keyword(arities())) ::
          [{atom(), [term()]}]
  def compile!(nil, %Macro.Env{}, allowed) when is_list(allowed), do: []

  def compile!(block, %Macro.Env{} = caller, allowed) when is_list(allowed) do
    allowed = Map.new(allowed)

    block
    |> calls()
    |> Enum.map(&compile_call!(&1, caller, allowed))
  end

  @spec compile_call!(Macro.t(), Macro.Env.t(), map()) :: {atom(), [term()]}
  defp compile_call!({name, _meta, args} = call, caller, allowed)
       when is_atom(name) and is_list(args) do
    arity = length(args)

    case Map.fetch(allowed, name) do
      {:ok, arities} ->
        unless accepted_arity?(arity, arities) do
          raise ArgumentError,
                "invalid #{name}/#{arity} declaration in Stack package DSL"
        end

        {name, Enum.map(args, &evaluate!(&1, caller))}

      :error ->
        raise ArgumentError,
              "unknown Stack package declaration: #{Macro.to_string(call)}"
    end
  end

  defp compile_call!(call, _caller, _allowed) do
    raise ArgumentError, "invalid Stack package declaration: #{Macro.to_string(call)}"
  end

  @spec accepted_arity?(non_neg_integer(), arities()) :: boolean()
  defp accepted_arity?(arity, accepted) when is_integer(accepted), do: arity == accepted
  defp accepted_arity?(arity, %Range{} = accepted), do: arity in accepted
  defp accepted_arity?(arity, accepted) when is_list(accepted), do: arity in accepted

  @spec evaluate!(Macro.t(), Macro.Env.t()) :: term()
  defp evaluate!(ast, caller) do
    expanded = Macro.prewalk(ast, &Macro.expand(&1, caller))
    {value, _binding} = Code.eval_quoted(expanded, [], caller)
    value
  end

  @spec calls(Macro.t()) :: [Macro.t()]
  defp calls({:__block__, _meta, calls}), do: calls
  defp calls(one), do: [one]
end
