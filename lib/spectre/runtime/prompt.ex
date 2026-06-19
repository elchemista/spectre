defmodule Spectre.Prompt do
  @moduledoc """
  Prompt resolver and tiny HEEx-compatible renderer.

  Prompt resolution is filesystem-boundary code. Runtime modules pass prompt
  names and assigns; this module maps them to files under the agent prompt root
  and renders a small HEEx-like template syntax.
  """

  @doc """
  Resolves and renders a prompt for an agent turn.

      {:ok, text} = Spectre.Prompt.render(MyAgent, :welcome, ctx)
  """
  @spec render(module(), atom() | String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def render(agent, prompt, ctx, opts \\ []) do
    with {:ok, path} <- resolve(agent, prompt, ctx, opts),
         {:ok, text} <- File.read(path) do
      assigns = assigns(ctx, opts)
      {:ok, eval_heexish(text, assigns, path)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Resolves a prompt name or relative path under the agent prompt root.

      {:ok, path} = Spectre.Prompt.resolve(MyAgent, :welcome, ctx)

  Policy prompts are looked up under `policies/<policy>/<prompt>.text.heex` so
  confirmation copy can live next to the policy it explains.
  """
  @spec resolve(module(), atom() | String.t(), Spectre.Context.t() | map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve(agent, prompt, ctx, opts \\ []) do
    root = agent.__spectre_prompt_root__()
    policy = Keyword.get(opts, :policy) || active_policy(ctx)

    relative =
      cond do
        Keyword.get(opts, :policy_prompt?) && policy && is_atom(prompt) ->
          Path.join(["policies", to_string(policy), "#{prompt}.text.heex"])

        is_atom(prompt) ->
          "#{prompt}.text.heex"

        is_binary(prompt) ->
          prompt
      end

    path = Path.expand(relative, root)

    if File.exists?(path) do
      {:ok, path}
    else
      {:error, {:missing_prompt, path}}
    end
  end

  @spec active_policy(Spectre.Context.t() | map()) :: atom() | nil
  defp active_policy(%{state: %Spectre.State{} = state}) do
    case Spectre.State.open_policy_awaitable(state) do
      %Spectre.Awaitable{name: policy} -> policy
      nil -> nil
    end
  end

  defp active_policy(_ctx), do: nil

  @spec assigns(Spectre.Context.t() | map(), keyword()) :: map()
  defp assigns(%{input: input, state: state} = ctx, opts) do
    base =
      ctx
      |> Map.get(:assigns, %{})
      |> Map.merge(%{
        input: input,
        state: state,
        ctx: ctx,
        recent_chat: Keyword.get(opts, :recent_chat, Map.get(ctx, :recent_chat, "none")),
        memory: Map.get(ctx, :memory)
      })

    Map.merge(base, Keyword.get(opts, :assigns, %{}))
  end

  @spec eval_heexish(String.t(), map(), String.t()) :: String.t()
  defp eval_heexish(text, assigns, file) do
    text
    |> rewrite_assigns()
    |> EEx.eval_string([assigns: assigns], file: file)
  end

  @spec rewrite_assigns(String.t()) :: String.t()
  defp rewrite_assigns(text) do
    Regex.replace(~r/<%(=)?(.*?)%>/s, text, fn _full, equals, code ->
      marker = if equals == "=", do: "<%=", else: "<%"
      "#{marker}#{rewrite_assigns_in_code(code)}%>"
    end)
  end

  @spec rewrite_assigns_in_code(String.t()) :: String.t()
  defp rewrite_assigns_in_code(code) do
    Regex.replace(~r/@([a-zA-Z_][a-zA-Z0-9_]*)/, code, fn _full, key ->
      "Map.get(var!(assigns), :#{key})"
    end)
  end
end
