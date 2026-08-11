defmodule Spectre.Morph.DSL do
  @moduledoc """
  Declares the closed proposal surface of a compiled Agent.

      morph(
        may_propose: [:mount_skill, :replace_skill, :disable_skill],
        within: [scopes: [:agent], prompt_tokens: 512],
        approval: :human
      )

  The declaration is lowered into a must-understand canonical component. It
  cannot grant authority: it only narrows what `Spectre.Morph` may submit to
  the normal governance pipeline.
  """

  alias Spectre.Morph.Surface

  @doc """
  Declares the immutable proposal ceiling of the current Agent.

  `:may_propose` accepts only `:mount_skill`, `:replace_skill`, and
  `:disable_skill`. The `:within` keyword requires non-empty `:scopes` and a
  positive `:prompt_tokens` ceiling. `:approval` is either `:human` or
  `:host_policy`; it never delegates approval authority to the Agent.
  """
  @spec morph(keyword()) :: Macro.t()
  defmacro morph(opts) do
    surface = build!(opts, __CALLER__)
    module = __CALLER__.module

    if Module.get_attribute(module, :spectre_change_surface) do
      raise ArgumentError, "morph may be declared only once"
    end

    Module.put_attribute(module, :spectre_change_surface, surface)

    quote do
      :ok
    end
  end

  @doc false
  @spec build!(Macro.t(), Macro.Env.t()) :: Surface.t()
  def build!(opts, caller) do
    opts = Macro.expand(opts, caller)

    unless Keyword.keyword?(opts) do
      raise ArgumentError, "morph expects a keyword list, got: #{inspect(opts)}"
    end

    unless unique_keyword?(opts) do
      raise ArgumentError, "morph does not accept duplicate options"
    end

    unknown = Keyword.keys(opts) -- [:may_propose, :within, :approval]

    if unknown != [] do
      raise ArgumentError, "morph received unknown options: #{inspect(unknown)}"
    end

    within = Keyword.get(opts, :within)

    unless Keyword.keyword?(within) and unique_keyword?(within) do
      raise ArgumentError,
            "morph :within must be a keyword list with :scopes and :prompt_tokens"
    end

    unknown_within = Keyword.keys(within) -- [:scopes, :prompt_tokens]

    if unknown_within != [] do
      raise ArgumentError, "morph :within received unknown options: #{inspect(unknown_within)}"
    end

    Surface.new!(%{
      operation_types: Keyword.get(opts, :may_propose, [:mount_skill]),
      scope_ceiling: Keyword.get(within, :scopes),
      prompt_token_ceiling: Keyword.get(within, :prompt_tokens),
      approval_requirement: Keyword.get(opts, :approval, :host_policy)
    })
  end

  @spec unique_keyword?(keyword()) :: boolean()
  defp unique_keyword?(values) do
    keys = Keyword.keys(values)
    MapSet.size(MapSet.new(keys)) == length(keys)
  end
end
