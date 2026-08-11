defmodule Spectre.Prompt.Fragment do
  @moduledoc """
  Resolved or canonical prompt content with its composition metadata.

  Runtime fragments are built with `new/3`. Content-addressed Definition
  fragments are built with `canonical/1`; those fragments reject EEx and use a
  closed `{{path.to.value}}` placeholder grammar with an explicit schema.
  """

  alias Spectre.Canonical.Value

  @schema_version 1
  @targets [:instructions, :context, :task]
  @positions [:start, :end, :replace]
  @trust_classes [:instruction, :data]
  @visibilities [:private, :agent, :operator, :public]
  @priorities [:low, :normal, :high]
  @budget_classes [:small, :standard, :large]
  @placeholder ~r/\{\{([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\}\}/
  @legacy_placeholder ~r/<%=\s*@([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\s*%>/
  @legacy_inspect_placeholder ~r/<%=\s*inspect\(\s*@([a-zA-Z_][a-zA-Z0-9_]*(?:\.[a-zA-Z_][a-zA-Z0-9_]*)*)\s*\)\s*%>/
  @renderer_refs ["spectre.renderer.text/1", "spectre.renderer.inspect/1"]

  defstruct [
    :id,
    :content,
    :scope,
    :target,
    :position,
    :source,
    :trust,
    :digest,
    schema_version: @schema_version,
    placeholders: %{},
    provenance: %{},
    visibility: :private,
    requested_priority: :normal,
    granted_priority: :normal,
    budget_class: :standard,
    token_cap: nil,
    condition_ref: nil,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: term(),
          content: String.t() | nil,
          scope: term(),
          target: Spectre.Prompt.Operation.target(),
          position: Spectre.Prompt.Operation.position(),
          source: Spectre.Prompt.Operation.source() | :base | map(),
          trust: :instruction | :data,
          digest: String.t() | nil,
          schema_version: pos_integer(),
          placeholders: map(),
          provenance: map(),
          visibility: :private | :agent | :operator | :public,
          requested_priority: :low | :normal | :high,
          granted_priority: :low | :normal | :high,
          budget_class: :small | :standard | :large,
          token_cap: pos_integer() | nil,
          condition_ref: map() | nil,
          metadata: map()
        }

  @doc """
  Builds a resolved prompt fragment from an operation.
  """
  @spec new(Spectre.Prompt.Operation.t(), String.t(), map()) :: t()
  def new(%Spectre.Prompt.Operation{} = operation, content, metadata \\ %{})
      when is_binary(content) and is_map(metadata) do
    %__MODULE__{
      id: operation.id,
      content: content,
      scope: operation.scope,
      target: operation.target,
      position: operation.position,
      source: operation.source,
      trust: operation.trust,
      metadata: metadata
    }
  end

  @doc """
  Builds the base task fragment selected by `ask`.
  """
  @spec base(String.t()) :: t()
  def base(content) when is_binary(content) do
    %__MODULE__{
      id: :base_task,
      content: content,
      scope: :base,
      target: :task,
      position: :end,
      source: :base,
      trust: :instruction
    }
  end

  @doc """
  Builds a governed, digest-addressed prompt fragment.

  Canonical content may be static text or a template containing only declared
  `{{path.to.value}}` placeholders. Dynamic providers use `content: nil` and
  must remain `context:data` fragments.
  """
  @spec canonical(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def canonical(attrs) when is_list(attrs), do: attrs |> Map.new() |> canonical()

  def canonical(attrs) when is_map(attrs) do
    fragment = struct(__MODULE__, Map.take(attrs, fields()))

    with :ok <- validate_canonical(fragment),
         {:ok, digest} <- fragment |> canonical_data() |> Value.digest() do
      {:ok, %{fragment | digest: digest, metadata: %{}}}
    end
  end

  def canonical(value), do: {:error, {:invalid_canonical_prompt_fragment, shape(value)}}

  @doc "Builds a canonical fragment or raises with its stable validation reason."
  @spec canonical!(map() | keyword()) :: t()
  def canonical!(attrs) do
    case canonical(attrs) do
      {:ok, fragment} ->
        fragment

      {:error, reason} ->
        raise ArgumentError, "invalid canonical prompt fragment: #{inspect(reason)}"
    end
  end

  @doc """
  Migrates the safe subset of compiled `.text.heex` assets to closed templates.

  Only direct assign paths such as `<%= @input.text %>` are accepted. Any
  remaining EEx tag is rejected instead of being copied into runtime data.
  """
  @spec close_template(String.t()) :: {:ok, String.t(), map()} | {:error, term()}
  def close_template(content) when is_binary(content) do
    inspected = legacy_paths(@legacy_inspect_placeholder, content)
    scalar = legacy_paths(@legacy_placeholder, content)

    closed =
      content
      |> then(&Regex.replace(@legacy_inspect_placeholder, &1, "{{\\1}}"))
      |> then(&Regex.replace(@legacy_placeholder, &1, "{{\\1}}"))

    cond do
      String.contains?(closed, "<%") ->
        {:error, :executable_prompt_template}

      not MapSet.disjoint?(inspected, scalar) ->
        {:error, :ambiguous_prompt_placeholder_renderer}

      true ->
        {:ok, closed, closed_placeholders(closed, inspected)}
    end
  end

  def close_template(value), do: {:error, {:invalid_prompt_template, shape(value)}}

  @doc "Returns the portable data included in a canonical fragment digest."
  @spec canonical_data(t()) :: map()
  def canonical_data(%__MODULE__{} = fragment) do
    %{
      schema_version: fragment.schema_version,
      id: fragment.id,
      content: fragment.content,
      scope: fragment.scope,
      target: fragment.target,
      position: fragment.position,
      source: fragment.source,
      trust: fragment.trust,
      placeholders: fragment.placeholders,
      provenance: fragment.provenance,
      visibility: fragment.visibility,
      requested_priority: fragment.requested_priority,
      granted_priority: fragment.granted_priority,
      budget_class: fragment.budget_class,
      token_cap: fragment.token_cap,
      condition_ref: fragment.condition_ref
    }
  end

  @spec validate_canonical(t()) :: :ok | {:error, term()}
  defp validate_canonical(%__MODULE__{} = fragment) do
    validators = [
      &validate_schema/1,
      &validate_identity/1,
      &validate_placement/1,
      &validate_governance/1,
      &validate_content/1,
      &validate_portable_fields/1
    ]

    Enum.reduce_while(validators, :ok, fn validator, :ok ->
      case validator.(fragment) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @spec validate_schema(t()) :: :ok | {:error, term()}
  defp validate_schema(%__MODULE__{schema_version: @schema_version}), do: :ok

  defp validate_schema(%__MODULE__{schema_version: version}),
    do: {:error, {:unsupported_prompt_fragment_schema, version}}

  @spec validate_identity(t()) :: :ok | {:error, term()}
  defp validate_identity(%__MODULE__{id: nil}), do: {:error, :missing_prompt_fragment_id}
  defp validate_identity(%__MODULE__{scope: nil}), do: {:error, :missing_prompt_fragment_scope}
  defp validate_identity(%__MODULE__{}), do: :ok

  @spec validate_placement(t()) :: :ok | {:error, term()}
  defp validate_placement(%__MODULE__{target: target}) when target not in @targets,
    do: {:error, {:invalid_prompt_fragment_target, target}}

  defp validate_placement(%__MODULE__{position: position}) when position not in @positions,
    do: {:error, {:invalid_prompt_fragment_position, position}}

  defp validate_placement(%__MODULE__{trust: trust}) when trust not in @trust_classes,
    do: {:error, {:invalid_prompt_fragment_trust, trust}}

  defp validate_placement(%__MODULE__{}), do: :ok

  @spec validate_governance(t()) :: :ok | {:error, term()}
  defp validate_governance(%__MODULE__{} = fragment) do
    with :ok <-
           validate_member(
             fragment.visibility,
             @visibilities,
             :invalid_prompt_fragment_visibility
           ),
         :ok <-
           validate_member(
             fragment.requested_priority,
             @priorities,
             :invalid_prompt_fragment_priority
           ),
         :ok <-
           validate_member(
             fragment.granted_priority,
             @priorities,
             :invalid_prompt_fragment_grant
           ),
         :ok <-
           validate_member(
             fragment.budget_class,
             @budget_classes,
             :invalid_prompt_fragment_budget_class
           ),
         :ok <- validate_token_cap(fragment.token_cap) do
      validate_dynamic_fragment(fragment)
    end
  end

  @spec validate_member(term(), [term()], atom()) :: :ok | {:error, term()}
  defp validate_member(value, allowed, error) do
    if value in allowed, do: :ok, else: {:error, {error, value}}
  end

  @spec validate_token_cap(term()) :: :ok | {:error, term()}
  defp validate_token_cap(nil), do: :ok
  defp validate_token_cap(value) when is_integer(value) and value > 0, do: :ok

  defp validate_token_cap(value),
    do: {:error, {:invalid_prompt_fragment_token_cap, value}}

  @spec validate_dynamic_fragment(t()) :: :ok | {:error, term()}
  defp validate_dynamic_fragment(%__MODULE__{content: nil, target: target})
       when target != :context,
       do: {:error, :dynamic_prompt_fragment_must_target_context}

  defp validate_dynamic_fragment(%__MODULE__{content: nil, trust: trust}) when trust != :data,
    do: {:error, :dynamic_prompt_fragment_must_be_data}

  defp validate_dynamic_fragment(%__MODULE__{}), do: :ok

  @spec validate_content(t()) :: :ok | {:error, term()}
  defp validate_content(%__MODULE__{content: nil, placeholders: placeholders}) do
    if placeholders == %{}, do: :ok, else: {:error, :dynamic_prompt_fragment_has_placeholders}
  end

  defp validate_content(%__MODULE__{content: content, placeholders: placeholders})
       when is_binary(content) and is_map(placeholders) do
    declared = placeholders |> Map.keys() |> Enum.sort()

    observed =
      @placeholder
      |> Regex.scan(content, capture: :all_but_first)
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.sort()

    cond do
      String.contains?(content, "<%") -> {:error, :executable_prompt_template}
      declared != observed -> {:error, {:prompt_placeholder_schema_mismatch, declared, observed}}
      Enum.all?(placeholders, &valid_placeholder?/1) -> :ok
      true -> {:error, :invalid_prompt_placeholder_schema}
    end
  end

  defp validate_content(%__MODULE__{content: content}),
    do: {:error, {:invalid_prompt_fragment_content, shape(content)}}

  @spec valid_placeholder?({term(), term()}) :: boolean()
  defp valid_placeholder?({name, %{path: path, renderer_ref: renderer_ref}}) do
    is_binary(name) and is_list(path) and path != [] and Enum.all?(path, &is_binary/1) and
      renderer_ref in @renderer_refs
  end

  defp valid_placeholder?(_entry), do: false

  @spec validate_portable_fields(t()) :: :ok | {:error, term()}
  defp validate_portable_fields(fragment) do
    case fragment |> canonical_data() |> Value.validate() do
      :ok -> :ok
      {:error, reason} -> {:error, {:nonportable_prompt_fragment, reason}}
    end
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end

  @spec shape(term()) :: atom()
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(_value), do: :other

  @spec legacy_paths(Regex.t(), String.t()) :: MapSet.t(String.t())
  defp legacy_paths(pattern, content) do
    pattern
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  @spec closed_placeholders(String.t(), MapSet.t(String.t())) :: map()
  defp closed_placeholders(content, inspected) do
    @placeholder
    |> Regex.scan(content, capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Map.new(fn name ->
      renderer_ref =
        if MapSet.member?(inspected, name),
          do: "spectre.renderer.inspect/1",
          else: "spectre.renderer.text/1"

      {name, %{path: String.split(name, "."), renderer_ref: renderer_ref}}
    end)
  end
end
