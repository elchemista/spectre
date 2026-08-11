defmodule Spectre.Morph.Surface.EvaluationObligations do
  @moduledoc """
  Derives mandatory evaluation cases from an immutable Definition diff.

  Morph-owned cases are not trusted merely because they appear in a
  ChangeSet. This module reconstructs the required cases from the published
  parent and candidate Skill mounts and requires byte-for-byte equivalent
  canonical cases during composition, activation, and recovery.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Definition.Canonical
  alias Spectre.Eval.Case, as: EvalCase
  alias Spectre.Morph.Surface
  alias Spectre.Morph.Surface.MountIndex
  alias Spectre.Morph.Surface.Mutation
  alias Spectre.Prompt.Fragment
  alias Spectre.Prompt.Materializer
  alias Spectre.Skill.Definition, as: SkillDefinition

  @max_evaluation_cases 10_000

  @type canonical_case :: map()
  @type canonical_cases :: %{optional(String.t()) => canonical_case()}
  @type route_contract :: %{
          input: String.t(),
          label: term(),
          prompt_ref: term()
        }

  @doc false
  @spec verify(Surface.t(), Canonical.t(), Canonical.t(), [map()]) ::
          :ok | {:error, term()}
  def verify(
        %Surface{} = surface,
        %Canonical{} = parent,
        %Canonical{} = candidate,
        cases
      )
      when is_list(cases) do
    with {:ok, mutations} <- MountIndex.mutations(parent, candidate),
         {:ok, required} <- required_cases(surface, mutations),
         {:ok, supplied} <- canonical_cases(cases) do
      require_cases(required, supplied)
    end
  end

  @doc false
  @spec case_id(term(), term(), String.t()) :: String.t()
  def case_id(mount_id, scope, purpose) do
    digest =
      Value.digest!(%{
        "mount" => mount_id,
        "scope" => scope,
        "purpose" => purpose
      })

    "morph:" <> binary_part(digest, 0, 24)
  end

  @spec required_cases(Surface.t(), [Mutation.t()]) ::
          {:ok, [canonical_case()]} | {:error, term()}
  defp required_cases(surface, mutations) do
    mutations
    |> Enum.reduce_while({:ok, [], 0}, &append_mutation_cases(surface, &1, &2))
    |> finalize_required_cases()
  end

  @spec append_mutation_cases(
          Surface.t(),
          Mutation.t(),
          {:ok, [canonical_case()], non_neg_integer()}
        ) ::
          {:cont, {:ok, [canonical_case()], non_neg_integer()}}
          | {:halt, {:error, term()}}
  defp append_mutation_cases(surface, mutation, {:ok, cases, count}) do
    with {:ok, required} <- mutation_cases(surface, mutation),
         next_count = count + length(required),
         true <- next_count <= @max_evaluation_cases do
      {:cont, {:ok, :lists.reverse(required, cases), next_count}}
    else
      false -> {:halt, {:error, :too_many_morph_evaluation_obligations}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  @spec finalize_required_cases({:ok, [canonical_case()], non_neg_integer()} | {:error, term()}) ::
          {:ok, [canonical_case()]} | {:error, term()}
  defp finalize_required_cases({:ok, cases, _count}), do: {:ok, Enum.reverse(cases)}
  defp finalize_required_cases({:error, _reason} = error), do: error

  @spec mutation_cases(Surface.t(), Mutation.t()) ::
          {:ok, [canonical_case()]} | {:error, term()}
  defp mutation_cases(surface, %Mutation{
         mount_id: mount_id,
         operation: :mount_skill,
         candidate: candidate
       }) do
    reply_cases_for(surface, mount_id, candidate)
  end

  defp mutation_cases(surface, %Mutation{
         mount_id: mount_id,
         operation: :replace_skill,
         parent: parent,
         candidate: candidate
       }) do
    # Replacement is legal only for a runtime-origin parent. Checking both
    # sides here prevents a tampered ChangeSet from shadowing compiled code.
    with {:ok, _parent_skill} <- runtime_skill(parent, mount_id) do
      reply_cases_for(surface, mount_id, candidate)
    end
  end

  defp mutation_cases(surface, %Mutation{
         mount_id: mount_id,
         operation: :disable_skill,
         parent: parent
       }) do
    with {:ok, skill} <- runtime_skill(parent, mount_id),
         {:ok, scopes} <- obligation_scopes(skill, surface),
         inputs when is_list(inputs) and inputs != [] <-
           SkillDefinition.applicability(skill).positive,
         true <- Enum.all?(inputs, &(is_binary(&1) and &1 != "")) do
      disabled_cases(mount_id, scopes, inputs)
    else
      _value -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  @spec reply_cases_for(Surface.t(), term(), map() | nil) ::
          {:ok, [canonical_case()]} | {:error, term()}
  defp reply_cases_for(surface, mount_id, mount) do
    with {:ok, skill} <- runtime_skill(mount, mount_id),
         :ok <- reply_only(skill, mount_id),
         {:ok, route} <- single_exact_reply(skill, mount_id),
         {:ok, fragment} <- route_fragment(skill, route.prompt_ref, mount_id),
         {:ok, scopes} <- obligation_scopes(skill, surface) do
      reply_cases(mount_id, scopes, route, fragment)
    end
  end

  @spec runtime_skill(map() | nil, term()) ::
          {:ok, SkillDefinition.t()} | {:error, term()}
  defp runtime_skill(mount, mount_id) when is_map(mount) do
    with data when is_map(data) <- value(mount, :definition),
         {:ok, canonical} <- Canonical.from_data(data),
         :ok <- embedded_definition_ref(canonical, value(mount, :definition_ref), mount_id),
         {:ok, skill} <- SkillDefinition.from_canonical(canonical),
         :runtime <- SkillDefinition.origin(skill) do
      {:ok, skill}
    else
      :compiled -> {:error, {:morph_compiled_skill_is_immutable, mount_id}}
      {:error, _reason} = error -> error
      _value -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  defp runtime_skill(_mount, mount_id),
    do: {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}

  @spec reply_only(SkillDefinition.t(), term()) :: :ok | {:error, term()}
  defp reply_only(skill, mount_id) do
    if SkillDefinition.operation_refs(skill) == [] and SkillDefinition.works(skill) == [],
      do: :ok,
      else: {:error, {:morph_evaluation_obligation_not_declarative, mount_id}}
  end

  @spec single_exact_reply(SkillDefinition.t(), term()) ::
          {:ok, route_contract()} | {:error, term()}
  defp single_exact_reply(skill, mount_id) do
    case SkillDefinition.routes(skill) do
      [route] -> exact_reply_route(route, mount_id)
      _routes -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  @spec exact_reply_route(map(), term()) :: {:ok, route_contract()} | {:error, term()}
  defp exact_reply_route(route, mount_id) when is_map(route) do
    handler = value(route, :handler, %{})
    checks = value(route, :checks, [])
    label = value(route, :label)

    with kind when kind in [:reply, "reply"] <- value(handler, :kind),
         prompt_ref when not is_nil(prompt_ref) <- value(handler, :prompt),
         {:ok, input} <- exact_text_check(checks),
         true <- not is_nil(label) do
      {:ok, %{input: input, label: EvalCase.canonical(label), prompt_ref: prompt_ref}}
    else
      _value -> {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  @spec exact_text_check(term()) :: {:ok, String.t()} | {:error, :invalid_exact_text_check}
  defp exact_text_check([{:text, input}]) when is_binary(input) and input != "", do: {:ok, input}
  defp exact_text_check([["text", input]]) when is_binary(input) and input != "", do: {:ok, input}
  defp exact_text_check(_checks), do: {:error, :invalid_exact_text_check}

  @spec route_fragment(SkillDefinition.t(), term(), term()) ::
          {:ok, Fragment.t()} | {:error, term()}
  defp route_fragment(skill, prompt_ref, mount_id) do
    case Enum.find(SkillDefinition.prompt_fragments(skill), &same_name?(&1.id, prompt_ref)) do
      %Fragment{content: content, condition_ref: nil, placeholders: placeholders} = fragment
      when is_binary(content) and is_map(placeholders) ->
        if Enum.all?(Map.keys(placeholders), &(&1 == "input.text")),
          do: {:ok, fragment},
          else: {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}

      _value ->
        {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}
    end
  end

  @spec obligation_scopes(SkillDefinition.t(), Surface.t()) ::
          {:ok, [String.t()]} | {:error, :skill_applicability_ceiling_exceeded}
  defp obligation_scopes(skill, surface) do
    scopes =
      skill
      |> SkillDefinition.applicability()
      |> Map.fetch!(:scopes)
      |> Enum.map(&canonical_scope/1)

    if scopes != [] and Enum.all?(scopes, &(is_binary(&1) and &1 in surface.scope_ceiling)),
      do: {:ok, scopes},
      else: {:error, :skill_applicability_ceiling_exceeded}
  end

  @spec embedded_definition_ref(Canonical.t(), term(), term()) :: :ok | {:error, term()}
  defp embedded_definition_ref(canonical, embedded, mount_id) when is_binary(embedded) do
    actual = canonical |> Canonical.ref() |> to_string()

    if embedded == actual,
      do: :ok,
      else: {:error, {:morph_skill_definition_ref_mismatch, mount_id, embedded, actual}}
  end

  defp embedded_definition_ref(_canonical, embedded, mount_id),
    do: {:error, {:invalid_morph_skill_definition_ref, mount_id, embedded}}

  @spec canonical_scope(term()) :: String.t() | nil
  defp canonical_scope(scope) when is_atom(scope) and not is_nil(scope), do: Atom.to_string(scope)
  defp canonical_scope(scope) when is_binary(scope) and scope != "", do: scope
  defp canonical_scope(_scope), do: nil

  @spec reply_cases(term(), [String.t()], route_contract(), Fragment.t()) ::
          {:ok, [canonical_case()]} | {:error, term()}
  defp reply_cases(mount_id, scopes, route, fragment) do
    scopes
    |> Enum.reduce_while({:ok, [], 0}, fn scope, {:ok, cases, count} ->
      context = %{"scope" => scope}

      with true <- count < @max_evaluation_cases,
           {:ok, output, _evidence} <- Materializer.render(fragment, route.input, context),
           {:ok, evaluation_case} <-
             EvalCase.new(%{
               "id" => case_id(mount_id, scope, "reply"),
               "input" => route.input,
               "expected_outcome" => "route",
               "expected_route" => route.label,
               "expected_output" => output,
               "context" => context,
               "llm" => "forbidden"
             }) do
        {:cont, {:ok, [EvalCase.to_data(evaluation_case) | cases], count + 1}}
      else
        false ->
          {:halt, {:error, :too_many_morph_evaluation_obligations}}

        {:error, reason} ->
          {:halt, {:error, {:morph_evaluation_obligation_not_derivable, mount_id, reason}}}
      end
    end)
    |> reverse_cases()
  end

  @spec disabled_cases(term(), [String.t()], [String.t()]) ::
          {:ok, [canonical_case()]} | {:error, term()}
  defp disabled_cases(mount_id, scopes, inputs) do
    scopes
    |> Stream.flat_map(fn scope -> Stream.map(inputs, &{scope, &1}) end)
    |> Enum.reduce_while({:ok, [], 0}, fn {scope, input}, {:ok, cases, count} ->
      attrs = disabled_case_attrs(mount_id, scope, input)
      append_disabled_case(attrs, mount_id, cases, count)
    end)
    |> reverse_cases()
  end

  @spec disabled_case_attrs(term(), String.t(), String.t()) :: canonical_case()
  defp disabled_case_attrs(mount_id, scope, input) do
    %{
      "id" => case_id(mount_id, scope, "disabled:" <> input),
      "input" => input,
      "expected_outcome" => "clarify",
      "context" => %{"scope" => scope},
      "llm" => "forbidden"
    }
  end

  @spec append_disabled_case(canonical_case(), term(), [canonical_case()], non_neg_integer()) ::
          {:cont, {:ok, [canonical_case()], pos_integer()}} | {:halt, {:error, term()}}
  defp append_disabled_case(_attrs, _mount_id, _cases, count)
       when count >= @max_evaluation_cases,
       do: {:halt, {:error, :too_many_morph_evaluation_obligations}}

  defp append_disabled_case(attrs, mount_id, cases, count) do
    case EvalCase.new(attrs) do
      {:ok, evaluation_case} ->
        {:cont, {:ok, [EvalCase.to_data(evaluation_case) | cases], count + 1}}

      {:error, _reason} ->
        {:halt, {:error, {:morph_evaluation_obligation_not_derivable, mount_id}}}
    end
  end

  @spec reverse_cases({:ok, [canonical_case()], non_neg_integer()} | {:error, term()}) ::
          {:ok, [canonical_case()]} | {:error, term()}
  defp reverse_cases({:ok, cases, _count}), do: {:ok, Enum.reverse(cases)}
  defp reverse_cases({:error, _reason} = error), do: error

  @spec canonical_cases([map()]) :: {:ok, canonical_cases()} | {:error, term()}
  defp canonical_cases(cases) do
    cases
    |> Stream.with_index()
    |> Enum.reduce_while({:ok, %{}}, fn {case_data, index}, {:ok, normalized} ->
      with {:ok, evaluation_case} <- EvalCase.new(case_data),
           data = EvalCase.to_data(evaluation_case),
           false <- Map.has_key?(normalized, evaluation_case.id) do
        {:cont, {:ok, Map.put(normalized, evaluation_case.id, data)}}
      else
        true ->
          {:halt, {:error, {:duplicate_morph_evaluation_obligation, index}}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_morph_evaluation_obligation, index, reason}}}
      end
    end)
  end

  @spec require_cases([canonical_case()], canonical_cases()) :: :ok | {:error, term()}
  defp require_cases(required, supplied) do
    Enum.reduce_while(required, :ok, fn expected, :ok ->
      id = expected["id"]

      case Map.fetch(supplied, id) do
        {:ok, ^expected} -> {:cont, :ok}
        {:ok, _other} -> {:halt, {:error, {:morph_evaluation_obligation_mismatch, id}}}
        :error -> {:halt, {:error, {:morph_evaluation_obligation_missing, id}}}
      end
    end)
  end

  @spec same_name?(term(), term()) :: boolean()
  defp same_name?(left, right) when is_atom(left), do: same_name?(Atom.to_string(left), right)
  defp same_name?(left, right) when is_atom(right), do: same_name?(left, Atom.to_string(right))
  defp same_name?(left, right), do: left == right

  @spec value(map(), atom(), term()) :: term()
  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
