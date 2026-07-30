defmodule Spectre.Subject.Registry do
  @moduledoc """
  Authoritative in-memory resolver for Subjects and authenticated identities.

  Resolution is exact and Agent-scoped. The registry never compares display
  names, phone-number similarity, address books, message text, or model output.
  Linking requires either an explicit trusted bootstrap proof or the
  destination-channel challenge protocol.

  Durable storage for these records belongs to the later continuity phase; the
  0.1.4 registry deliberately exposes plain value objects that a store adapter
  can persist without process handles or secrets.
  """

  use GenServer

  alias Spectre.AgentRef
  alias Spectre.ExternalIdentity
  alias Spectre.Identity
  alias Spectre.LinkIntent
  alias Spectre.Run.Value
  alias Spectre.Subject
  alias Spectre.SubjectLink

  @default_ttl :timer.minutes(10)
  @default_attempts 3

  defstruct links: %{}, resolutions: %{}, intents: %{}, opts: []

  @type server :: GenServer.server()

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Starts a Subject Registry.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Creates the first explicit link for a Subject from a trusted host proof.

  This is the bootstrap boundary for an already authenticated identity. The
  `:proof` option is mandatory so importing or provisioning an identity cannot
  accidentally degrade into heuristic linking.
  """
  @spec bind(
          AgentRef.t() | module(),
          Subject.t() | term(),
          ExternalIdentity.t(),
          keyword()
        ) :: {:ok, SubjectLink.t()} | {:error, term()}
  @spec bind(
          server(),
          AgentRef.t() | module(),
          Subject.t() | term(),
          ExternalIdentity.t(),
          keyword()
        ) ::
          {:ok, SubjectLink.t()} | {:error, term()}
  def bind(agent_ref, subject, identity, opts \\ [])

  def bind(agent_ref, subject, identity, opts) when is_list(opts) do
    bind(__MODULE__, agent_ref, subject, identity, opts)
  end

  def bind(server, agent_ref, subject, %ExternalIdentity{} = identity) do
    bind(server, agent_ref, subject, identity, [])
  end

  def bind(server, agent_ref, subject, identity, opts) when is_list(opts) do
    GenServer.call(server, {:bind, agent_ref, subject, identity, opts})
  end

  @doc """
  Opens a one-time destination challenge from an identity already linked to
  the Subject.

  The returned challenge is never retained by the registry.
  """
  @spec open_link(
          AgentRef.t() | module(),
          Subject.t() | term(),
          ExternalIdentity.t(),
          ExternalIdentity.t(),
          keyword()
        ) :: {:ok, LinkIntent.t(), String.t()} | {:error, term()}
  @spec open_link(
          server(),
          AgentRef.t() | module(),
          Subject.t() | term(),
          ExternalIdentity.t(),
          ExternalIdentity.t(),
          keyword()
        ) :: {:ok, LinkIntent.t(), String.t()} | {:error, term()}
  def open_link(agent_ref, subject, source_identity, destination_identity, opts \\ [])

  def open_link(agent_ref, subject, source_identity, destination_identity, opts)
      when is_list(opts) do
    open_link(
      __MODULE__,
      agent_ref,
      subject,
      source_identity,
      destination_identity,
      opts
    )
  end

  def open_link(
        server,
        agent_ref,
        subject,
        source_identity,
        %ExternalIdentity{} = destination_identity
      ) do
    open_link(server, agent_ref, subject, source_identity, destination_identity, [])
  end

  def open_link(server, agent_ref, subject, source_identity, destination_identity, opts)
      when is_list(opts) do
    GenServer.call(
      server,
      {:open_link, agent_ref, subject, source_identity, destination_identity, opts}
    )
  end

  @doc """
  Confirms a LinkIntent from its authenticated destination identity.
  """
  @spec confirm_link(String.t(), ExternalIdentity.t(), String.t(), keyword()) ::
          {:ok, SubjectLink.t() | LinkIntent.t()} | {:error, term()}
  @spec confirm_link(server(), String.t(), ExternalIdentity.t(), String.t(), keyword()) ::
          {:ok, SubjectLink.t() | LinkIntent.t()} | {:error, term()}
  def confirm_link(intent_id, identity, challenge, opts \\ [])

  def confirm_link(intent_id, identity, challenge, opts) when is_list(opts) do
    confirm_link(__MODULE__, intent_id, identity, challenge, opts)
  end

  def confirm_link(server, intent_id, %ExternalIdentity{} = identity, challenge) do
    confirm_link(server, intent_id, identity, challenge, [])
  end

  def confirm_link(server, intent_id, identity, challenge, opts) when is_list(opts) do
    GenServer.call(server, {:confirm_link, intent_id, identity, challenge, opts})
  end

  @doc """
  Applies the optional second confirmation from the already linked source.
  """
  @spec confirm_source(String.t(), ExternalIdentity.t(), keyword()) ::
          {:ok, SubjectLink.t()} | {:error, term()}
  @spec confirm_source(server(), String.t(), ExternalIdentity.t(), keyword()) ::
          {:ok, SubjectLink.t()} | {:error, term()}
  def confirm_source(intent_id, identity, opts \\ [])

  def confirm_source(intent_id, identity, opts) when is_list(opts) do
    confirm_source(__MODULE__, intent_id, identity, opts)
  end

  def confirm_source(server, intent_id, %ExternalIdentity{} = identity) do
    confirm_source(server, intent_id, identity, [])
  end

  def confirm_source(server, intent_id, identity, opts) when is_list(opts) do
    GenServer.call(server, {:confirm_source, intent_id, identity, opts})
  end

  @doc """
  Resolves an exact authenticated identity to its canonical Subject and link.
  """
  @spec resolve(AgentRef.t() | module(), ExternalIdentity.t()) ::
          {:ok, Subject.t(), SubjectLink.t()} | {:error, term()}
  @spec resolve(server(), AgentRef.t() | module(), ExternalIdentity.t()) ::
          {:ok, Subject.t(), SubjectLink.t()} | {:error, term()}
  def resolve(agent_ref, identity), do: resolve(__MODULE__, agent_ref, identity)

  def resolve(server, agent_ref, identity) do
    GenServer.call(server, {:resolve, agent_ref, identity})
  end

  @doc """
  Revokes an active link without deleting the Subject or Instance state.
  """
  @spec revoke(String.t(), keyword()) :: {:ok, SubjectLink.t()} | {:error, term()}
  @spec revoke(server(), String.t(), keyword()) ::
          {:ok, SubjectLink.t()} | {:error, term()}
  def revoke(link_id, opts \\ [])

  def revoke(link_id, opts) when is_list(opts) do
    revoke(__MODULE__, link_id, opts)
  end

  def revoke(server, link_id) when is_binary(link_id), do: revoke(server, link_id, [])

  def revoke(server, link_id, opts) when is_list(opts) do
    GenServer.call(server, {:revoke, link_id, opts})
  end

  @doc """
  Returns a LinkIntent by id for audit and channel workflows.
  """
  @spec intent(String.t()) :: {:ok, LinkIntent.t()} | {:error, :unknown_link_intent}
  @spec intent(server(), String.t()) :: {:ok, LinkIntent.t()} | {:error, :unknown_link_intent}
  def intent(intent_id), do: intent(__MODULE__, intent_id)

  def intent(server, intent_id) do
    GenServer.call(server, {:intent, intent_id})
  end

  @doc """
  Lists every retained link for an Agent and Subject, including revocations.
  """
  @spec links(AgentRef.t() | module(), Subject.t() | term()) ::
          {:ok, [SubjectLink.t()]} | {:error, term()}
  @spec links(server(), AgentRef.t() | module(), Subject.t() | term()) ::
          {:ok, [SubjectLink.t()]} | {:error, term()}
  def links(agent_ref, subject), do: links(__MODULE__, agent_ref, subject)

  def links(server, agent_ref, subject) do
    GenServer.call(server, {:links, agent_ref, subject})
  end

  @impl GenServer
  def init(opts) do
    {:ok, %__MODULE__{opts: opts}}
  end

  @impl GenServer
  def handle_call({:bind, agent, subject, identity, opts}, _from, state) do
    result =
      with {:ok, agent_ref} <- normalize_agent_ref(agent),
           {:ok, subject} <- normalize_subject(subject),
           {:ok, identity} <- normalize_identity(identity),
           {:ok, proof_ref} <- bootstrap_proof(opts),
           :ok <- ensure_resolution_available(state, agent_ref, subject, identity),
           {:ok, link} <-
             build_link(agent_ref, subject, identity, now_ms(state, opts),
               proof_ref: proof_ref,
               metadata: Keyword.get(opts, :metadata, %{})
             ),
           :ok <- record_link(state, link, :subject_link_committed, opts) do
        {:ok, link}
      end

    case result do
      {:ok, link} ->
        {:reply, {:ok, link}, put_link(state, link)}

      {:error, {:identity_already_linked, link_id}} ->
        {:reply, existing_link_reply(state, link_id, subject), state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:open_link, agent, subject, source, destination, opts},
        _from,
        state
      ) do
    result =
      with {:ok, agent_ref} <- normalize_agent_ref(agent),
           {:ok, subject} <- normalize_subject(subject),
           {:ok, source} <- normalize_identity(source),
           {:ok, destination} <- normalize_identity(destination),
           :ok <- source_owns_subject(state, agent_ref, subject, source),
           :ok <- ensure_resolution_available(state, agent_ref, subject, destination),
           {:ok, ttl} <- positive_option(opts, :ttl, @default_ttl),
           {:ok, attempts} <- positive_option(opts, :attempts, @default_attempts),
           {:ok, source_confirmation?} <-
             boolean_option(opts, :source_confirmation?, false) do
        challenge = challenge()
        now = now_ms(state, opts)

        intent = %LinkIntent{
          id: Identity.uuid7(),
          agent_ref: agent_ref,
          subject: subject,
          source_identity: source,
          destination_identity: destination,
          challenge_digest: digest(challenge),
          expires_at: now + ttl,
          attempts_remaining: attempts,
          source_confirmation?: source_confirmation?
        }

        {:ok, intent, challenge}
      end

    case result do
      {:ok, intent, challenge} ->
        {:reply, {:ok, intent, challenge}, put_intent(state, intent)}

      {:error, {:identity_already_linked, link_id}} ->
        {:reply, existing_link_reply(state, link_id, subject), state}

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  def handle_call({:confirm_link, intent_id, identity, challenge, opts}, _from, state) do
    with {:ok, intent} <- fetch_intent(state, intent_id),
         {:ok, identity} <- normalize_identity(identity),
         {:ok, intent, state} <-
           validate_destination_confirmation(state, intent, identity, challenge, opts) do
      destination_confirmation_reply(state, intent, opts)
    else
      {:error, reason, updated_state} -> {:reply, {:error, reason}, updated_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:confirm_source, intent_id, identity, opts}, _from, state) do
    result =
      with {:ok, %LinkIntent{status: :awaiting_source} = intent} <-
             fetch_intent(state, intent_id),
           {:ok, identity} <- normalize_identity(identity),
           true <- ExternalIdentity.key(identity) == ExternalIdentity.key(intent.source_identity),
           :ok <- source_owns_subject(state, intent.agent_ref, intent.subject, identity) do
        commit_intent(state, intent, opts)
      else
        {:ok, %LinkIntent{status: status}} ->
          {:error, {:link_intent_not_awaiting_source, status}, state}

        false ->
          {:error, :source_identity_mismatch, state}

        {:error, reason} ->
          {:error, reason, state}
      end

    case result do
      {:ok, link, committed_state} -> {:reply, {:ok, link}, committed_state}
      {:error, reason, current_state} -> {:reply, {:error, reason}, current_state}
    end
  end

  def handle_call({:resolve, agent, identity}, _from, state) do
    result =
      with {:ok, agent_ref} <- normalize_agent_ref(agent),
           {:ok, identity} <- normalize_identity(identity),
           {:ok, link_id} <- fetch_resolution(state, agent_ref, identity),
           %SubjectLink{status: :active} = link <- Map.get(state.links, link_id) do
        {:ok, link.subject, link}
      else
        nil -> {:error, :unlinked_external_identity}
        %SubjectLink{status: :revoked} -> {:error, :revoked_external_identity}
        {:error, _reason} = error -> error
      end

    {:reply, result, state}
  end

  def handle_call({:revoke, link_id, opts}, _from, state) do
    case Map.get(state.links, link_id) do
      %SubjectLink{status: :active} = link ->
        revoked = %{
          link
          | status: :revoked,
            revoked_at: now_ms(state, opts),
            revision: link.revision + 1
        }

        case record_link(state, revoked, :subject_link_revoked, opts) do
          :ok ->
            resolution_key = resolution_key(revoked.agent_ref, revoked.external_identity)

            next = %{
              state
              | links: Map.put(state.links, revoked.id, revoked),
                resolutions: Map.delete(state.resolutions, resolution_key)
            }

            {:reply, {:ok, revoked}, next}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      %SubjectLink{status: :revoked} = link ->
        {:reply, {:ok, link}, state}

      nil ->
        {:reply, {:error, :unknown_subject_link}, state}
    end
  end

  def handle_call({:intent, intent_id}, _from, state) do
    {:reply, fetch_intent(state, intent_id), state}
  end

  def handle_call({:links, agent, subject}, _from, state) do
    result =
      with {:ok, agent_ref} <- normalize_agent_ref(agent),
           {:ok, subject} <- normalize_subject(subject) do
        links =
          state.links
          |> Map.values()
          |> Enum.filter(
            &(AgentRef.key(&1.agent_ref) == AgentRef.key(agent_ref) and
                Subject.key(&1.subject) == Subject.key(subject))
          )
          |> Enum.sort_by(&{&1.committed_at, &1.id})

        {:ok, links}
      end

    {:reply, result, state}
  end

  defp destination_confirmation_reply(state, intent, opts) do
    if intent.source_confirmation? do
      awaiting = %{
        intent
        | status: :awaiting_source,
          challenge_digest: <<>>,
          revision: intent.revision + 1
      }

      {:reply, {:ok, awaiting}, put_intent(state, awaiting)}
    else
      case commit_intent(state, intent, opts) do
        {:ok, link, committed_state} -> {:reply, {:ok, link}, committed_state}
        {:error, reason, current_state} -> {:reply, {:error, reason}, current_state}
      end
    end
  end

  defp normalize_agent_ref(%AgentRef{} = ref) do
    case AgentRef.validate(ref) do
      :ok -> {:ok, ref}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_agent_ref(agent) when is_atom(agent) do
    {:ok, AgentRef.new(agent)}
  rescue
    exception -> {:error, {:invalid_agent_ref, exception.__struct__}}
  end

  defp normalize_agent_ref(other), do: {:error, {:invalid_agent_ref, other}}

  defp normalize_subject(%Subject{} = subject) do
    case Subject.validate(subject) do
      :ok -> {:ok, subject}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_subject(nil), do: {:error, :missing_subject}

  defp normalize_subject(subject) do
    case Subject.new(subject) do
      %Subject{} = normalized -> {:ok, normalized}
    end
  rescue
    exception -> {:error, {:invalid_subject, exception.__struct__}}
  end

  defp normalize_identity(%ExternalIdentity{} = identity) do
    case ExternalIdentity.validate(identity) do
      :ok -> {:ok, identity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_identity(other), do: {:error, {:invalid_external_identity, other}}

  defp bootstrap_proof(opts) do
    case Keyword.fetch(opts, :proof) do
      {:ok, proof} when not is_nil(proof) ->
        case Value.validate(proof, [:subject_link, :proof]) do
          :ok -> {:ok, Value.token("link-proof", proof)}
          {:error, _reason} -> {:error, :invalid_subject_link_proof}
        end

      _missing ->
        {:error, :subject_link_proof_required}
    end
  end

  defp ensure_resolution_available(state, agent_ref, subject, identity) do
    case Map.get(state.resolutions, resolution_key(agent_ref, identity)) do
      nil ->
        :ok

      link_id ->
        resolution_available_for_link(state, link_id, subject)
    end
  end

  defp resolution_available_for_link(state, link_id, subject) do
    case Map.get(state.links, link_id) do
      %SubjectLink{status: :active, subject: linked_subject} ->
        if Subject.key(linked_subject) == Subject.key(subject),
          do: {:error, {:identity_already_linked, link_id}},
          else: {:error, {:external_identity_subject_conflict, link_id}}

      _inactive ->
        :ok
    end
  end

  defp existing_link_reply(state, link_id, subject) do
    with {:ok, subject} <- normalize_subject(subject) do
      existing_link_for_subject(state, link_id, subject)
    end
  end

  defp existing_link_for_subject(state, link_id, subject) do
    case Map.get(state.links, link_id) do
      %SubjectLink{status: :active, subject: linked_subject} = link ->
        if Subject.key(linked_subject) == Subject.key(subject),
          do: {:ok, link},
          else: {:error, {:external_identity_subject_conflict, link_id}}

      _missing ->
        {:error, :unlinked_external_identity}
    end
  end

  defp source_owns_subject(state, agent_ref, subject, source) do
    with {:ok, link_id} <- fetch_resolution(state, agent_ref, source),
         %SubjectLink{status: :active, subject: linked_subject} <- Map.get(state.links, link_id),
         true <- Subject.key(linked_subject) == Subject.key(subject) do
      :ok
    else
      false -> {:error, :source_identity_subject_mismatch}
      _missing -> {:error, :source_identity_not_linked}
    end
  end

  defp validate_destination_confirmation(state, intent, identity, challenge, opts) do
    now = now_ms(state, opts)

    cond do
      intent.status != :pending ->
        {:error, {:link_intent_not_pending, intent.status}, state}

      now >= intent.expires_at ->
        expired = %{intent | status: :expired, revision: intent.revision + 1}
        {:error, :link_intent_expired, put_intent(state, expired)}

      ExternalIdentity.key(identity) != ExternalIdentity.key(intent.destination_identity) ->
        {:error, :destination_identity_mismatch, state}

      not valid_challenge?(challenge, intent.challenge_digest) ->
        remaining = max(intent.attempts_remaining - 1, 0)
        status = if remaining == 0, do: :failed, else: :pending

        attempted = %{
          intent
          | attempts_remaining: remaining,
            status: status,
            revision: intent.revision + 1
        }

        {:error, {:invalid_link_challenge, remaining}, put_intent(state, attempted)}

      true ->
        {:ok, intent, state}
    end
  end

  defp commit_intent(state, intent, opts) do
    now = now_ms(state, opts)

    if now >= intent.expires_at do
      expired = %{intent | status: :expired, revision: intent.revision + 1}
      {:error, :link_intent_expired, put_intent(state, expired)}
    else
      commit_current_intent(state, intent, opts, now)
    end
  end

  defp commit_current_intent(state, intent, opts, now) do
    with :ok <-
           source_owns_subject(
             state,
             intent.agent_ref,
             intent.subject,
             intent.source_identity
           ),
         :ok <-
           ensure_resolution_available(
             state,
             intent.agent_ref,
             intent.subject,
             intent.destination_identity
           ),
         {:ok, link} <-
           build_link(
             intent.agent_ref,
             intent.subject,
             intent.destination_identity,
             now,
             metadata: %{link_intent_id: intent.id}
           ),
         :ok <- record_link(state, link, :subject_link_committed, opts) do
      committed = %{
        intent
        | status: :committed,
          challenge_digest: <<>>,
          receipt_ref: link.receipt_ref,
          revision: intent.revision + 1
      }

      next = state |> put_link(link) |> put_intent(committed)
      {:ok, link, next}
    else
      {:error, {:identity_already_linked, link_id}} ->
        reuse_existing_intent_link(state, link_id, intent)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp reuse_existing_intent_link(state, link_id, intent) do
    case existing_link_reply(state, link_id, intent.subject) do
      {:ok, link} ->
        committed = %{
          intent
          | status: :committed,
            challenge_digest: <<>>,
            receipt_ref: link.receipt_ref,
            revision: intent.revision + 1
        }

        {:ok, link, put_intent(state, committed)}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp build_link(agent_ref, subject, identity, now, opts) do
    metadata = Keyword.get(opts, :metadata, %{})

    if is_map(metadata) and match?(:ok, Value.validate(metadata, [:subject_link, :metadata])) do
      {:ok,
       %SubjectLink{
         id: Identity.uuid7(),
         agent_ref: agent_ref,
         subject: subject,
         external_identity: identity,
         receipt_ref: Keyword.get(opts, :proof_ref) || Identity.uuid7(),
         committed_at: now,
         metadata: metadata
       }}
    else
      {:error, :invalid_subject_link_metadata}
    end
  end

  defp put_link(state, %SubjectLink{} = link) do
    key = resolution_key(link.agent_ref, link.external_identity)

    %{
      state
      | links: Map.put(state.links, link.id, link),
        resolutions: Map.put(state.resolutions, key, link.id)
    }
  end

  defp put_intent(state, %LinkIntent{} = intent) do
    %{state | intents: Map.put(state.intents, intent.id, intent)}
  end

  defp fetch_intent(state, intent_id) when is_binary(intent_id) do
    case Map.get(state.intents, intent_id) do
      %LinkIntent{} = intent -> {:ok, intent}
      nil -> {:error, :unknown_link_intent}
    end
  end

  defp fetch_intent(_state, _intent_id), do: {:error, :unknown_link_intent}

  defp fetch_resolution(state, agent_ref, identity) do
    case Map.fetch(state.resolutions, resolution_key(agent_ref, identity)) do
      {:ok, link_id} -> {:ok, link_id}
      :error -> {:error, :unlinked_external_identity}
    end
  end

  defp resolution_key(agent_ref, identity) do
    {AgentRef.key(agent_ref), ExternalIdentity.key(identity)}
  end

  defp record_link(state, link, event, opts) do
    journal_opts = Keyword.merge(state.opts, opts)

    Spectre.Journal.record(
      link.agent_ref.definition,
      event,
      %{
        subject_key: Subject.key(link.subject),
        external_identity_key: ExternalIdentity.key(link.external_identity),
        subject_link_id: link.id,
        receipt_ref: link.receipt_ref,
        status: link.status,
        revision: link.revision
      },
      journal_opts
    )
  end

  defp positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_link_intent_option, key, value}}
    end
  end

  defp boolean_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> {:ok, value}
      value -> {:error, {:invalid_link_intent_option, key, value}}
    end
  end

  defp now_ms(state, _command_opts) do
    if is_function(Keyword.get(state.opts, :clock), 0) do
      state.opts |> Keyword.fetch!(:clock) |> then(& &1.())
    else
      System.system_time(:millisecond)
    end
  end

  defp challenge do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp digest(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  defp valid_challenge?(challenge, expected) when is_binary(challenge) and is_binary(expected) do
    candidate = digest(challenge)
    byte_size(candidate) == byte_size(expected) and :crypto.hash_equals(candidate, expected)
  end

  defp valid_challenge?(_challenge, _expected), do: false
end
