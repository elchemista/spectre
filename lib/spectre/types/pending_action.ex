defmodule Spectre.PendingAction do
  @moduledoc """
  Planned action that has not crossed the execution boundary.

  Pending actions can come from deterministic DSL handlers, extracted Action
  Language, or manual host code. The struct keeps those sources normalized so
  protection checks and execution dispatch use one shape.

      pending =
        Spectre.PendingAction.new(%{
          name: :delete_account,
          args: %{reason: "user requested"},
          source: :dsl
        })
  """

  defstruct [
    :id,
    :name,
    :selected_tool,
    :al,
    :source,
    args: %{},
    status: :staged,
    policy: nil,
    hooks: [],
    created_at: nil,
    raw: nil
  ]

  @type t :: %__MODULE__{
          id: term(),
          name: atom() | nil,
          selected_tool: String.t() | nil,
          al: String.t() | nil,
          source: :al | :dsl | :manual,
          args: map(),
          status: atom(),
          policy: atom() | nil,
          hooks: [map()],
          created_at: DateTime.t() | nil,
          raw: term()
        }

  @doc """
  Builds a pending action from planner output or fallback AL metadata.

      Spectre.PendingAction.new(%{selected_tool: "Elixir.MyApp.Tools.delete/2"})
  """
  @spec new(map() | struct()) :: t()
  def new(action) when is_map(action) do
    selected_tool = get_attr(action, :selected_tool)
    al = get_attr(action, :al)

    %__MODULE__{
      id: get_attr(action, :id) || System.unique_integer([:positive]),
      name: normalize_name(get_attr(action, :name), selected_tool, al),
      selected_tool: selected_tool,
      al: al,
      source: get_attr(action, :source) || infer_source(selected_tool, al),
      args: get_attr(action, :args) || %{},
      status: get_attr(action, :status) || :staged,
      policy: get_attr(action, :policy),
      hooks: get_attr(action, :hooks) || [],
      created_at: get_attr(action, :created_at) || DateTime.utc_now(),
      raw: action
    }
  end

  @doc """
  Returns the most stable key available for protection and dispatch checks.

      :delete_account = Spectre.PendingAction.action_key(pending)
  """
  @spec action_key(t() | map() | atom() | String.t()) :: atom() | String.t() | nil
  def action_key(%__MODULE__{name: name}) when is_atom(name), do: name
  def action_key(%__MODULE__{selected_tool: tool}) when is_binary(tool), do: tool
  def action_key(%{name: name}) when is_atom(name), do: name
  def action_key(%{selected_tool: tool}) when is_binary(tool), do: tool
  def action_key(name) when is_atom(name), do: name
  def action_key(name) when is_binary(name), do: name
  def action_key(_other), do: nil

  @spec normalize_name(term(), String.t() | nil, String.t() | nil) :: atom() | nil
  defp normalize_name(name, _selected_tool, _al) when is_atom(name) and not is_nil(name), do: name
  defp normalize_name(_name, selected_tool, al), do: infer_name(selected_tool, al)

  @spec infer_name(String.t() | nil, String.t() | nil) :: atom() | nil
  defp infer_name(selected_tool, _al) when is_binary(selected_tool) do
    selected_tool
    |> String.replace_prefix("Elixir.", "")
    |> String.split(".")
    |> List.last()
    |> case do
      nil -> nil
      fun_arity -> fun_arity |> String.split("/") |> hd() |> existing_atom()
    end
  end

  defp infer_name(_selected_tool, al) when is_binary(al) do
    al
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join("_", &String.downcase/1)
    |> String.replace(~r/[^a-z0-9_]/, "")
    |> case do
      "" -> nil
      name -> existing_atom(name)
    end
  end

  defp infer_name(_selected_tool, _al), do: nil

  @spec infer_source(String.t() | nil, String.t() | nil) :: :al | :manual
  defp infer_source(selected_tool, al) when is_binary(selected_tool) or is_binary(al), do: :al
  defp infer_source(_selected_tool, _al), do: :manual

  @spec get_attr(map(), atom()) :: term()
  defp get_attr(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  @spec existing_atom(String.t()) :: atom() | nil
  defp existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
