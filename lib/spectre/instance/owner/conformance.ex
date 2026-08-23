defmodule Spectre.Instance.Owner.Conformance do
  @moduledoc """
  Executable conformance checks for Instance ownership adapters.

  The `:local` profile verifies the portable lease boundary used together with
  the unique local Instance Registry. It deliberately makes no claim about
  cross-node supersession. The `:distributed` profile additionally requires
  monotonic fencing, supersession, cross-Ref isolation, and a single current
  lease after concurrent claims.

  The runner has no ExUnit dependency. Adapter authors can call it from their
  own test suites with fresh, isolated Instance references.
  """

  alias Spectre.Instance.Owner
  alias Spectre.Instance.Owner.Lease
  alias Spectre.Instance.Ref

  @contract_version 1
  @profiles [:local, :distributed]

  @type profile :: :local | :distributed

  @type report :: %{
          required(:contract_version) => pos_integer(),
          required(:profile) => profile(),
          required(:lease) => :portable,
          required(:ref_binding) => :verified,
          required(:fencing_floor) => :verified,
          required(:validation) => :verified,
          required(:release) => :verified | :optional_noop | :registry_scoped,
          required(:supersession) => :verified | :registry_scoped,
          required(:concurrent_claims) => :single_current | :not_applicable
        }

  @doc "Returns the ownership conformance contract version."
  @spec contract_version() :: pos_integer()
  def contract_version, do: @contract_version

  @doc """
  Runs one ownership profile against a fresh Instance reference.

  Options:

    * `:profile` - `:local` by default, or `:distributed`;
    * `:minimum_fencing_token` - non-negative floor supplied to the first claim;
    * `:concurrent_claims` - number of contenders for the distributed race;
    * `:timeout` - timeout for every contender in milliseconds;
    * `:alternate_ref` - optional distinct Ref used to prove Ref isolation.
  """
  @spec run(Owner.config(), Ref.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def run(owner, ref, opts \\ [])

  def run(owner, %Ref{} = ref, opts) when is_list(opts) do
    with :ok <- validate_options(opts),
         options = validated(opts),
         {:ok, normalized} <- normalize_owner(owner),
         {:ok, alternate_ref} <- alternate_ref(ref, opts),
         {:ok, _normalized, %Lease{} = lease} <-
           claim(owner, ref, Keyword.fetch!(options, :minimum_fencing_token)) do
      try do
        with :ok <- validates(owner, ref, lease, :validation),
             :ok <- rejects(owner, alternate_ref, lease, :ref_binding) do
          run_profile(
            Keyword.fetch!(options, :profile),
            owner,
            normalized,
            ref,
            alternate_ref,
            lease,
            options
          )
        end
      after
        _ = Owner.release(owner, ref, lease)
      end
    end
  end

  def run(_owner, _ref, _opts), do: failure(:options, :invalid_arguments)

  defp run_profile(:local, _owner, normalized, _ref, _alternate_ref, _lease, _opts) do
    {:ok, report(:local, normalized, :registry_scoped, :not_applicable, :registry_scoped)}
  end

  defp run_profile(:distributed, owner, normalized, ref, alternate_ref, first, opts) do
    with {:ok, _normalized, %Lease{} = second} <- reclaim(owner, ref, first.fencing_token) do
      try do
        with :ok <- validates(owner, ref, second, :reclaim),
             :ok <- rejects(owner, ref, first, :supersession),
             :ok <- cross_ref_isolation(owner, ref, alternate_ref, second),
             :ok <- concurrent_claims(owner, ref, second.fencing_token, opts),
             {:ok, release} <- release_semantics(owner, normalized, ref, second.fencing_token) do
          {:ok, report(:distributed, normalized, :verified, :single_current, release)}
        end
      after
        _ = Owner.release(owner, ref, second)
      end
    end
  end

  defp cross_ref_isolation(owner, ref, alternate_ref, current) do
    with {:ok, _normalized, %Lease{} = alternate} <- claim(owner, alternate_ref, 0) do
      try do
        with :ok <- validates(owner, alternate_ref, alternate, :alternate_claim),
             :ok <- validates(owner, ref, current, :cross_ref_isolation),
             :ok <- rejects(owner, ref, alternate, :cross_ref_binding) do
          rejects(owner, alternate_ref, current, :cross_ref_binding)
        end
      after
        _ = Owner.release(owner, alternate_ref, alternate)
      end
    end
  end

  defp concurrent_claims(owner, ref, minimum, opts) do
    count = Keyword.fetch!(opts, :concurrent_claims)
    timeout = Keyword.fetch!(opts, :timeout)

    outcomes =
      1..count
      |> Task.async_stream(
        fn _contender -> Owner.claim(owner, ref, minimum_fencing_token: minimum) end,
        ordered: false,
        max_concurrency: count,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.to_list()

    case successful_leases(outcomes) do
      {:ok, leases} ->
        try do
          with :ok <- unique_tokens(leases),
               {:ok, _current} <- exactly_one_current(owner, ref, leases) do
            :ok
          end
        after
          release_all(owner, ref, leases)
        end

      {:error, code, leases} ->
        release_all(owner, ref, leases)
        failure(:concurrency, code)
    end
  end

  defp successful_leases(outcomes) do
    Enum.reduce_while(outcomes, {:ok, []}, fn
      {:ok, {:ok, _normalized, %Lease{} = lease}}, {:ok, leases} ->
        {:cont, {:ok, [lease | leases]}}

      {:ok, {:error, _reason}}, {:ok, leases} ->
        {:cont, {:ok, leases}}

      {:exit, _reason}, {:ok, leases} ->
        {:halt, {:error, :contender_exit, leases}}

      _invalid, {:ok, leases} ->
        {:halt, {:error, :invalid_contender_reply, leases}}
    end)
    |> case do
      {:ok, []} -> {:error, :no_successful_claim, []}
      {:ok, leases} -> {:ok, leases}
      {:error, code, leases} -> {:error, code, leases}
    end
  end

  defp unique_tokens(leases) do
    tokens = Enum.map(leases, & &1.fencing_token)

    if length(Enum.uniq(tokens)) == length(tokens),
      do: :ok,
      else: failure(:concurrency, :duplicate_fencing_token)
  end

  defp exactly_one_current(owner, ref, leases) do
    current = Enum.filter(leases, &(Owner.validate(owner, ref, &1) == :ok))

    case current do
      [lease] -> {:ok, lease}
      [] -> failure(:concurrency, :no_current_lease)
      _many -> failure(:concurrency, :multiple_current_leases)
    end
  end

  defp validates(owner, ref, lease, phase) do
    case Owner.validate(owner, ref, lease) do
      :ok -> :ok
      {:error, _reason} -> failure(phase, :lease_rejected)
    end
  end

  defp rejects(owner, ref, lease, phase) do
    case Owner.validate(owner, ref, lease) do
      {:error, _reason} -> :ok
      :ok -> failure(phase, :lease_accepted)
    end
  end

  defp claim(owner, ref, minimum) do
    case Owner.claim(owner, ref, minimum_fencing_token: minimum) do
      {:ok, _normalized, %Lease{}} = ok -> ok
      {:error, _reason} -> failure(:claim, :rejected)
    end
  end

  defp reclaim(owner, ref, minimum) do
    case Owner.claim(owner, ref, minimum_fencing_token: minimum) do
      {:ok, _normalized, %Lease{}} = ok ->
        ok

      {:error, {:owner_fencing_token_not_monotonic, _token, ^minimum}} ->
        failure(:fencing, :non_monotonic_reclaim)

      {:error, _reason} ->
        failure(:reclaim, :rejected)
    end
  end

  defp release_semantics(owner, {module, _adapter_opts}, ref, minimum) do
    if Code.ensure_loaded?(module) and function_exported?(module, :release, 3) do
      with {:ok, _normalized, %Lease{} = lease} <- claim(owner, ref, minimum),
           :ok <- validates(owner, ref, lease, :release),
           :ok <- release(owner, ref, lease),
           :ok <- rejects(owner, ref, lease, :release) do
        {:ok, :verified}
      end
    else
      {:ok, :optional_noop}
    end
  end

  defp release(owner, ref, lease) do
    case Owner.release(owner, ref, lease) do
      :ok -> :ok
      {:error, _reason} -> failure(:release, :release_rejected)
    end
  end

  defp release_all(owner, ref, leases) do
    Enum.each(leases, fn lease ->
      _ = Owner.release(owner, ref, lease)
    end)
  end

  defp normalize_owner(owner) do
    case Owner.normalize(owner) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, _reason} -> failure(:configuration, :invalid_owner)
    end
  end

  defp alternate_ref(ref, opts) do
    alternate =
      Keyword.get_lazy(opts, :alternate_ref, fn ->
        Ref.new(ref.agent_ref, {:owner_conformance, ref.key})
      end)

    case alternate do
      %Ref{key: key} when key != ref.key -> {:ok, alternate}
      %Ref{} -> failure(:options, :alternate_ref_not_distinct)
      _invalid -> failure(:options, :invalid_alternate_ref)
    end
  end

  defp validate_options(opts) do
    allowed = [
      :profile,
      :minimum_fencing_token,
      :concurrent_claims,
      :timeout,
      :alternate_ref
    ]

    with :ok <- validate_keyword(opts),
         :ok <- validate_known_options(opts, allowed),
         values = validated(opts),
         :ok <- validate_profile(values[:profile]),
         :ok <- validate_non_negative(values[:minimum_fencing_token], :invalid_fencing_floor),
         :ok <- validate_minimum(values[:concurrent_claims], 2, :invalid_concurrent_claims) do
      validate_minimum(values[:timeout], 1, :invalid_timeout)
    end
  end

  defp validate_keyword(opts) do
    if Keyword.keyword?(opts), do: :ok, else: failure(:options, :invalid_keyword)
  end

  defp validate_known_options(opts, allowed) do
    if Keyword.keys(opts) -- allowed == [],
      do: :ok,
      else: failure(:options, :unknown_options)
  end

  defp validate_profile(profile) do
    if profile in @profiles, do: :ok, else: failure(:options, :invalid_profile)
  end

  defp validate_non_negative(value, code) do
    if is_integer(value) and value >= 0, do: :ok, else: failure(:options, code)
  end

  defp validate_minimum(value, minimum, code) do
    if is_integer(value) and value >= minimum, do: :ok, else: failure(:options, code)
  end

  defp validated(opts) do
    opts
    |> Keyword.put_new(:profile, :local)
    |> Keyword.put_new(:minimum_fencing_token, 0)
    |> Keyword.put_new(:concurrent_claims, 4)
    |> Keyword.put_new(:timeout, 5_000)
  end

  defp report(profile, _normalized, supersession, concurrent_claims, release) do
    %{
      contract_version: @contract_version,
      profile: profile,
      lease: :portable,
      ref_binding: :verified,
      fencing_floor: :verified,
      validation: :verified,
      release: release,
      supersession: supersession,
      concurrent_claims: concurrent_claims
    }
  end

  defp failure(phase, code),
    do: {:error, {:instance_owner_conformance_failed, phase, code}}
end
