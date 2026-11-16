defmodule Spectre.Server.GAM.Managed.Reviewer do
  @moduledoc false

  alias Spectre.GAM
  alias Spectre.GAM.Canonical.Value
  alias Spectre.GAM.Domain.Sequencer
  alias Spectre.GAM.Duty.Disposition
  alias Spectre.GAM.GovernedAct.Execution
  alias Spectre.GAM.Scope.Opening
  alias Spectre.Server.GAM.Managed.{Gate, Identity}

  @authorization_end 253_402_300_799_999

  @doc false
  @spec normalize(keyword()) :: {:ok, keyword()} | {:error, atom()}
  def normalize(opts) do
    case Keyword.fetch(opts, :reviewer) do
      :error -> {:ok, opts}
      {:ok, config} -> normalize_config(config, opts)
    end
  end

  @spec normalize_config(term(), keyword()) :: {:ok, keyword()} | {:error, atom()}
  defp normalize_config(config, opts) when is_list(config) do
    with true <- Keyword.keyword?(config),
         true <- Keyword.keys(config) -- [:consumer, :identity, :expires_at] == [],
         true <- length(Keyword.keys(config)) == length(Enum.uniq(Keyword.keys(config))),
         expires_at = Keyword.get(config, :expires_at, @authorization_end),
         true <- is_integer(expires_at) and expires_at > 0 and expires_at <= @authorization_end,
         consumer when is_pid(consumer) <- config[:consumer],
         {:ok, identity} <- Identity.normalize(config[:identity]),
         true <- represented_identity?(identity),
         false <- consumer == opts[:consumer],
         false <- same_actor?(identity, opts[:identity] || %{}) do
      {:ok,
       Keyword.put(opts, :reviewer,
         identity: identity,
         consumer: consumer,
         expires_at: expires_at
       )}
    else
      _ -> {:error, :independent_reviewer_required}
    end
  end

  defp normalize_config(_, _), do: {:error, :invalid_managed_reviewer}

  @spec represented_identity?(map()) :: boolean()
  defp represented_identity?(identity),
    do:
      not is_nil(identity[:subject] || identity[:task]) and
        (identity[:subject] || identity[:task]) != ""

  @spec same_actor?(map(), map()) :: boolean()
  defp same_actor?(reviewer, actor) do
    reviewer == actor or
      (not is_nil(reviewer[:subject]) and reviewer[:subject] == actor[:subject]) or
      (is_nil(reviewer[:subject]) and not is_nil(reviewer[:task]) and
         reviewer[:task] == actor[:task])
  end

  @doc false
  @spec identity(keyword()) :: map() | nil
  def identity(opts), do: get_in(opts, [:reviewer, :identity])

  @doc false
  @spec authority(keyword()) :: map() | nil
  def authority(opts) do
    if identity(opts),
      do: %{
        identity: identity(opts),
        expires_at: Keyword.get(opts[:reviewer], :expires_at, @authorization_end)
      },
      else: nil
  end

  @doc false
  @spec principal(binary(), keyword()) :: GAM.Principal.t()
  def principal(prefix, opts) do
    identity = identity(opts)

    attributes =
      if identity,
        do: %{"name" => prefix <> "reviewer", "identity_digest" => Value.digest!(identity)},
        else: %{"name" => prefix <> "unassigned-reviewer", "available" => false}

    {:ok, principal} =
      GAM.Principal.new(%{
        kind: if(identity && identity[:subject], do: :human, else: :service),
        attributes: attributes
      })

    principal
  end

  @doc false
  @spec mandate(keyword(), map(), GAM.Principal.t(), GAM.Mandate.t()) ::
          {:ok, GAM.Mandate.t() | nil} | {:error, term()}
  def mandate(opts, refs, reviewer, operation_mandate) do
    if identity(opts) do
      GAM.Mandate.new(%{
        revision: 1,
        grantor_ref: reviewer.ref,
        holder_ref: reviewer.ref,
        accountable_ref: reviewer.ref,
        executor_refs: [Execution.kernel_executor_ref()],
        executor_contract_refs: [Execution.kernel_contract_ref()],
        scope_refs: [refs.scope <> ":reviewer"],
        subject_refs: [],
        target_refs: [operation_mandate.ref],
        classes: ["duty.dispose"],
        ceiling: %{govern: true},
        purpose_ref: refs.purpose <> ":duty-review",
        purpose_params: %{},
        conditions: [],
        not_before: operation_mandate.not_before,
        expires_at: Keyword.get(opts[:reviewer], :expires_at, @authorization_end),
        meters: %{},
        delegation: %{"allowed" => false, "max_depth" => 0},
        revocation: %{"mode" => :retained_controller, "controller_refs" => [reviewer.ref]},
        source_ref: refs.genesis
      })
    else
      {:ok, nil}
    end
  end

  @doc false
  @spec open(pid(), map(), pid(), keyword()) :: {:ok, map() | nil} | {:error, term()}
  def open(_domain, %{reviewer_mandate: nil}, _owner, _opts), do: {:ok, nil}

  def open(domain, host, owner, opts) do
    scope_ref = host.refs.scope <> ":reviewer"
    token = :crypto.strong_rand_bytes(32)

    with {:ok, gate} <- start_gate(host, owner, opts, scope_ref, token) do
      case open_scope(domain, host, scope_ref, gate, token) do
        {:ok, scope} ->
          {:ok, %{scope: scope, gate: gate, consumer: opts[:reviewer][:consumer]}}

        {:error, _} = error ->
          GenServer.stop(gate)
          error
      end
    end
  end

  @spec start_gate(map(), pid(), keyword(), binary(), binary()) :: GenServer.on_start()
  defp start_gate(host, owner, opts, scope_ref, token) do
    Gate.start_link(%{
      owner: owner,
      token: token,
      consumer: opts[:reviewer][:consumer],
      runtime: opts[:runtime],
      show_timeout: 20_000,
      auth: %{
        domain: host.refs.domain,
        scope: scope_ref,
        principal: host.reviewer_principal.ref,
        authentication: scope_ref <> ":authentication",
        session: scope_ref <> ":session"
      }
    })
  end

  @spec open_scope(pid(), map(), binary(), pid(), binary()) ::
          {:ok, GAM.Scope.t()} | {:error, term()}
  defp open_scope(domain, host, scope_ref, gate, token) do
    with {:ok, context} <- Sequencer.authenticate(domain, scope_ref, %{gate: gate, token: token}),
         {:ok, opening} <-
           Opening.new(
             Map.merge(
               %{
                 ref: scope_ref,
                 domain_ref: host.refs.domain,
                 kind: :session,
                 opened_at: host.issued_at,
                 disposition_authority_refs: []
               },
               Opening.context_bindings(context)
             )
           ),
         {:ok, _} <- Sequencer.open_scope(domain, context, opening) do
      GAM.Scope.new(GAM.Domain.handle(domain, host.refs.domain), context)
    end
  end

  @doc false
  @spec dispose(map(), binary(), Disposition.kind(), keyword(), pid()) ::
          {:ok, GAM.Proposal.Result.t()} | {:error, term()}
  def dispose(%{reviewer: nil}, _ref, _kind, _options, _caller),
    do: {:error, :reviewer_not_configured}

  def dispose(state, ref, kind, options, caller) do
    with true <- caller == state.reviewer.consumer,
         :ok <- disposition_options(options),
         {:ok, view} <-
           GAM.Facade.Access.scoped_query(
             state.scope,
             {:selected_view, %{duty_ref: ref, evidence_refs: options[:supporting_refs]}}
           ),
         %GAM.Duty{} = duty <- Enum.find(view.duties, &(&1.ref == ref)),
         {:ok, disposition} <-
           Disposition.for_duty(
             duty,
             kind,
             options[:supporting_refs],
             Keyword.get(options, :meter_resolution, :none)
           ) do
      evidence_refs =
        view.evidence
        |> Enum.filter(&(&1.ref in disposition.supporting_refs))
        |> Enum.map(& &1.ref)

      GAM.dispose_duty(state.reviewer.scope, disposition, %{
        identity_key:
          "spectre:managed:disposition:" <> Value.digest!(Disposition.canonical(disposition)),
        requested_mandate_ref: state.reviewer_mandate.ref,
        accountable_ref: state.reviewer_principal.ref,
        purpose_ref: state.reviewer_mandate.purpose_ref,
        evidence_refs: evidence_refs
      })
    else
      false -> {:error, :untrusted_reviewer_transport}
      nil -> {:error, :duty_not_found}
      {:error, _} = error -> error
    end
  end

  @spec disposition_options(term()) :: :ok | {:error, atom()}
  defp disposition_options(options) when is_list(options) do
    if Keyword.keyword?(options) and
         Keyword.keys(options) -- [:supporting_refs, :meter_resolution] == [] and
         length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) and
         is_list(options[:supporting_refs]) and options[:supporting_refs] != [],
       do: :ok,
       else: {:error, :invalid_duty_disposition_options}
  end

  defp disposition_options(_), do: {:error, :invalid_duty_disposition_options}
end
