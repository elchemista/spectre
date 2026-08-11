defmodule Spectre.Morph.SkillProposal do
  @moduledoc """
  Builds the closed reply-only Skill proposals accepted by Morph.

  This module translates the ergonomic host API into inert ChangeSet data. It
  never registers callbacks or operations, and replacement or disable targets
  must already be runtime-origin Skills in the active immutable Definition.
  """

  alias Spectre.Morph.Change
  alias Spectre.Morph.Options
  alias Spectre.Morph.Surface
  alias Spectre.Morph.Surface.EvaluationObligations
  alias Spectre.Morph.Surface.MountIndex
  alias Spectre.Skill.Definition, as: SkillDefinition

  @type operation_type :: :mount_skill | :replace_skill
  @typep operation_name :: String.t()
  @type skill_build :: %{
          definition: map(),
          cases: [map()]
        }

  @skill_options [:match, :reply, :never, :version, :token_cap, :scopes]

  @doc false
  @spec put(Change.t(), operation_type(), String.t(), keyword()) :: Change.t()
  def put(%Change{error: error} = change, _type, _mount_id, _opts)
      when not is_nil(error),
      do: change

  def put(%Change{} = change, type, mount_id, opts)
      when type in [:mount_skill, :replace_skill] and is_list(opts) do
    operation = Atom.to_string(type)

    with :ok <- Options.validate(opts, @skill_options),
         :ok <- Change.require_state(change, :draft),
         :ok <- permitted(change, operation),
         :ok <- stable_id(mount_id),
         :ok <- maybe_runtime_target(change, type, mount_id),
         {:ok, build} <- skill_definition(change, mount_id, opts),
         :ok <- Change.ensure_operation_capacity(change, 1 + length(build.cases)) do
      mutation = mutation_operation(operation, mount_id, build.definition)
      cases = Enum.map(build.cases, &eval_case_operation/1)

      Change.append_operations(change, [mutation | cases])
    else
      {:error, reason} -> Change.fail(change, reason)
    end
  end

  def put(%Change{} = change, type, _mount_id, _opts)
      when type not in [:mount_skill, :replace_skill],
      do: Change.fail(change, {:morph_not_permitted, type})

  def put(%Change{} = change, _type, _mount_id, opts),
    do: Change.fail(change, {:invalid_morph_options, opts})

  @doc false
  @spec disable(Change.t(), String.t()) :: Change.t()
  def disable(%Change{error: error} = change, _mount_id) when not is_nil(error), do: change

  def disable(%Change{} = change, mount_id) do
    with :ok <- Change.require_state(change, :draft),
         :ok <- permitted(change, "disable_skill"),
         :ok <- stable_id(mount_id),
         {:ok, skill} <- runtime_target(change, mount_id),
         {:ok, cases} <-
           EvaluationObligations.disable_cases(change.surface, mount_id, skill),
         :ok <- Change.ensure_operation_capacity(change, 1 + length(cases)) do
      operations = [disable_operation(mount_id) | Enum.map(cases, &eval_case_operation/1)]
      Change.append_operations(change, operations)
    else
      {:error, reason} -> Change.fail(change, reason)
    end
  end

  @doc false
  @spec internal_eval_case?(map()) :: boolean()
  def internal_eval_case?(%{
        "type" => "add_eval_case",
        "payload" => %{"case" => evaluation_case}
      }) do
    match?({:ok, _case}, Spectre.Eval.Case.new(evaluation_case))
  end

  def internal_eval_case?(_operation), do: false

  @spec skill_definition(Change.t(), String.t(), keyword()) ::
          {:ok, skill_build()} | {:error, term()}
  defp skill_definition(change, mount_id, opts) do
    with {:ok, trigger} <- exact_match(Keyword.get(opts, :match)),
         :ok <- Options.require_nonempty(Keyword.get(opts, :reply), :reply),
         :ok <- reply_template(Keyword.get(opts, :reply)),
         {:ok, negative} <- examples(Keyword.get(opts, :never, [])),
         {:ok, scopes} <- skill_scopes(change.surface, Keyword.get(opts, :scopes)),
         {:ok, token_cap} <- token_cap(change.surface, Keyword.get(opts, :token_cap)) do
      attrs = skill_attrs(mount_id, trigger, negative, scopes, token_cap, opts)

      with {:ok, skill} <- SkillDefinition.new(attrs),
           {:ok, cases} <- EvaluationObligations.reply_cases(change.surface, mount_id, skill) do
        {:ok, %{definition: attrs, cases: cases}}
      end
    end
  end

  @spec skill_attrs(
          String.t(),
          String.t(),
          [String.t()],
          [String.t()],
          pos_integer(),
          keyword()
        ) :: map()
  defp skill_attrs(mount_id, trigger, negative, scopes, token_cap, opts) do
    fragment_id = mount_id <> ":reply"

    %{
      "id" => mount_id,
      "declared_version" => Keyword.get(opts, :version, 1),
      "publisher_ref" => "spectre.morph",
      "applicability" => %{
        "scopes" => scopes,
        "positive" => [trigger],
        "negative" => negative
      },
      "prompt_budget" => token_cap,
      "prompt_fragments" => [
        %{
          "id" => fragment_id,
          "content" => Keyword.fetch!(opts, :reply),
          "token_cap" => token_cap,
          "budget_class" => "small"
        }
      ],
      "flows" => [
        %{
          "id" => hd(scopes),
          "routes" => [
            %{
              "label" => route_label(mount_id),
              "match" => %{"kind" => "exact", "value" => trigger},
              "handler" => %{"kind" => "reply", "prompt" => fragment_id}
            }
          ]
        }
      ]
    }
  end

  @spec mutation_operation(operation_name(), String.t(), map()) :: map()
  defp mutation_operation(type, mount_id, definition) do
    %{
      "type" => type,
      "payload" => %{
        "mount_id" => mount_id,
        "definition" => definition,
        "bindings" => %{},
        "opts" => %{}
      }
    }
  end

  @spec disable_operation(String.t()) :: map()
  defp disable_operation(mount_id) do
    %{"type" => "disable_skill", "payload" => %{"mount_id" => mount_id}}
  end

  @spec exact_match(term()) :: {:ok, String.t()} | {:error, term()}
  defp exact_match({:exact, value}), do: exact_match(value)
  defp exact_match(value) when is_binary(value) and value != "", do: {:ok, value}
  defp exact_match(value), do: {:error, {:morph_requires_exact_match, value}}

  @spec examples(term()) :: {:ok, [String.t()]} | {:error, term()}
  defp examples(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, [], MapSet.new()}, &append_example/2)
    |> then(fn
      {:ok, examples, _seen} -> {:ok, Enum.reverse(examples)}
      :invalid -> {:error, {:invalid_morph_negative_examples, values}}
    end)
  end

  defp examples(value), do: {:error, {:invalid_morph_negative_examples, value}}

  @spec append_example(term(), {:ok, [String.t()], MapSet.t(String.t())}) ::
          {:cont, {:ok, [String.t()], MapSet.t(String.t())}} | {:halt, :invalid}
  defp append_example(value, {:ok, examples, seen}) when is_binary(value) and value != "" do
    if MapSet.member?(seen, value),
      do: {:cont, {:ok, examples, seen}},
      else: {:cont, {:ok, [value | examples], MapSet.put(seen, value)}}
  end

  defp append_example(_value, {:ok, _examples, _seen}), do: {:halt, :invalid}

  @spec reply_template(term()) :: :ok | {:error, term()}
  defp reply_template(template) when is_binary(template) do
    placeholders =
      ~r/{{[^}]*}}/u
      |> Regex.scan(template)
      |> Enum.map(fn [placeholder] -> placeholder end)
      |> Enum.uniq()

    remainder = Regex.replace(~r/{{[^}]*}}/u, template, "")

    placeholder_names =
      Enum.map(placeholders, &binary_part(&1, 2, byte_size(&1) - 4))

    if Enum.all?(placeholders, &(&1 == "{{input.text}}")) and
         not String.contains?(remainder, ["{{", "}}"]),
       do: :ok,
       else: {:error, {:unsupported_morph_reply_placeholder, placeholder_names}}
  end

  defp reply_template(value), do: {:error, {:morph_requires, :reply, value}}

  @spec skill_scopes(Surface.t(), term()) :: {:ok, [String.t()]} | {:error, term()}
  defp skill_scopes(%Surface{scope_ceiling: [scope]}, nil), do: {:ok, [scope]}

  defp skill_scopes(%Surface{scope_ceiling: scopes}, nil),
    do: {:error, {:morph_skill_scopes_required, scopes}}

  defp skill_scopes(%Surface{scope_ceiling: ceiling}, values)
       when is_list(values) and values != [] do
    normalized = Enum.map(values, &canonical_scope/1)

    cond do
      Enum.any?(normalized, &is_nil/1) ->
        {:error, {:invalid_morph_skill_scopes, values}}

      MapSet.size(MapSet.new(normalized)) != length(normalized) ->
        {:error, {:duplicate_morph_skill_scopes, values}}

      Enum.any?(normalized, &(&1 not in ceiling)) ->
        {:error, {:morph_skill_scopes_exceed_surface, normalized, ceiling}}

      true ->
        {:ok, Enum.sort(normalized)}
    end
  end

  defp skill_scopes(_surface, values), do: {:error, {:invalid_morph_skill_scopes, values}}

  @spec canonical_scope(term()) :: String.t() | nil
  defp canonical_scope(value) when is_atom(value) and not is_nil(value),
    do: Atom.to_string(value)

  defp canonical_scope(value) when is_binary(value) and value != "", do: value
  defp canonical_scope(_value), do: nil

  @spec token_cap(Surface.t(), term()) :: {:ok, pos_integer()} | {:error, term()}
  defp token_cap(surface, nil), do: {:ok, min(128, surface.prompt_token_ceiling)}

  defp token_cap(surface, value)
       when is_integer(value) and value > 0 and value <= surface.prompt_token_ceiling,
       do: {:ok, value}

  defp token_cap(surface, value),
    do: {:error, {:morph_prompt_cap_exceeded, value, surface.prompt_token_ceiling}}

  @spec maybe_runtime_target(Change.t(), operation_type(), String.t()) ::
          :ok | {:error, term()}
  defp maybe_runtime_target(_change, :mount_skill, _mount_id), do: :ok

  defp maybe_runtime_target(change, :replace_skill, mount_id) do
    with {:ok, _skill} <- runtime_target(change, mount_id), do: :ok
  end

  @spec runtime_target(Change.t(), String.t()) ::
          {:ok, SkillDefinition.t()} | {:error, term()}
  defp runtime_target(change, mount_id) do
    case change.activation do
      %{definition_ref: definition_ref} when definition_ref == change.source_definition_ref ->
        fetch_runtime_target(change.source_mount_index, mount_id)

      %{definition_ref: actual} ->
        {:error, {:morph_change_definition_ref_mismatch, change.source_definition_ref, actual}}

      _invalid ->
        {:error, :morph_requires_activation}
    end
  end

  @spec fetch_runtime_target(MountIndex.index(), String.t()) ::
          {:ok, SkillDefinition.t()} | {:error, term()}
  defp fetch_runtime_target(mount_index, mount_id) do
    case MountIndex.fetch(mount_index, mount_id) do
      {:ok, mount} -> EvaluationObligations.runtime_skill(mount, mount_id)
      :error -> {:error, {:morph_runtime_skill_not_found, mount_id}}
    end
  end

  @spec eval_case_operation(map()) :: map()
  defp eval_case_operation(evaluation_case) do
    %{"type" => "add_eval_case", "payload" => %{"case" => evaluation_case}}
  end

  @spec route_label(String.t()) :: String.t()
  defp route_label(mount_id) do
    mount_id
    |> String.upcase()
    |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
    |> String.trim("_")
  end

  @spec permitted(Change.t(), String.t()) :: :ok | {:error, term()}
  defp permitted(change, operation) do
    if Surface.allows?(change.surface, operation),
      do: :ok,
      else: {:error, {:morph_not_permitted, operation}}
  end

  @spec stable_id(term()) :: :ok | {:error, term()}
  defp stable_id(value) when is_binary(value) and value != "" do
    if String.starts_with?(value, "Elixir."),
      do: {:error, {:morph_code_reference_forbidden, value}},
      else: :ok
  end

  defp stable_id(value), do: {:error, {:invalid_morph_skill_id, value}}
end
