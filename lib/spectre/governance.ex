defmodule Spectre.Governance do
  @moduledoc """
  Constructors for administrative Candidates.

  These helpers only make proposals.  They bind proposer and Scope to the
  authenticated handle, force the exact governance Row and construct a
  canonical consequence; they never append, select a Mandate or mint a Grant.
  The returned Candidate must cross normal `Spectre.propose/4` admission.
  """

  alias Spectre.Candidate
  alias Spectre.Declassification
  alias Spectre.Definition
  alias Spectre.Duty.Disposition
  alias Spectre.Erasure.Analysis, as: ErasureAnalysis
  alias Spectre.Evidence
  alias Spectre.HostProfile
  alias Spectre.Mandate
  alias Spectre.Portable
  alias Spectre.Scope
  alias Spectre.Scope.Opening
  alias Spectre.SubmissionContext
  alias Spectre.Surface

  @kernel_executor_ref "spectre:kernel:ledger"
  @kernel_contract_ref "spectre:kernel:ledger:v1"
  @retained_revocation_purpose_ref "spectre:purpose:retained-mandate-revocation:v1"
  @scope_open_class "scope.open"
  @scope_open_dimensions [:write, :govern]
  @ledger_internal_classes [
    "mandate.delegate",
    "mandate.devolve",
    "mandate.restrict",
    "mandate.revoke",
    "duty.dispose",
    "surface.revise",
    "host_profile.revise",
    "definition.revise",
    "data.declassify",
    @scope_open_class
  ]

  @governed_scope_fields [
    :kind,
    :promise_condition,
    :accountable_ref,
    :disposition_authority_refs,
    :due_at
  ]

  @internal_fields [
    :identity_key,
    :requested_mandate_ref,
    :accountable_ref,
    :subject_refs,
    :target_refs,
    :purpose_ref,
    :purpose_params,
    :consent,
    :evidence_refs,
    :presentation_ref
  ]

  @erasure_fields @internal_fields ++
                    [
                      :executor_ref,
                      :executor_contract_ref,
                      :observation_window_ms
                    ]

  @retained_revocation_fields [:identity_key]

  @doc "Stable executor identity used for consequences completed inside the ledger."
  @spec kernel_executor_ref() :: String.t()
  def kernel_executor_ref, do: @kernel_executor_ref

  @doc "Stable executor contract used for consequences completed inside the ledger."
  @spec kernel_contract_ref() :: String.t()
  def kernel_contract_ref, do: @kernel_contract_ref

  @doc "Stable governed class used to open Work and Vigil scopes."
  @spec scope_open_class() :: String.t()
  def scope_open_class, do: @scope_open_class

  @doc "Exact Row dimensions required by a governed Scope opening."
  @spec scope_open_dimensions() :: [Spectre.Row.dimension()]
  def scope_open_dimensions, do: @scope_open_dimensions

  @doc "Stable, closed purpose used by a retained controller to revoke its exact Mandate."
  @spec retained_revocation_purpose_ref() :: String.t()
  def retained_revocation_purpose_ref, do: @retained_revocation_purpose_ref

  @doc false
  @spec ledger_internal?(map()) :: boolean()
  def ledger_internal?(record) when is_map(record) do
    reservations = map_field(record, :reservations) || map_field(record, :meter_requests)

    map_field(record, :executor_ref) == @kernel_executor_ref and
      map_field(record, :executor_contract_ref) == @kernel_contract_ref and
      map_field(record, :observation_window_ms) == 0 and reservations in [%{}, []]
  end

  def ledger_internal?(_record), do: false

  @doc false
  @spec execution_boundary(map()) :: :ok | {:error, term()}
  def execution_boundary(record) when is_map(record) do
    class = map_field(record, :class)

    cond do
      class in @ledger_internal_classes and ledger_internal?(record) ->
        :ok

      class in @ledger_internal_classes ->
        {:error, {:governance_act_not_ledger_internal, class}}

      class == "data.erase" and reserved_kernel_route?(record) ->
        {:error, :executor_mediated_act_uses_kernel_route}

      true ->
        :ok
    end
  end

  def execution_boundary(_record), do: {:error, :invalid_governance_execution_boundary}

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
      internal_candidate(
        parent_scope,
        @scope_open_class,
        %{"scope_open" => draft},
        @scope_open_dimensions,
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
         parent_ref when is_binary(parent_ref) and parent_ref != "" <-
           Map.get(draft, "parent_ref") do
      internal_candidate(
        scope,
        "mandate.delegate",
        %{"mandate_issue" => draft},
        [:delegate, :govern],
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
      when is_binary(child_mandate_ref) and child_mandate_ref != "" and is_map(amounts) and
             not is_struct(amounts) do
    with :ok <- positive_amounts(amounts) do
      internal_candidate(
        scope,
        "mandate.devolve",
        %{
          "mandate_devolve" => %{
            "child_mandate_ref" => child_mandate_ref,
            "amounts" => amounts
          }
        },
        [:delegate, :govern],
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
      when is_binary(predecessor_ref) and predecessor_ref != "" do
    with {:ok, draft} <- Mandate.issue_draft(successor) do
      internal_candidate(
        scope,
        "mandate.restrict",
        %{
          "mandate_restrict" => %{
            "predecessor_ref" => predecessor_ref,
            "successor" => draft
          }
        },
        [:govern],
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

        %{"mode" => "retained_controller"} ->
          retained_revocation_candidate(scope, target, candidate_attrs)

        _ordinary ->
          revoke_mandate(scope, target.ref, candidate_attrs)
      end
    end
  end

  def revoke_mandate(%Scope{} = scope, mandate_ref, candidate_attrs)
      when is_binary(mandate_ref) and mandate_ref != "" do
    internal_candidate(
      scope,
      "mandate.revoke",
      %{"mandate_revoke" => %{"mandate_ref" => mandate_ref}},
      [:govern],
      candidate_attrs,
      [mandate_ref]
    )
  end

  def revoke_mandate(_scope, _mandate_ref, _candidate_attrs),
    do: {:error, :invalid_mandate_revocation}

  defp retained_revocation_candidate(scope, target, candidate_attrs) do
    with {:ok, attrs} <-
           normalize_attrs(candidate_attrs, @retained_revocation_fields) do
      attrs =
        Map.merge(attrs, %{
          requested_mandate_ref: target.ref,
          accountable_ref: target.accountable_ref,
          purpose_ref: @retained_revocation_purpose_ref,
          purpose_params: %{},
          subject_refs: [],
          evidence_refs: [],
          presentation_ref: nil
        })

      candidate(
        scope,
        attrs,
        %{
          class: "mandate.revoke",
          consequence: %{"mandate_revoke" => %{"mandate_ref" => target.ref}},
          row: row([:govern]),
          executor_ref: @kernel_executor_ref,
          executor_contract_ref: @kernel_contract_ref,
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
      internal_candidate(
        scope,
        "duty.dispose",
        Disposition.consequence(disposition),
        [:govern],
        candidate_attrs,
        [disposition.duty_ref]
      )
    end
  end

  @doc "Builds a governed Surface revision proposal."
  @spec revise_surface(Scope.t(), String.t(), Surface.t() | map() | keyword(), map() | keyword()) ::
          {:ok, Candidate.t()} | {:error, term()}
  def revise_surface(%Scope{} = scope, previous_ref, surface, candidate_attrs)
      when is_binary(previous_ref) and previous_ref != "" do
    with {:ok, surface} <- Surface.new(surface) do
      internal_candidate(
        scope,
        "surface.revise",
        %{
          "surface_revision" => %{
            "previous_ref" => previous_ref,
            "surface" => Surface.canonical(surface)
          }
        },
        [:govern],
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
      when is_binary(previous_ref) and previous_ref != "" do
    with {:ok, profile} <- HostProfile.new(profile) do
      internal_candidate(
        scope,
        "host_profile.revise",
        %{
          "host_profile_revision" => %{
            "previous_ref" => previous_ref,
            "host_profile" => HostProfile.canonical(profile)
          }
        },
        [:govern],
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
      internal_candidate(
        scope,
        "definition.revise",
        %{
          "definition_revision" => %{
            "previous_ref" => definition.previous_ref,
            "definition" => Definition.canonical(definition)
          }
        },
        [:govern],
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
         {:ok, draft} <- Declassification.draft(evidence, removed_labels),
         {:ok, required_targets} <-
           Declassification.required_target_refs(evidence, draft["removed_labels"]) do
      internal_candidate(
        scope,
        "data.declassify",
        %{"evidence_declassification" => draft},
        [:write, :govern],
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
         {:ok, target_ref} <- required_ref(request, :target_ref),
         {:ok, reason} <- required_binary(request, :reason),
         {:ok, requested_at} <- required_integer(request, :requested_at),
         :ok <- ErasureAnalysis.requestable?(facts, target_ref),
         {:ok, draft_attrs} <-
           ErasureAnalysis.derive_request(
             facts,
             target_ref,
             scope.ref,
             reason,
             requested_at
           ),
         {:ok, draft} <- Spectre.Erasure.request_draft(draft_attrs),
         {:ok, attrs} <- normalize_attrs(candidate_attrs, @erasure_fields),
         {:ok, executor_ref} <- required_ref(attrs, :executor_ref),
         {:ok, contract_ref} <- required_ref(attrs, :executor_contract_ref) do
      candidate(
        scope,
        attrs,
        %{
          class: "data.erase",
          consequence: %{"erasure_request" => draft},
          row: row([:attempt, :write, :govern]),
          executor_ref: executor_ref,
          executor_contract_ref: contract_ref,
          target_refs: required_refs(attrs, :target_refs, [Map.fetch!(draft, "target_ref")]),
          meter_requests: %{},
          observation_window_ms: Map.get(attrs, :observation_window_ms, 0)
        }
      )
    end
  end

  def request_erasure(_scope, _facts, _request_attrs, _candidate_attrs),
    do: {:error, :invalid_erasure_request}

  defp internal_candidate(scope, class, consequence, dimensions, candidate_attrs, targets) do
    with {:ok, attrs} <- normalize_attrs(candidate_attrs, @internal_fields) do
      candidate(
        scope,
        attrs,
        %{
          class: class,
          consequence: consequence,
          row: row(dimensions),
          executor_ref: @kernel_executor_ref,
          executor_contract_ref: @kernel_contract_ref,
          target_refs: required_refs(attrs, :target_refs, targets),
          meter_requests: %{},
          observation_window_ms: 0
        }
      )
    end
  end

  defp candidate(scope, attrs, forced) do
    with {:ok, identity_key} <- required_binary(attrs, :identity_key),
         {:ok, mandate_ref} <- required_ref(attrs, :requested_mandate_ref),
         {:ok, accountable_ref} <- required_ref(attrs, :accountable_ref),
         {:ok, purpose_ref} <- required_ref(attrs, :purpose_ref) do
      Candidate.new(%{
        identity_key: identity_key,
        class: forced.class,
        consequence: forced.consequence,
        row: forced.row,
        requested_mandate_ref: mandate_ref,
        proposer_ref: scope.context.authenticated_principal_ref,
        executor_ref: forced.executor_ref,
        accountable_ref: accountable_ref,
        scope_ref: scope.ref,
        subject_refs: Map.get(attrs, :subject_refs, []),
        target_refs: forced.target_refs,
        purpose_ref: purpose_ref,
        purpose_params: Map.get(attrs, :purpose_params, %{}),
        consent: Map.get(attrs, :consent),
        evidence_refs: Map.get(attrs, :evidence_refs, []),
        presentation_ref: Map.get(attrs, :presentation_ref),
        meter_requests: forced.meter_requests,
        executor_contract_ref: forced.executor_contract_ref,
        observation_window_ms: forced.observation_window_ms
      })
    end
  end

  defp normalize_attrs(attrs, fields), do: Portable.normalize_attrs(attrs, fields, :governance)

  defp governed_scope_draft(parent_scope, child_context, attrs) do
    attrs
    |> Map.merge(%{
      ref: child_context.scope_ref,
      domain_ref: child_context.domain_ref,
      parent_ref: parent_scope.ref,
      opened_by_ref: child_context.authenticated_principal_ref,
      submission_context_ref: child_context.ref,
      authentication_ref: child_context.authentication_ref,
      ingress_ref: child_context.ingress_ref,
      channel_ref: child_context.channel_ref,
      session_ref: child_context.session_ref,
      host_generation: child_context.host_generation
    })
    |> Opening.governed_draft()
  end

  defp child_context_matches_parent_domain(parent_scope, child_context) do
    cond do
      child_context.domain_ref != parent_scope.domain.ref ->
        {:error, :child_scope_domain_mismatch}

      child_context.host_generation != parent_scope.context.host_generation ->
        {:error, :child_scope_generation_mismatch}

      child_context.scope_ref == parent_scope.ref ->
        {:error, :child_scope_ref_must_differ_from_parent}

      true ->
        :ok
    end
  end

  defp required_ref(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:missing_governance_candidate_field, key}}
    end
  end

  defp required_binary(attrs, key), do: required_ref(attrs, key)

  defp required_integer(attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) -> {:ok, value}
      _missing -> {:error, {:missing_governance_candidate_field, key}}
    end
  end

  defp required_refs(attrs, key, required) do
    attrs
    |> Map.get(key, [])
    |> List.wrap()
    |> Kernel.++(required)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp positive_amounts(amounts) do
    if map_size(amounts) > 0 and
         Enum.all?(amounts, fn {ref, quantity} ->
           is_binary(ref) and ref != "" and is_integer(quantity) and quantity > 0
         end) do
      :ok
    else
      {:error, :invalid_mandate_devolution_amounts}
    end
  end

  defp row(dimensions) do
    Map.new(~w(attempt observe read write disclose spend delegate govern present), fn dimension ->
      {dimension, String.to_existing_atom(dimension) in dimensions}
    end)
  end

  defp reserved_kernel_route?(record) do
    map_field(record, :executor_ref) == @kernel_executor_ref or
      map_field(record, :executor_contract_ref) == @kernel_contract_ref
  end

  defp map_field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
