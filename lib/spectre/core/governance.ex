defmodule Spectre.Governance do
  @moduledoc """
  Constructors for administrative Candidates.

  These helpers only make proposals.  They bind proposer and Scope to the
  authenticated handle, force the exact governance Row and construct a
  canonical consequence; they never append, select a Mandate or mint a Grant.
  The returned Candidate must cross normal `Spectre.propose/3` admission.
  Ordinary application classes do not need a helper here and remain declared
  through their Surface contracts.
  """

  require Spectre.Portable

  alias Spectre.{Act, Candidate}
  alias Spectre.Declassification
  alias Spectre.Definition
  alias Spectre.Duty.Disposition
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Evidence
  alias Spectre.Governance.Builder
  alias Spectre.GovernedAct.Class, as: GovernedClass
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.HostProfile
  alias Spectre.Kernel.Meter.Amounts
  alias Spectre.Mandate
  alias Spectre.Portable
  alias Spectre.Principal
  alias Spectre.Scope
  alias Spectre.Scope.Opening
  alias Spectre.SubmissionContext
  alias Spectre.Surface

  @scope_open_class "scope.open"

  @governed_scope_fields [
    :kind,
    :promise_condition,
    :accountable_ref,
    :disposition_authority_refs,
    :due_at
  ]

  @retained_revocation_fields [:identity_key]

  @doc "Stable executor identity used for consequences completed inside the ledger."
  @spec kernel_executor_ref() :: String.t()
  defdelegate kernel_executor_ref(), to: GovernedExecution

  @doc "Stable executor contract used for consequences completed inside the ledger."
  @spec kernel_contract_ref() :: String.t()
  defdelegate kernel_contract_ref(), to: GovernedExecution

  @doc "Stable governed class used to open Work and Vigil scopes."
  @spec scope_open_class() :: String.t()
  def scope_open_class, do: @scope_open_class

  @doc "Exact Row dimensions required by a governed Scope opening."
  @spec scope_open_dimensions() :: [Spectre.Row.dimension()]
  def scope_open_dimensions do
    {:ok, dimensions} = GovernedClass.dimensions(@scope_open_class)
    dimensions
  end

  @doc "Stable, closed purpose used by a retained controller to revoke its exact Mandate."
  @spec retained_revocation_purpose_ref() :: String.t()
  defdelegate retained_revocation_purpose_ref(), to: GovernedClass

  @doc "Builds a governed proposal that registers an immutable Principal without granting power."
  @spec register_principal(Scope.t(), Principal.t() | map() | keyword(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def register_principal(%Scope{} = scope, principal, candidate_attrs) do
    with {:ok, principal} <- Principal.new(principal) do
      Builder.internal(
        scope,
        "principal.register",
        %{"principal_registration" => Principal.canonical(principal)},
        candidate_attrs,
        [principal.ref]
      )
    end
  end

  @doc false
  @spec ledger_internal?(Candidate.t() | Act.t()) :: boolean()
  defdelegate ledger_internal?(record), to: GovernedExecution

  @doc false
  @spec execution_mode(Candidate.t() | Act.t()) ::
          {:ok, :ledger_internal | :executor_mediated} | {:error, term()}
  def execution_mode(record), do: GovernedExecution.mode(record)

  @doc false
  @spec executor_mediated?(Candidate.t() | Act.t()) :: boolean()
  defdelegate executor_mediated?(record), to: GovernedExecution

  @doc false
  @spec execution_boundary(Candidate.t() | Act.t()) :: :ok | {:error, term()}
  def execution_boundary(record), do: GovernedExecution.validate(record)

  @doc "Builds a Work/Vigil opening proposal in an already-open parent Scope."
  @spec open_scope(
          Scope.t(),
          SubmissionContext.t(),
          map() | keyword(),
          map() | keyword()
        ) :: {:ok, Candidate.t()} | {:error, term()}
  def open_scope(
        %Scope{} = parent_scope,
        %SubmissionContext{} = child_context,
        opening_attrs,
        candidate_attrs
      ) do
    with {:ok, child_context} <- SubmissionContext.new(child_context),
         :ok <- child_context_matches_parent_domain(parent_scope, child_context),
         {:ok, opening_attrs} <-
           Portable.normalize_attrs(opening_attrs, @governed_scope_fields, :governed_scope),
         {:ok, draft} <- governed_scope_draft(parent_scope, child_context, opening_attrs) do
      Builder.internal(
        parent_scope,
        @scope_open_class,
        %{"scope_open" => draft},
        candidate_attrs,
        [Map.fetch!(draft, "ref")]
      )
    end
  end

  def open_scope(_parent_scope, _child_context, _opening_attrs, _candidate_attrs),
    do: {:error, :invalid_governed_scope_opening}

  @doc "Builds a subtractive child-Mandate issuance proposal."
  @spec delegate_mandate(Scope.t(), map() | keyword() | Mandate.t(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def delegate_mandate(%Scope{} = scope, mandate, candidate_attrs) do
    with {:ok, draft} <- Mandate.issue_draft(mandate),
         parent_ref when Portable.is_non_empty_binary(parent_ref) <-
           Map.get(draft, "parent_ref") do
      Builder.internal(
        scope,
        "mandate.delegate",
        %{"mandate_issue" => draft},
        candidate_attrs,
        [parent_ref]
      )
    else
      {:error, _reason} = error -> error
      _missing_or_invalid -> {:error, :delegated_mandate_parent_required}
    end
  end

  @doc "Builds a proposal to return all declared free child Meter balances."
  @spec devolve_mandate(Scope.t(), String.t(), map(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def devolve_mandate(%Scope{} = scope, child_mandate_ref, amounts, candidate_attrs)
      when Portable.is_non_empty_binary(child_mandate_ref) and is_map(amounts) and
             not is_struct(amounts) do
    with {:ok, amounts} <- Amounts.non_empty(amounts) do
      Builder.internal(
        scope,
        "mandate.devolve",
        %{
          "mandate_devolve" => %{
            "child_mandate_ref" => child_mandate_ref,
            "amounts" => amounts
          }
        },
        candidate_attrs,
        [child_mandate_ref]
      )
    end
  end

  def devolve_mandate(_scope, _child_ref, _amounts, _candidate_attrs),
    do: {:error, :invalid_mandate_devolution}

  @doc "Builds a proposal for an immutable, strictly narrower Mandate successor."
  @spec restrict_mandate(
          Scope.t(),
          String.t(),
          map() | keyword() | Mandate.t(),
          map() | keyword()
        ) :: {:ok, Candidate.t()} | {:error, term()}
  def restrict_mandate(%Scope{} = scope, predecessor_ref, successor, candidate_attrs)
      when Portable.is_non_empty_binary(predecessor_ref) do
    with {:ok, draft} <- Mandate.issue_draft(successor) do
      Builder.internal(
        scope,
        "mandate.restrict",
        %{
          "mandate_restrict" => %{
            "predecessor_ref" => predecessor_ref,
            "successor" => draft
          }
        },
        candidate_attrs,
        [predecessor_ref]
      )
    end
  end

  def restrict_mandate(_scope, _predecessor_ref, _successor, _candidate_attrs),
    do: {:error, :invalid_mandate_restriction}

  @doc "Builds an immediate, forward-only Mandate revocation proposal."
  @spec revoke_mandate(Scope.t(), Mandate.t() | String.t(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def revoke_mandate(%Scope{} = scope, %Mandate{} = target, candidate_attrs) do
    with {:ok, target} <- Mandate.new(target) do
      case target.revocation do
        %{"mode" => :retained_controller} ->
          retained_revocation_candidate(scope, target, candidate_attrs)

        _ordinary ->
          revoke_mandate(scope, target.ref, candidate_attrs)
      end
    end
  end

  def revoke_mandate(%Scope{} = scope, mandate_ref, candidate_attrs)
      when Portable.is_non_empty_binary(mandate_ref) do
    Builder.internal(
      scope,
      "mandate.revoke",
      %{"mandate_revoke" => %{"mandate_ref" => mandate_ref}},
      candidate_attrs,
      [mandate_ref]
    )
  end

  def revoke_mandate(_scope, _mandate_ref, _candidate_attrs),
    do: {:error, :invalid_mandate_revocation}

  defp retained_revocation_candidate(scope, target, candidate_attrs) do
    with {:ok, attrs} <-
           normalize_attrs(candidate_attrs, @retained_revocation_fields),
         {:ok, row} <- Builder.intrinsic_row("mandate.revoke") do
      attrs =
        Map.merge(attrs, %{
          requested_mandate_ref: target.ref,
          accountable_ref: target.accountable_ref,
          purpose_ref: GovernedClass.retained_revocation_purpose_ref(),
          purpose_params: %{},
          subject_refs: [],
          evidence_refs: [],
          presentation_ref: nil
        })

      Builder.build(
        scope,
        attrs,
        %{
          class: "mandate.revoke",
          consequence: %{"mandate_revoke" => %{"mandate_ref" => target.ref}},
          row: row,
          executor_ref: GovernedExecution.kernel_executor_ref(),
          executor_contract_ref: GovernedExecution.kernel_contract_ref(),
          target_refs: [target.ref],
          meter_requests: %{},
          observation_window_ms: 0
        }
      )
    end
  end

  @doc "Builds an independently authorized Duty disposition proposal."
  @spec dispose_duty(Scope.t(), Disposition.t() | map() | keyword(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def dispose_duty(%Scope{} = scope, disposition, candidate_attrs) do
    with {:ok, disposition} <- Disposition.new(disposition) do
      Builder.internal(
        scope,
        "duty.dispose",
        Disposition.consequence(disposition),
        candidate_attrs,
        [disposition.duty_ref]
      )
    end
  end

  @doc "Builds a governed Surface revision proposal."
  @spec revise_surface(Scope.t(), String.t(), Surface.t() | map() | keyword(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def revise_surface(%Scope{} = scope, previous_ref, surface, candidate_attrs)
      when Portable.is_non_empty_binary(previous_ref) do
    with {:ok, surface} <- Surface.new(surface) do
      Builder.internal(
        scope,
        "surface.revise",
        %{
          "surface_revision" => %{
            "previous_ref" => previous_ref,
            "surface" => Surface.canonical(surface)
          }
        },
        candidate_attrs,
        [previous_ref, surface.ref]
      )
    end
  end

  def revise_surface(_scope, _previous_ref, _surface, _candidate_attrs),
    do: {:error, :invalid_surface_revision}

  @doc "Builds a governed host-profile revision proposal."
  @spec revise_host_profile(
          Scope.t(),
          String.t(),
          HostProfile.t() | map() | keyword(),
          map() | keyword()
        ) :: {:ok, Candidate.t()} | {:error, term()}
  def revise_host_profile(%Scope{} = scope, previous_ref, profile, candidate_attrs)
      when Portable.is_non_empty_binary(previous_ref) do
    with {:ok, profile} <- HostProfile.new(profile) do
      Builder.internal(
        scope,
        "host_profile.revise",
        %{
          "host_profile_revision" => %{
            "previous_ref" => previous_ref,
            "host_profile" => HostProfile.canonical(profile)
          }
        },
        candidate_attrs,
        [previous_ref, profile.ref]
      )
    end
  end

  def revise_host_profile(_scope, _previous_ref, _profile, _candidate_attrs),
    do: {:error, :invalid_host_profile_revision}

  @doc "Builds a governed declarative Definition revision proposal."
  @spec revise_definition(Scope.t(), Definition.t() | map() | keyword(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def revise_definition(%Scope{} = scope, definition, candidate_attrs) do
    with {:ok, definition} <- Definition.new(definition) do
      Builder.internal(
        scope,
        "definition.revise",
        %{
          "definition_revision" => %{
            "previous_ref" => definition.previous_ref,
            "definition" => Definition.canonical(definition)
          }
        },
        candidate_attrs,
        Enum.reject([definition.previous_ref, definition.ref], &is_nil/1)
      )
    end
  end

  @doc "Builds a governed proposal that binds removed labels and their owners as exact targets."
  @spec declassify_evidence(
          Scope.t(),
          Evidence.t() | map() | keyword(),
          [term()],
          map() | keyword()
        ) ::
          {:ok, Candidate.t()} | {:error, term()}
  def declassify_evidence(%Scope{} = scope, evidence, removed_labels, candidate_attrs) do
    with {:ok, evidence} <- Evidence.new(evidence),
         {:ok, evidence} <-
           Declassification.bind_producer(
             evidence,
             scope.context.authenticated_principal_ref
           ),
         {:ok, draft} <- Declassification.draft(evidence, removed_labels),
         {:ok, required_targets} <-
           Declassification.required_target_refs(evidence, draft["removed_labels"]) do
      Builder.internal(
        scope,
        "data.declassify",
        %{"evidence_declassification" => draft},
        candidate_attrs,
        required_targets
      )
    end
  end

  @doc "Builds an executor-mediated erasure request proposal."
  @spec request_erasure(Scope.t(), map(), map() | keyword(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def request_erasure(%Scope{} = scope, facts, request_attrs, candidate_attrs)
      when is_map(facts) do
    with {:ok, request} <-
           normalize_attrs(request_attrs, [:target_ref, :reason, :requested_at]),
         {:ok, target_ref} <- Builder.required_ref(request, :target_ref),
         {:ok, reason} <- Builder.required_binary(request, :reason),
         {:ok, requested_at} <- Builder.required_integer(request, :requested_at),
         :ok <- ErasureAnalysis.requestable?(facts, target_ref),
         {:ok, draft_attrs} <-
           ErasureAnalysis.derive_request(
             facts,
             target_ref,
             Scope.ref(scope),
             reason,
             requested_at
           ),
         {:ok, draft} <- Spectre.Erasure.request_draft(draft_attrs),
         {:ok, row} <- Builder.intrinsic_row("data.erase"),
         {:ok, attrs} <-
           Builder.normalize_attrs(
             candidate_attrs,
             [:executor_ref, :executor_contract_ref, :observation_window_ms]
           ),
         {:ok, executor_ref} <- Builder.required_ref(attrs, :executor_ref),
         {:ok, contract_ref} <- Builder.required_ref(attrs, :executor_contract_ref) do
      Builder.build(
        scope,
        attrs,
        %{
          class: "data.erase",
          consequence: %{"erasure_request" => draft},
          row: row,
          executor_ref: executor_ref,
          executor_contract_ref: contract_ref,
          target_refs:
            Builder.target_refs(attrs, :target_refs, [Map.fetch!(draft, "target_ref")]),
          meter_requests: %{},
          observation_window_ms: Map.get(attrs, :observation_window_ms, 0)
        }
      )
    end
  end

  def request_erasure(_scope, _facts, _request_attrs, _candidate_attrs),
    do: {:error, :invalid_erasure_request}

  defp normalize_attrs(attrs, fields), do: Portable.normalize_attrs(attrs, fields, :governance)

  defp governed_scope_draft(parent_scope, child_context, attrs) do
    attrs
    |> Map.put(:parent_ref, Scope.ref(parent_scope))
    |> Map.merge(Opening.context_bindings(child_context))
    |> Opening.governed_draft()
  end

  defp child_context_matches_parent_domain(parent_scope, child_context) do
    cond do
      child_context.domain_ref != Scope.domain_ref(parent_scope) ->
        {:error, :child_scope_domain_mismatch}

      child_context.host_generation != parent_scope.context.host_generation ->
        {:error, :child_scope_generation_mismatch}

      child_context.scope_ref == Scope.ref(parent_scope) ->
        {:error, :child_scope_ref_must_differ_from_parent}

      true ->
        :ok
    end
  end
end
