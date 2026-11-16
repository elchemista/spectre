defmodule Spectre.Server.PublicProjection do
  @moduledoc """
  Optional incremental projection of a planning stream into public text.

  Configure `public_projection: Module` or `{Module, options}` on generation.
  The host vouches for this adapter's public projection. It receives complete
  UTF-8 after the core structural sanitizer; it must never expose instructions,
  control data or internal reasoning, and its output must be consistent with
  the terminal public result. Raw provider output remains separate for final
  plan consolidation. This port never executes a proposal.
  """
  @callback init(keyword()) :: {:ok, term()} | {:error, term()}
  @callback push(binary(), term()) :: {:ok, binary(), term()} | {:error, term()}
  @callback finish(term()) :: {:ok, binary()} | {:error, term()}

  def open(nil), do: {:ok, nil}
  def open(module) when is_atom(module), do: open({module, []})

  def open({module, opts}) when is_atom(module) and is_list(opts) do
    if Keyword.keyword?(opts) and Code.ensure_loaded?(module) and
         Enum.all?([init: 1, push: 2, finish: 1], fn {name, arity} ->
           function_exported?(module, name, arity)
         end) do
      case module.init(opts) do
        {:ok, state} -> {:ok, {module, state}}
        {:error, _} = error -> error
        _ -> {:error, :invalid_public_projection_init}
      end
    else
      {:error, :invalid_public_projection}
    end
  end

  def open(_), do: {:error, :invalid_public_projection}

  def push(nil, text), do: {:ok, text, nil}

  def push({module, state}, text) do
    case module.push(text, state) do
      {:ok, public, next} when is_binary(public) ->
        if String.valid?(public),
          do: {:ok, public, {module, next}},
          else: {:error, :invalid_public_projection_utf8}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_public_projection_reply}
    end
  end

  def finish(nil), do: {:ok, ""}

  def finish({module, state}) do
    case module.finish(state) do
      {:ok, public} when is_binary(public) ->
        if String.valid?(public),
          do: {:ok, public},
          else: {:error, :invalid_public_projection_utf8}

      {:error, _} = error ->
        error

      _ ->
        {:error, :invalid_public_projection_reply}
    end
  end
end
