defmodule Spectre.Presentation.Approval do
  @moduledoc """
  Pure consent-response semantics for an immutable Presentation.

  A Presentation describes material prepared for disclosure. This module owns
  the separate Evidence graph proving that the material was successfully shown
  and then supported or contradicted by an authenticated recipient. Keeping
  those responsibilities apart makes the causal order visible:

      Presentation -> show Act -> successful Outcome -> response Evidence

  None of these checks grants authority. Admission remains responsible for
  requiring the returned Evidence basis under the selected Mandate.
  """

  alias Spectre.{Act, Evidence, Ingress, Outcome, Portable, Presentation, SubmissionContext}

  @contract_ref "spectre.presentation.approval.v1"
  @response_fields [
    :ref,
    :valid_from,
    :valid_until,
    :freshness_ms,
    :assumptions,
    :labels,
    :payload,
    :payload_ref
  ]

  @doc "Returns the closed proposition for a response to one successful show Act."
  @spec proposition(String.t(), String.t()) :: map()
  def proposition(presentation_ref, show_act_ref)
      when is_binary(presentation_ref) and presentation_ref != "" and is_binary(show_act_ref) and
             show_act_ref != "" do
    %{
      "contract_ref" => @contract_ref,
      "presentation_ref" => presentation_ref,
      "show_act_ref" => show_act_ref
    }
  end

  @doc "Builds an authenticated supporting or contradicting response Evidence record."
  @spec response_evidence(
          SubmissionContext.t(),
          Presentation.t(),
          Act.t(),
          Evidence.stance(),
          integer(),
          map() | keyword()
        ) :: {:ok, Evidence.t()} | {:error, term()}
  def response_evidence(
        %SubmissionContext{} = context,
        %Presentation{} = presentation,
        %Act{} = show_act,
        stance,
        observed_at,
        attrs
      )
      when stance in [:supports, :contradicts] and is_integer(observed_at) do
    with {:ok, context} <- SubmissionContext.new(context),
         {:ok, presentation} <- Presentation.new(presentation),
         {:ok, show_act} <- Act.new(show_act),
         :ok <- response_context(context, presentation, show_act, observed_at),
         {:ok, attrs} <-
           Portable.normalize_attrs(attrs, @response_fields, :presentation_response_evidence) do
      attrs
      |> Map.merge(%{
        proposition: proposition(presentation.ref, show_act.ref),
        stance: stance,
        issuer_ref: context.authenticated_principal_ref,
        bindings: %{
          "presentation_ref" => presentation.ref,
          "show_act_ref" => show_act.ref,
          "recipient_ref" => context.authenticated_principal_ref
        },
        provisional: false
      })
      |> then(&Ingress.evidence(context, observed_at, &1))
    end
  end

  def response_evidence(
        _context,
        _presentation,
        _show_act,
        _stance,
        _observed_at,
        _attrs
      ),
      do: {:error, :invalid_presentation_response_evidence}

  @doc "Recognizes only the exact canonical response proposition."
  @spec refs(Evidence.t()) ::
          :not_approval | {:ok, String.t(), String.t()} | {:error, term()}
  def refs(%Evidence{proposition: %{"contract_ref" => @contract_ref} = value}) do
    presentation_ref = Map.get(value, "presentation_ref")
    show_act_ref = Map.get(value, "show_act_ref")

    if valid_ref?(presentation_ref) and valid_ref?(show_act_ref) and
         value == proposition(presentation_ref, show_act_ref) do
      {:ok, presentation_ref, show_act_ref}
    else
      {:error, :noncanonical_presentation_approval_proposition}
    end
  end

  def refs(%Evidence{}), do: :not_approval

  @doc "Validates one supporting approval and discards its computed Evidence basis."
  @spec validate_approval(
          Evidence.t(),
          Presentation.t(),
          Act.t(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: :ok | {:error, term()}
  def validate_approval(approval, presentation, show_act, outcomes, evidence, time) do
    with {:ok, _basis_refs} <-
           validate_approval_with_basis(
             approval,
             presentation,
             show_act,
             outcomes,
             evidence,
             time
           ) do
      :ok
    end
  end

  @doc "Validates either response stance and returns its complete Evidence basis."
  @spec validate_response_with_basis(
          Evidence.t(),
          Presentation.t(),
          Act.t(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def validate_response_with_basis(
        %Evidence{stance: stance} = response,
        %Presentation{} = presentation,
        %Act{} = show_act,
        outcomes,
        evidence,
        time
      )
      when stance in [:supports, :contradicts] and is_list(outcomes) and is_list(evidence) and
             is_integer(time) do
    validate_evidence_with_basis(
      response,
      stance,
      presentation,
      show_act,
      outcomes,
      evidence,
      time
    )
  end

  def validate_response_with_basis(
        _response,
        _presentation,
        _show_act,
        _outcomes,
        _evidence,
        _time
      ),
      do: {:error, :invalid_presentation_response}

  @doc "Validates a supporting approval and returns its complete Evidence basis."
  @spec validate_approval_with_basis(
          Evidence.t(),
          Presentation.t(),
          Act.t(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def validate_approval_with_basis(
        %Evidence{} = approval,
        %Presentation{} = presentation,
        %Act{} = show_act,
        outcomes,
        evidence,
        time
      )
      when is_list(outcomes) and is_list(evidence) and is_integer(time) do
    validate_evidence_with_basis(
      approval,
      :supports,
      presentation,
      show_act,
      outcomes,
      evidence,
      time
    )
  end

  def validate_approval_with_basis(
        _approval,
        _presentation,
        _show_act,
        _outcomes,
        _evidence,
        _time
      ),
      do: {:error, :invalid_presentation_approval}

  @doc false
  @spec validate_approval_contradiction_with_basis(
          Evidence.t(),
          Presentation.t(),
          Act.t(),
          [Outcome.t()],
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def validate_approval_contradiction_with_basis(
        %Evidence{} = approval,
        %Presentation{} = presentation,
        %Act{} = show_act,
        outcomes,
        evidence,
        time
      )
      when is_list(outcomes) and is_list(evidence) and is_integer(time) do
    validate_evidence_with_basis(
      approval,
      :contradicts,
      presentation,
      show_act,
      outcomes,
      evidence,
      time
    )
  end

  def validate_approval_contradiction_with_basis(
        _approval,
        _presentation,
        _show_act,
        _outcomes,
        _evidence,
        _time
      ),
      do: {:error, :invalid_presentation_approval_contradiction}

  @doc false
  @spec validate_assumption_contradiction_with_basis(
          Evidence.t(),
          Evidence.t(),
          Presentation.t(),
          [Evidence.t()],
          integer()
        ) :: {:ok, [String.t()]} | {:error, term()}
  def validate_assumption_contradiction_with_basis(
        %Evidence{} = item,
        %Evidence{} = approval,
        %Presentation{} = presentation,
        evidence,
        time
      )
      when is_list(evidence) and is_integer(time) do
    with true <- item.stance == :contradicts,
         true <- valid_assumption_identity?(item, approval, presentation),
         true <- current_assumption?(item, time, time),
         {:ok, basis_refs} <-
           qualified_evidence_basis(
             item,
             approval,
             presentation,
             evidence,
             time,
             MapSet.new([approval.ref, item.ref]),
             time
           ) do
      {:ok, basis_refs}
    else
      false -> {:error, :presentation_assumption_evidence_not_current}
      {:error, _reason} = error -> error
    end
  end

  def validate_assumption_contradiction_with_basis(
        _item,
        _approval,
        _presentation,
        _evidence,
        _time
      ),
      do: {:error, :invalid_presentation_assumption_evidence}

  defp validate_evidence_with_basis(
         approval,
         stance,
         presentation,
         show_act,
         outcomes,
         evidence,
         time
       ) do
    with {:ok, presentation_ref, show_act_ref} <- refs(approval),
         true <- approval.stance == stance,
         true <- presentation_ref == presentation.ref,
         true <- show_act_ref == show_act.ref,
         :ok <- Presentation.validate_show(show_act, presentation),
         :ok <- validate_identity(approval, presentation, show_act_ref),
         :ok <- current_observation(approval, time),
         :ok <- successful_show_precedes_approval(approval, show_act, outcomes),
         {:ok, assumption_refs} <- recognized_assumptions(approval, presentation, evidence, time) do
      {:ok, normalize_basis_refs([approval.ref | assumption_refs])}
    else
      false -> {:error, :presentation_approval_stance_or_binding_mismatch}
      :not_approval -> {:error, :not_presentation_approval}
      {:error, _reason} = error -> error
    end
  end

  defp validate_identity(approval, presentation, show_act_ref) do
    recipient_ref = Map.get(approval.bindings, "recipient_ref")
    authenticated_ref = Map.get(approval.bindings, "authenticated_principal_ref")

    cond do
      approval.provenance != :observed or approval.provisional ->
        {:error, :presentation_approval_not_final_observation}

      approval.parent_refs != [] ->
        {:error, :presentation_approval_has_parents}

      approval.source_ref not in presentation.approval_source_refs ->
        {:error, :presentation_approval_source_not_configured}

      is_nil(approval.issuer_ref) or approval.issuer_ref != recipient_ref or
          approval.issuer_ref != authenticated_ref ->
        {:error, :presentation_approval_principal_mismatch}

      recipient_ref not in presentation.recipient_refs ->
        {:error, :presentation_approval_recipient_mismatch}

      Map.get(approval.bindings, "presentation_ref") != presentation.ref or
          Map.get(approval.bindings, "show_act_ref") != show_act_ref ->
        {:error, :presentation_approval_binding_mismatch}

      not valid_ref?(Map.get(approval.bindings, "scope_ref")) or
          not valid_ref?(Map.get(approval.bindings, "authentication_ref")) ->
        {:error, :presentation_approval_authentication_missing}

      true ->
        :ok
    end
  end

  defp response_context(context, presentation, show_act, observed_at) do
    cond do
      context.scope_ref != presentation.scope_ref ->
        {:error, :presentation_response_scope_mismatch}

      context.authenticated_principal_ref not in presentation.recipient_refs ->
        {:error, :presentation_response_recipient_mismatch}

      context.ingress_ref not in presentation.approval_source_refs ->
        {:error, :presentation_response_source_not_configured}

      observed_at < show_act.committed_at ->
        {:error, :presentation_response_precedes_show_act}

      true ->
        Presentation.validate_show(show_act, presentation)
    end
  end

  defp current_observation(evidence, time) do
    cond do
      evidence.observed_at > time ->
        {:error, :presentation_approval_from_future}

      not is_nil(evidence.valid_from) and evidence.valid_from > time ->
        {:error, :presentation_approval_not_yet_valid}

      not is_nil(evidence.valid_until) and time >= evidence.valid_until ->
        {:error, :presentation_approval_expired}

      not is_nil(evidence.freshness_ms) and time - evidence.observed_at > evidence.freshness_ms ->
        {:error, :presentation_approval_stale}

      true ->
        :ok
    end
  end

  defp successful_show_precedes_approval(approval, show_act, outcomes) do
    successful? =
      Enum.any?(outcomes, fn
        %Outcome{} = outcome ->
          outcome.act_ref == show_act.ref and outcome.status == :succeeded and
            outcome.observed_at <= approval.observed_at

        _other ->
          false
      end)

    cond do
      show_act.committed_at > approval.observed_at ->
        {:error, :presentation_approval_precedes_show_act}

      not successful? ->
        {:error, :presentation_approval_precedes_successful_show}

      true ->
        :ok
    end
  end

  defp recognized_assumptions(%Evidence{assumptions: []}, _presentation, _evidence, _time),
    do: {:ok, []}

  defp recognized_assumptions(approval, presentation, evidence, time) do
    approval.assumptions
    |> Enum.reduce_while({:ok, []}, fn assumption, {:ok, refs} ->
      case assumption_basis(
             assumption,
             approval,
             presentation,
             evidence,
             time,
             MapSet.new([approval.ref]),
             approval.observed_at
           ) do
        {:ok, assumption_refs} ->
          {:cont, {:ok, [assumption_refs | refs]}}

        {:error, _reason} ->
          {:halt, {:error, {:unrecognized_presentation_approval_assumption, assumption}}}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, normalize_basis_refs(refs)}
      {:error, _reason} = error -> error
    end
  end

  defp assumption_basis(
         assumption,
         approval,
         presentation,
         evidence,
         time,
         visited,
         observed_by
       ) do
    supporting =
      assumption_evidence_bases(
        assumption,
        :supports,
        approval,
        presentation,
        evidence,
        time,
        visited,
        observed_by
      )

    contradicting =
      assumption_evidence_bases(
        assumption,
        :contradicts,
        approval,
        presentation,
        evidence,
        time,
        visited,
        time
      )

    if supporting == [] or contradicting != [],
      do: {:error, :assumption_not_supported},
      else: {:ok, normalize_basis_refs(supporting)}
  end

  defp assumption_evidence_bases(
         assumption,
         stance,
         approval,
         presentation,
         evidence,
         time,
         visited,
         observed_by
       ) do
    evidence
    |> Enum.filter(fn
      %Evidence{} = item ->
        item.proposition == assumption and item.stance == stance and item.ref != approval.ref and
          not MapSet.member?(visited, item.ref) and
          valid_assumption_identity?(item, approval, presentation) and
          current_assumption?(item, time, observed_by)

      _other ->
        false
    end)
    |> Enum.sort_by(& &1.ref)
    |> Enum.reduce([], fn item, bases ->
      case qualified_evidence_basis(
             item,
             approval,
             presentation,
             evidence,
             time,
             MapSet.put(visited, item.ref),
             observed_by
           ) do
        {:ok, refs} -> [refs | bases]
        {:error, _reason} -> bases
      end
    end)
  end

  defp qualified_evidence_basis(
         item,
         approval,
         presentation,
         evidence,
         time,
         visited,
         observed_by
       ) do
    item.assumptions
    |> Enum.reduce_while({:ok, [[item.ref]]}, fn nested, {:ok, refs} ->
      case assumption_basis(
             nested,
             approval,
             presentation,
             evidence,
             time,
             visited,
             observed_by
           ) do
        {:ok, nested_refs} -> {:cont, {:ok, [nested_refs | refs]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, normalize_basis_refs(refs)}
      {:error, _reason} = error -> error
    end
  end

  defp valid_assumption_identity?(item, approval, presentation) do
    item.provenance == :observed and not item.provisional and item.parent_refs == [] and
      item.source_ref in presentation.approval_source_refs and
      item.issuer_ref == approval.issuer_ref and
      Map.get(item.bindings, "authenticated_principal_ref") == approval.issuer_ref
  end

  defp current_assumption?(item, time, observed_by) do
    item.observed_at <= observed_by and item.observed_at <= time and
      (is_nil(item.valid_from) or item.valid_from <= time) and
      (is_nil(item.valid_until) or time < item.valid_until) and
      (is_nil(item.freshness_ms) or time - item.observed_at <= item.freshness_ms)
  end

  defp normalize_basis_refs(refs), do: refs |> List.flatten() |> Enum.uniq() |> Enum.sort()
  defp valid_ref?(value), do: is_binary(value) and value != ""
end
