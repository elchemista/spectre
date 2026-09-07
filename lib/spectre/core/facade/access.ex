defmodule Spectre.Facade.Access do
  @moduledoc false

  # One public-to-Domain boundary shared by facade workflows. This module does
  # no admission and retains no context cache: every command/query still enters
  # the Domain's authenticated, generation-fenced boundary. It never calls back
  # into Spectre's facade, so extracted workflows cannot form a delegation loop.
  require Spectre.Portable

  alias Spectre.{Domain, Portable, Scope, SubmissionContext}
  alias Spectre.Domain.Sequencer

  @registry Spectre.Domain.Registry

  @doc "Resolves the registered, live local Domain without authenticating a caller."
  @spec lookup_domain(String.t()) :: {:ok, Domain.t()} | {:error, term()}
  def lookup_domain(domain_ref) when Portable.is_non_empty_binary(domain_ref) do
    case registered_domain(domain_ref) do
      {:ok, pid} -> {:ok, Domain.handle(pid, domain_ref)}
      {:error, _reason} = error -> error
    end
  end

  def lookup_domain(_domain_ref), do: {:error, :invalid_domain_ref}

  @doc "Resolves the current address while preserving original claims; commands and queries still verify the seal and generation."
  @spec rebind_scope(Scope.t()) :: {:ok, Scope.t()} | {:error, term()}
  def rebind_scope(%Scope{} = scope) do
    with {:ok, domain} <- resolve_domain(scope.domain),
         {:ok, context} <- SubmissionContext.new(scope.context),
         :ok <- context_domain_binding(context, domain) do
      Scope.new(domain, context)
    end
  end

  @doc "Runs a fixed scoped query at the Domain and returns its result with the rebound address, never the complete projection."
  @spec scoped_read(Scope.t(), term()) :: {:ok, Scope.t(), term()} | {:error, term()}
  def scoped_read(%Scope{} = scope, query) do
    with {:ok, scope} <- rebind_scope(scope),
         {:ok, result} <-
           sequencer_result(
             fn -> Sequencer.query(scope.domain.server, scope, query) end,
             :scope_validation_failed
           ) do
      {:ok, scope, result}
    end
  end

  @doc "Returns the result of a fixed, authenticated scoped query."
  @spec scoped_query(Scope.t(), term()) :: {:ok, term()} | {:error, term()}
  def scoped_query(%Scope{} = scope, query) do
    with {:ok, _scope, result} <- scoped_read(scope, query), do: {:ok, result}
  end

  @doc "Checks routing consistency without granting authority or verifying authentication."
  @spec context_domain_binding(SubmissionContext.t(), Domain.t()) :: :ok | {:error, term()}
  def context_domain_binding(%SubmissionContext{domain_ref: domain_ref}, %Domain{ref: domain_ref}),
      do: :ok

  def context_domain_binding(_context, _domain), do: {:error, :context_domain_mismatch}

  @doc "Resolves a handle or reference through the live registry instead of trusting a caller-supplied PID."
  @spec resolve_domain(Domain.t() | String.t()) :: {:ok, Domain.t()} | {:error, term()}
  def resolve_domain(%Domain{ref: domain_ref}), do: lookup_domain(domain_ref)
  def resolve_domain(domain_ref) when is_binary(domain_ref), do: lookup_domain(domain_ref)
  def resolve_domain(_domain), do: {:error, :invalid_domain}

  defp registered_domain(domain_ref) do
    with :ok <- registry_available(),
         {:ok, registered} <-
           safe_call(
             fn -> Domain.whereis(domain_ref, @registry) end,
             :domain_registry_unavailable
           ) do
      normalize_registration(registered)
    end
  end

  defp registry_available do
    if Process.whereis(@registry),
      do: :ok,
      else: {:error, :domain_registry_unavailable}
  end

  defp normalize_registration(pid) when is_pid(pid) do
    # Registry cleanup is asynchronous: a terminated local Domain may still
    # have an entry until its partition processes the monitor notification.
    if Process.alive?(pid), do: {:ok, pid}, else: {:error, :domain_not_found}
  end

  defp normalize_registration(nil), do: {:error, :domain_not_found}
  defp normalize_registration(_invalid), do: {:error, :invalid_domain_registration}

  @doc "Unwraps the expected Domain reply and sanitizes failed calls without fabricating a successful commit."
  @spec sequencer_result((-> term()), atom()) :: {:ok, term()} | {:error, term()}
  def sequencer_result(function, failure) do
    case safe_call(function, failure) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, _reason} = error} -> error
      {:ok, _invalid} -> {:error, {:invalid_sequencer_response, failure}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Validates one nested host-options list without silently coercing its representation."
  @spec nested_keyword(keyword(), atom()) :: {:ok, keyword()} | {:error, term()}
  def nested_keyword(opts, key) do
    value = Keyword.get(opts, key, [])

    case validate_keyword(value, key) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  @doc "Allows only timeout overrides; callers cannot replace Domain-owned execution adapters."
  @spec validate_sequencer_options(keyword()) :: :ok | {:error, term()}
  def validate_sequencer_options(opts) do
    case Keyword.keys(opts) -- [:timeout] do
      [] -> :ok
      unknown -> {:error, {:unknown_sequencer_options, unknown}}
    end
  end

  @doc "Checks the operation-specific closed option set, preserving its diagnostic context."
  @spec validate_known_options(keyword(), [atom()], atom()) :: :ok | {:error, term()}
  def validate_known_options(opts, allowed, context) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> {:error, {:unknown_options, context, unknown}}
    end
  end

  @doc "Checks an options list without normalizing duplicate keys or changing error vocabulary."
  @spec validate_keyword(term(), atom()) :: :ok | {:error, term()}
  def validate_keyword(value, field) when is_list(value) do
    if Keyword.keyword?(value),
      do: :ok,
      else: {:error, {:invalid_keyword_options, field}}
  end

  def validate_keyword(_value, field), do: {:error, {:invalid_keyword_options, field}}

  @doc "Sanitizes host-call failures; an error does not prove absence of a durable write or external effect."
  @spec safe_call((-> term()), atom()) :: {:ok, term()} | {:error, atom()}
  def safe_call(function, failure) do
    {:ok, function.()}
  rescue
    _exception -> {:error, failure}
  catch
    :exit, _reason -> {:error, failure}
    :throw, _reason -> {:error, failure}
  end
end
