defmodule Spectre.Server.GAM.Managed.Bootstrap do
  @moduledoc false
  alias Spectre.GAM
  alias Spectre.GAM.Canonical.Value
  alias Spectre.GAM.Consequence.Contract
  alias Spectre.GAM.Domain.Sequencer
  alias Spectre.GAM.Governance.Builder, as: GovernanceBuilder
  alias Spectre.GAM.GovernedAct.{Class, State}
  alias Spectre.GAM.Ledger.Store.Disk, as: LedgerDisk
  alias Spectre.GAM.Ledger.Store.ETS, as: LedgerETS
  alias Spectre.GAM.Scope.Opening
  alias Spectre.Server.GAM.{Effect, Managed}

  alias Spectre.Server.GAM.Managed.{
    Authority,
    Binding,
    Broker,
    Executor,
    Gate,
    Ingress,
    Mind,
    Reviewer,
    StorageLock
  }

  alias Spectre.Server.Store.Disk, as: ServerDisk

  # The kernel requires an integer deadline. This is the final UTC millisecond
  # supported by Elixir DateTime, not a recurring lease renewed by restart.
  @authorization_end 253_402_300_799_999
  @max_timer_ms 4_294_967_295

  @doc false
  @spec open(keyword(), pid()) :: {:ok, map()} | {:error, term()}
  def open(opts, owner) do
    with {:ok, opts} <- Reviewer.normalize(opts),
         :ok <- configuration(opts),
         :ok <- coherent_storage(opts),
         operations when is_map(operations) <- Keyword.get(opts, :operations, %{}),
         {:ok, effects} <- effects(opts[:agent], operations),
         :ok <- Binding.validate_overrides(effects, Keyword.get(opts, :bindings, %{})),
         {:ok, storage} <- storage(opts, effects),
         {:ok, host} <- foundation(opts, storage, effects),
         {:ok, gate} <- gate(opts, owner, host),
         {:ok, domain} <- domain(host, gate, owner, opts),
         :ok <- verify_foundation(domain, host),
         {:ok, context} <-
           Sequencer.authenticate(domain, host.refs.scope, %{gate: gate, token: host.token}),
         {:ok, scope} <- open_scope(domain, host, context),
         {:ok, reviewer} <- Reviewer.open(domain, host, owner, opts) do
      {:ok,
       Map.merge(host, %{
         scope: scope,
         reviewer: reviewer,
         owned: host.owned ++ if(reviewer, do: [reviewer.gate], else: []),
         domain: domain,
         gate: gate,
         effects: effects,
         operations: operations,
         options: opts,
         owner: owner
       })}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_managed_gam_configuration}
    end
  end

  @spec configuration(keyword()) :: :ok | {:error, atom()}
  defp configuration(opts) do
    expires_at = Keyword.get(opts, :expires_at, @authorization_end)

    cond do
      Keyword.has_key?(opts, :authority) ->
        {:error, :managed_authority_selector_removed}

      not is_map(Keyword.get(opts, :identity, %{})) ->
        {:error, :invalid_managed_identity}

      not is_integer(expires_at) or expires_at <= 0 or
          expires_at > @authorization_end ->
        {:error, :invalid_managed_authorization_deadline}

      true ->
        timeout_options(opts)
    end
  end

  @spec timeout_options(keyword()) :: :ok | {:error, atom()}
  defp timeout_options(opts) do
    cond do
      not timer_timeout?(Keyword.get(opts, :show_timeout, 20_000)) ->
        {:error, :invalid_managed_show_timeout}

      not timer_timeout?(Keyword.get(opts, :shutdown_timeout, 30_000)) ->
        {:error, :invalid_managed_shutdown_timeout}

      not consent_ttl?(Keyword.get(opts, :consent_ttl_ms, 300_000)) ->
        {:error, :invalid_managed_consent_ttl}

      true ->
        :ok
    end
  end

  @spec timer_timeout?(term()) :: boolean()
  defp timer_timeout?(value),
    do: is_integer(value) and value > 0 and value <= @max_timer_ms

  @spec consent_ttl?(term()) :: boolean()
  defp consent_ttl?(value), do: value == :infinity or (is_integer(value) and value > 0)

  @spec coherent_storage(keyword()) :: :ok | {:error, atom()}
  defp coherent_storage(opts) do
    ephemeral? = Keyword.get(opts, :storage, :ephemeral) == :ephemeral
    external_store? = Keyword.has_key?(opts, :store)
    checkpoint? = not is_nil(Keyword.get(Keyword.get(opts, :options, []), :checkpoint))

    if ephemeral? and (external_store? or checkpoint?),
      do: {:error, :managed_ephemeral_storage_cannot_recover_external_state},
      else: :ok
  end

  @spec effects(module(), map()) :: {:ok, map()} | {:error, term()}
  defp effects(agent, operations) do
    Enum.reduce_while(operations, {:ok, %{}}, fn entry, {:ok, acc} ->
      case effect_entry(agent, entry) do
        {:ok, operation, value} -> {:cont, {:ok, Map.put(acc, operation, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @spec effect_entry(module(), {term(), keyword()}) :: {:ok, term(), map()} | {:error, term()}
  defp effect_entry(agent, {operation, settings}) do
    with :ok <- validate_settings(settings),
         {:ok, effect} <- Effect.resolve(agent, operation, %{}, %{agent: agent}) do
      class = Keyword.get(settings, :class, "spectre.effect." <> Value.digest!(operation))

      if is_binary(class) and class != "" and not Class.intrinsic?(class),
        do: {:ok, operation, %{effect: effect, class: class, settings: settings}},
        else: {:error, :invalid_managed_effect_class}
    end
  end

  @spec validate_settings(term()) :: :ok | {:error, atom()}
  defp validate_settings(settings) when is_list(settings) do
    allowed = [:confirm, :class, :message, :expires_in]

    if Keyword.keyword?(settings) and
         length(Keyword.keys(settings)) == length(Enum.uniq(Keyword.keys(settings))) and
         Keyword.keys(settings) -- allowed == [] and
         is_boolean(Keyword.get(settings, :confirm, false)) and
         is_binary(Keyword.get(settings, :message, "")) and
         (is_nil(settings[:expires_in]) or
            (is_integer(settings[:expires_in]) and settings[:expires_in] > 0)),
       do: :ok,
       else: {:error, :invalid_managed_operation_options}
  end

  defp validate_settings(_), do: {:error, :invalid_managed_operation_options}

  @spec storage(keyword(), map()) :: {:ok, map()} | {:error, term()}
  defp storage(opts, effects) do
    domain =
      Keyword.get(
        opts,
        :domain,
        "managed:" <> Value.digest!(%{agent: opts[:agent], identity: opts[:identity]})
      )

    digest =
      Value.digest!(%{
        domain: domain,
        identity: opts[:identity],
        reviewer_authority: Reviewer.authority(opts),
        purpose: opts[:purpose],
        expires_at: Keyword.get(opts, :expires_at, @authorization_end),
        bindings: Keyword.get(opts, :bindings, %{}),
        effects:
          Map.new(effects, fn {op, value} ->
            {op, %{contract: value.effect.contract_ref, settings: value.settings}}
          end)
      })

    if is_binary(domain) and domain != "",
      do: allocate_storage(Keyword.get(opts, :storage, :ephemeral), domain, digest, opts),
      else: {:error, :invalid_managed_domain}
  end

  @spec allocate_storage(term(), binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  defp allocate_storage(:ephemeral, domain, digest, _opts) do
    with {:ok, ledger} <- LedgerETS.start_link(),
         {:ok, journal} <- Managed.Store.start_link([]) do
      {:ok,
       %{
         domain: domain,
         issued_at: System.system_time(:millisecond),
         digest: digest,
         ledger: ledger,
         store: {LedgerETS, server: ledger},
         journal: {Managed.Store, journal},
         owned: [ledger, journal],
         ephemeral: true
       }}
    end
  end

  defp allocate_storage({:disk, path}, domain, digest, opts) when is_binary(path),
    do: disk_storage(path, domain, digest, opts)

  defp allocate_storage(_, _, _, _), do: {:error, :invalid_managed_storage}

  @spec disk_storage(binary(), binary(), binary(), keyword()) :: {:ok, map()} | {:error, term()}
  defp disk_storage(path, domain, digest, opts) do
    with :ok <- File.mkdir_p(path),
         {:ok, lock} <- StorageLock.start_link(Keyword.put(opts, :path, path)) do
      case locked_disk_storage(path, domain, digest, lock) do
        {:ok, _} = result ->
          result

        {:error, _} = error ->
          GenServer.stop(lock)
          error
      end
    end
  end

  @spec locked_disk_storage(binary(), binary(), binary(), pid()) ::
          {:ok, map()} | {:error, term()}
  defp locked_disk_storage(path, domain, digest, lock) do
    with {:ok, ledger} <- LedgerDisk.start_link(path: Path.join(path, "gam")) do
      result =
        with {:ok, issued_at} <- initial_time(Path.join(path, "authority.profile"), digest),
             {:ok, journal} <-
               ServerDisk.start_link(path: Path.join(path, "commands.store")) do
          {:ok,
           %{
             domain: domain,
             issued_at: issued_at,
             digest: digest,
             ledger: ledger,
             store: {LedgerDisk, server: ledger},
             journal: {ServerDisk, journal},
             owned: [ledger, journal, lock],
             ephemeral: false
           }}
        end

      case result do
        {:ok, _} ->
          result

        error ->
          GenServer.stop(ledger)
          error
      end
    end
  end

  @spec initial_time(binary(), binary()) :: {:ok, integer()} | {:error, term()}
  defp initial_time(path, digest) do
    case File.read(path) do
      {:ok, body} ->
        parse_profile(body, digest)

      {:error, :enoent} ->
        now = System.system_time(:millisecond)

        with :ok <-
               File.write(path, digest <> "\n" <> Integer.to_string(now) <> "\n", [
                 :exclusive,
                 :sync
               ]),
             do: {:ok, now}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec parse_profile(binary(), binary()) :: {:ok, integer()} | {:error, atom()}
  defp parse_profile(body, digest) do
    case String.split(String.trim(body), "\n") do
      [^digest, time] -> parse_profile_time(time)
      _ -> {:error, :managed_authority_configuration_changed}
    end
  end

  @spec parse_profile_time(binary()) :: {:ok, integer()} | {:error, atom()}
  defp parse_profile_time(time) do
    case Integer.parse(time) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :invalid_managed_authority_profile}
    end
  end

  @spec foundation(keyword(), map(), map()) :: {:ok, map()} | {:error, term()}
  defp foundation(opts, storage, effects) do
    prefix = "spectre:managed:" <> Value.digest!(storage.domain) <> ":"
    actor = actor(prefix, Keyword.get(opts, :identity, %{}))
    accountable = principal(:organization, prefix <> "application")
    reviewer = Reviewer.principal(prefix, opts)

    refs = %{
      domain: storage.domain,
      scope: prefix <> "scope",
      target: prefix <> "target",
      subject: prefix <> "subject",
      purpose: Keyword.get(opts, :purpose, "spectre:managed:application"),
      genesis: prefix <> "genesis",
      attestation: prefix <> "application-configuration-attestation",
      grantor: accountable.ref,
      proposer: actor.ref,
      accountable: accountable.ref,
      executor: Executor.executor_ref(),
      contract: Executor.contract_ref()
    }

    classes = Enum.map(effects, fn {_, value} -> value.class end)

    with :ok <- authorization_window(opts, storage),
         true <- length(Enum.uniq(classes)) == length(classes),
         {:ok, row} <- GAM.Row.new(%{attempt: true, write: true, disclose: true}),
         {:ok, revoke_row} <- GovernanceBuilder.intrinsic_row("mandate.revoke"),
         {:ok, dispose_row} <- GovernanceBuilder.intrinsic_row("duty.dispose"),
         {:ok, contract} <-
           Contract.new(%{
             shape: %{
               "payload" => "portable",
               "subject_ref" => "subject_ref",
               "target_ref" => "target_ref",
               "destination_ref" => "destination_ref",
               "effect_contract_ref" => "portable",
               "execution_identity" => "portable",
               "bound" => "portable",
               "managed_policy" => "portable",
               "execution_context" => "portable"
             }
           }),
         {:ok, surface} <-
           GAM.Surface.new(%{
             revision: 1,
             declarations:
               Map.merge(Map.new(classes, &{&1, row}), %{
                 "presentation.show" => GAM.Presentation.show_row(),
                 "mandate.revoke" => revoke_row,
                 "duty.dispose" => dispose_row
               }),
             presentation_required_classes:
               for(
                 {_op, %{class: class, settings: settings}} <- effects,
                 Keyword.get(settings, :confirm, false),
                 do: class
               ),
             consequence_contracts: Map.new(classes, &{&1, contract})
           }),
         {:ok, profile} <-
           GAM.HostProfile.new(%{
             mode: :mediated,
             attestation_ref: prefix <> "host",
             declared_at: storage.issued_at,
             assumptions: [
               "Trusted application configuration declares the allowed operations and their limits",
               actor_assumption(actor),
               if(storage.ephemeral,
                 do:
                   "Ephemeral record: loss of this process ends this domain; no durable recovery claim",
                 else:
                   "Local durable record and capability claims share the configured storage boundary"
               ),
               "Same-BEAM mediated boundary; trusted application callbacks; no OS-level isolation claim"
             ]
           }) do
      constitution = %{
        "duty_rules" =>
          Map.new(
            ~w(ambiguous_outcome contradicted_outcome disputed_evidence scope_promise_overdue erasure_reduces_verifiability),
            &{&1, %{"disposition_authority_refs" => [reviewer.ref]}}
          )
      }

      with {:ok, mandate} <-
             GAM.Mandate.new(%{
               revision: 1,
               grantor_ref: accountable.ref,
               holder_ref: actor.ref,
               accountable_ref: accountable.ref,
               executor_refs: [refs.executor],
               executor_contract_refs: [refs.contract],
               scope_refs: [refs.scope],
               subject_refs: [refs.subject],
               target_refs: [refs.target, actor.ref],
               classes: classes ++ ["presentation.show"],
               ceiling: %{row | present: true},
               purpose_ref: refs.purpose,
               purpose_params: %{"managed_contract_digest" => storage.digest},
               conditions: [],
               not_before: storage.issued_at - 1000,
               expires_at: Keyword.get(opts, :expires_at, @authorization_end),
               meters: %{},
               delegation: %{"allowed" => false, "max_depth" => 0},
               revocation: %{
                 "mode" => :retained_controller,
                 "controller_refs" => [accountable.ref, actor.ref]
               },
               source_ref: refs.genesis
             }),
           {:ok, reviewer_mandate} <- Reviewer.mandate(opts, refs, reviewer, mandate),
           mandates = [mandate | List.wrap(reviewer_mandate)],
           principals = [actor, accountable, Executor.principal(), reviewer],
           {:ok, genesis} <-
             GAM.Genesis.new(%{
               ref: refs.genesis,
               domain_ref: refs.domain,
               principal_refs: Enum.map(principals, & &1.ref),
               root_mandate_refs: Enum.map(mandates, & &1.ref),
               constitution_ref: GAM.Constitution.ref!(constitution),
               surface_ref: surface.ref,
               surface_revision: 1,
               host_profile_ref: profile.ref,
               emergency_mandate_ref: nil,
               issued_at: storage.issued_at,
               attestation_ref: refs.attestation
             }) do
        {:ok,
         Map.merge(storage, %{
           refs: refs,
           row: row,
           mandate: mandate,
           mandates: mandates,
           reviewer_principal: reviewer,
           reviewer_mandate: reviewer_mandate,
           surface: surface,
           profile: profile,
           genesis: genesis,
           constitution: constitution,
           principals: principals,
           token: :crypto.strong_rand_bytes(32)
         })}
      end
    else
      false -> {:error, :duplicate_managed_effect_class}
      {:error, _} = error -> error
    end
  end

  @spec authorization_window(keyword(), map()) :: :ok | {:error, atom()}
  defp authorization_window(opts, storage) do
    # Recovery must remain possible after expiry so that outcomes and Duties
    # remain inspectable. Admission checks the deadline against current time.
    if Keyword.get(opts, :expires_at, @authorization_end) > storage.issued_at,
      do: :ok,
      else: {:error, :invalid_managed_authorization_deadline}
  end

  @spec gate(keyword(), pid(), map()) :: GenServer.on_start()
  defp gate(opts, owner, host) do
    Gate.start_link(%{
      owner: owner,
      token: host.token,
      consumer: opts[:consumer],
      runtime: opts[:runtime],
      show_timeout: Keyword.get(opts, :show_timeout, 20_000),
      auth: %{
        domain: host.refs.domain,
        scope: host.refs.scope,
        principal: host.refs.proposer,
        authentication: host.refs.scope <> ":authentication",
        session: host.refs.scope <> ":session"
      }
    })
  end

  @spec domain(map(), pid(), pid(), keyword()) :: GenServer.on_start()
  defp domain(host, gate, owner, opts) do
    receipt_secret = :crypto.strong_rand_bytes(32)
    grant_secret = :crypto.strong_rand_bytes(32)

    broker_options = [
      domain_ref: host.refs.domain,
      checkout_receipt_secret: receipt_secret,
      store: host.journal
    ]

    GAM.Domain.start_link(
      domain_ref: host.refs.domain,
      store: host.store,
      ingress: Ingress,
      mind: Mind,
      executors: [
        {Executor,
         managed: owner,
         gate: gate,
         broker: broker_options,
         show_timeout: Keyword.get(opts, :show_timeout, 20_000)}
      ],
      generation: 1,
      checkout_receipt_secret: receipt_secret,
      grant_secret: grant_secret,
      broker: {Broker, broker_options},
      clock: GAM.Clock.System,
      id_source: GAM.Id.UUIDv7,
      constitution: host.constitution,
      genesis: host.genesis,
      principals: host.principals,
      host_profile: host.profile,
      surface: host.surface,
      root_mandates: host.mandates,
      genesis_verifier: {Authority, genesis_digest: GAM.Genesis.digest(host.genesis)}
    )
  end

  @spec verify_foundation(pid(), map()) :: :ok | {:error, atom()}
  defp verify_foundation(domain, host) do
    projection = Sequencer.projection(domain)

    if projection.catalog.genesis == host.genesis and
         State.surface(projection) == host.surface and
         Enum.all?(host.mandates, &(Map.get(projection.mandates, &1.ref) == &1)),
       do: :ok,
       else: {:error, :managed_authority_configuration_changed}
  end

  @spec open_scope(pid(), map(), GAM.SubmissionContext.t()) ::
          {:ok, GAM.Scope.t()} | {:error, term()}
  defp open_scope(domain, host, context) do
    with {:ok, opening} <-
           Opening.new(
             Map.merge(
               %{
                 ref: host.refs.scope,
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

  @spec actor(binary(), map()) :: GAM.Principal.t()
  defp actor(prefix, %{subject: subject} = identity)
       when not is_nil(subject) and subject != "" do
    principal(:human, prefix <> "human:" <> Value.digest!(identity))
  end

  defp actor(prefix, identity),
    do: principal(:service, prefix <> "application-actor:" <> Value.digest!(identity))

  @spec actor_assumption(GAM.Principal.t()) :: binary()
  defp actor_assumption(%{kind: :human}),
    do: "Application-authenticated subject acts through the agent runtime"

  defp actor_assumption(_),
    do: "Application execution identity; no authenticated human identity is asserted"

  @spec principal(atom(), binary()) :: GAM.Principal.t()
  defp principal(kind, name) do
    {:ok, value} = GAM.Principal.new(%{kind: kind, attributes: %{"name" => name}})
    value
  end
end
