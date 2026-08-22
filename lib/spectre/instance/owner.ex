defmodule Spectre.Instance.Owner do
  @moduledoc """
  Host contract for canonical Instance ownership and monotonic fencing.

  A local Registry is routing, not distributed ownership. Hosts that may run
  the same logical Instance on multiple nodes must supply an adapter backed by
  a linearizable lease or route all work to one canonical owner. Losing or
  superseding the lease blocks admission, activation commit, state commit,
  Effect dispatch, and retry before dispatch.
  """

  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Owner.Local
  alias Spectre.Instance.Ref

  @type config :: module() | {module(), keyword()} | nil

  @callback claim(Ref.t(), keyword()) :: {:ok, Lease.t()} | {:error, term()}
  @callback claim_maintenance(Ref.t(), atom(), keyword()) ::
              {:ok, Lease.t()} | {:error, term()}
  @callback validate(Ref.t(), Lease.t(), keyword()) :: :ok | {:error, term()}
  @callback release(Ref.t(), Lease.t(), keyword()) :: :ok | {:error, term()}

  @optional_callbacks claim_maintenance: 3, release: 3

  @doc "Normalizes an ownership adapter; `nil` selects the local-only adapter."
  @spec normalize(config()) :: {:ok, {module(), keyword()}} | {:error, term()}
  def normalize(nil), do: {:ok, {Local, []}}
  def normalize(module) when is_atom(module) and not is_nil(module), do: {:ok, {module, []}}

  def normalize({module, opts})
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, {module, opts}},
      else: {:error, {:invalid_instance_owner, {module, :non_keyword_options}}}
  end

  def normalize(value), do: {:error, {:invalid_instance_owner, value}}

  @doc "Claims ownership and validates the returned portable lease."
  @spec claim(config(), Ref.t(), keyword()) ::
          {:ok, {module(), keyword()}, Lease.t()} | {:error, term()}
  def claim(config, %Ref{} = ref, opts \\ []) do
    with {:ok, {module, adapter_opts} = normalized} <- normalize(config),
         :ok <- ensure_callback(module, :claim, 2),
         {:ok, reply} <- invoke(module, :claim, [ref, Keyword.merge(adapter_opts, opts)]),
         {:ok, lease} <- normalize_claim(reply),
         :ok <- fencing_floor(lease, Keyword.get(opts, :minimum_fencing_token, 0)),
         :ok <- validate(normalized, ref, lease, opts) do
      {:ok, normalized, lease}
    end
  end

  @doc """
  Claims an unowned Instance for one offline maintenance operation.

  Unlike an ordinary claim, an adapter must not supersede a live owner. The
  callback is optional so existing adapters remain source compatible, but
  maintenance operations fail with an explicit capability error when it is
  absent. The local adapter is safe only after core has reserved the unique
  local Registry key.
  """
  @spec claim_maintenance(config(), Ref.t(), atom(), keyword()) ::
          {:ok, {module(), keyword()}, Lease.t()} | {:error, term()}
  def claim_maintenance(config, ref, purpose, opts \\ [])

  def claim_maintenance(config, %Ref{} = ref, purpose, opts) when is_atom(purpose) do
    with {:ok, {module, adapter_opts} = normalized} <- normalize(config),
         :ok <- ensure_maintenance_callback(module),
         {:ok, reply} <-
           invoke(module, :claim_maintenance, [
             ref,
             purpose,
             Keyword.merge(adapter_opts, opts)
           ]),
         {:ok, lease} <- normalize_claim(reply),
         :ok <- fencing_floor(lease, Keyword.get(opts, :minimum_fencing_token, 0)),
         :ok <- validate(normalized, ref, lease, opts) do
      {:ok, normalized, lease}
    end
  end

  def claim_maintenance(_config, %Ref{}, purpose, _opts),
    do: {:error, {:invalid_instance_owner_maintenance_purpose, purpose}}

  @doc "Validates that a lease remains current at a guarded boundary."
  @spec validate(config(), Ref.t(), Lease.t(), keyword()) :: :ok | {:error, term()}
  def validate(config, %Ref{} = ref, %Lease{} = lease, opts \\ []) do
    with {:ok, {module, adapter_opts}} <- normalize(config),
         :ok <- ensure_callback(module, :validate, 3),
         {:ok, reply} <-
           invoke(module, :validate, [ref, lease, Keyword.merge(adapter_opts, opts)]) do
      normalize_validate(reply, module)
    end
  end

  @doc """
  Validates a lease and classifies failure as an owner-fence loss for one
  concrete operation.
  """
  @spec assert_current(config(), Ref.t(), Lease.t(), atom(), keyword()) ::
          :ok | {:error, term()}
  def assert_current(config, ref, lease, operation, opts \\ []) when is_atom(operation) do
    case validate(config, ref, lease, opts) do
      :ok -> :ok
      {:error, reason} -> {:error, {:owner_fence_lost, operation, reason}}
    end
  end

  @doc "Releases an owned lease when the adapter implements the callback."
  @spec release(config(), Ref.t(), Lease.t(), keyword()) :: :ok | {:error, term()}
  def release(config, %Ref{} = ref, %Lease{} = lease, opts \\ []) do
    with {:ok, normalized} <- normalize(config),
         do: release_normalized(normalized, ref, lease, opts)
  end

  defp release_normalized({module, adapter_opts}, ref, lease, opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :release, 3) do
      with {:ok, reply} <-
             invoke(module, :release, [ref, lease, Keyword.merge(adapter_opts, opts)]),
           do: normalize_validate(reply, module)
    else
      :ok
    end
  end

  defp normalize_claim({:ok, %Lease{} = lease}) do
    case Lease.new(Map.from_struct(lease)) do
      {:ok, ^lease} -> {:ok, lease}
      {:ok, rebuilt} -> {:error, {:owner_lease_integrity_mismatch, lease, rebuilt}}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_claim({:error, _reason} = error), do: error
  defp normalize_claim(value), do: {:error, {:invalid_instance_owner_claim, value}}

  defp normalize_validate(:ok, _module), do: :ok
  defp normalize_validate({:error, _reason} = error, _module), do: error

  defp normalize_validate(value, module),
    do: {:error, {:invalid_instance_owner_reply, module, value}}

  defp fencing_floor(%Lease{fencing_token: token}, minimum)
       when is_integer(minimum) and minimum >= 0 and token > minimum,
       do: :ok

  defp fencing_floor(%Lease{fencing_token: token}, minimum),
    do: {:error, {:owner_fencing_token_not_monotonic, token, minimum}}

  defp ensure_callback(module, function, arity) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:instance_owner_not_loaded, module}}

      not function_exported?(module, function, arity) ->
        {:error, {:instance_owner_callback_missing, module, function, arity}}

      true ->
        :ok
    end
  end

  defp ensure_maintenance_callback(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:instance_owner_not_loaded, module}}

      not function_exported?(module, :claim_maintenance, 3) ->
        {:error, {:instance_owner_maintenance_unsupported, module}}

      true ->
        :ok
    end
  end

  defp invoke(module, function, arguments) do
    {:ok, apply(module, function, arguments)}
  rescue
    exception -> {:error, {:instance_owner_exception, module, function, exception.__struct__}}
  catch
    kind, reason -> {:error, {:instance_owner_failure, module, function, kind, reason}}
  end
end
