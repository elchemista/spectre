defmodule Spectre.Router.Rule do
  @moduledoc """
  Portable routing declaration. `to` names a Candidate template; `match` maps
  method identifiers to method-specific data. Neither is an admission decision.
  Regex structs are lowered to source/options before entering a Definition.
  """

  alias Spectre.Portable

  @enforce_keys [:ref, :to, :match]
  defstruct [:ref, :to, :match]
  @type t :: %__MODULE__{ref: String.t(), to: String.t(), match: map()}

  @doc "Validates one named rule and normalizes its method identifiers."
  @spec new(String.t(), term()) :: {:ok, t()} | {:error, term()}
  def new(ref, attrs) do
    with :ok <- path(ref),
         {:ok, attrs} <- Portable.normalize_attrs(attrs, [:to, :match], :router_rule),
         :ok <- path(Map.get(attrs, :to)),
         {:ok, match} <- normalize_match(Map.get(attrs, :match)) do
      {:ok, %__MODULE__{ref: ref, to: attrs.to, match: match}}
    end
  end

  @doc "Returns the canonical rule body; its name is the surrounding map key."
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = rule), do: %{"to" => rule.to, "match" => rule.match}

  @doc false
  def path(name) when is_binary(name) and name != "" do
    if Enum.all?(:binary.split(name, "/", [:global]), &(&1 != "")),
      do: :ok,
      else: {:error, {:invalid_declaration_path, name}}
  end

  def path(name), do: {:error, {:invalid_declaration_path, name}}

  @doc false
  def method(id) when is_atom(id) and id not in [nil, true, false], do: method(Atom.to_string(id))
  def method(id) when is_binary(id) and id != "", do: {:ok, id}
  def method(_id), do: {:error, :invalid_router_method}

  defp normalize_match(match) when is_map(match) and not is_struct(match),
    do: normalize_pairs(Map.to_list(match))

  defp normalize_match(match) when is_list(match) do
    if Keyword.keyword?(match), do: normalize_pairs(match), else: {:error, :invalid_router_match}
  end

  defp normalize_match(_match), do: {:error, :invalid_router_match}

  defp normalize_pairs([]), do: {:error, :empty_router_match}

  defp normalize_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {raw_id, raw_data}, {:ok, acc} ->
      with {:ok, id} <- method(raw_id),
           false <- Map.has_key?(acc, id),
           {:ok, data} <- match_data(raw_data) do
        {:cont, {:ok, Map.put(acc, id, data)}}
      else
        true -> {:halt, {:error, :duplicate_router_method}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp match_data(%Regex{} = regex),
    do: {:ok, %{"source" => Regex.source(regex), "options" => Regex.opts(regex)}}

  defp match_data(data), do: Portable.stringify_atom_keys(data)
end
