defmodule Spectre.Execution.Router do
  @moduledoc """
  Resolves host execution wiring before a Candidate enters the kernel.

  A route proves only that this running application knows how to reach the
  declared executor contract and has a compatible broker profile. It does not
  authorize the Candidate, choose its route, or become a governed fact. The
  kernel still decides Admission from ledger-derived authority; execution can
  begin only after the resulting Act receives and consumes a Grant.
  """

  alias Spectre.{Candidate, Portable}
  alias Spectre.Execution.Boundary
  alias Spectre.GovernedAct.Execution, as: GovernedExecution
  alias Spectre.GovernedAct.State

  @type route :: Boundary.runtime_route()

  @doc "Checks that host wiring can support an executor-mediated Candidate."
  @spec validate_candidate(Boundary.t(), State.t(), Candidate.t()) :: :ok | {:error, term()}
  def validate_candidate(boundary, %State{} = projection, %Candidate{} = candidate) do
    case GovernedExecution.mode(candidate) do
      {:ok, :ledger_internal} ->
        :ok

      {:ok, :executor_mediated} ->
        with {:ok, route} <-
               fetch(boundary, candidate.executor_ref, candidate.executor_contract_ref) do
          candidate_profile(projection, route.broker_descriptor)
        end

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Returns the exact executor/broker pair configured for a declared contract."
  @spec fetch(Boundary.t(), String.t(), String.t()) :: {:ok, route()} | {:error, term()}
  def fetch(%{routes: routes} = boundary, executor_ref, contract_ref) when is_map(routes) do
    with :ok <- Portable.validate_ref(executor_ref, :executor_ref),
         :ok <- Portable.validate_ref(contract_ref, :executor_contract_ref),
         {:ok, route} <- Map.fetch(routes, {executor_ref, contract_ref}),
         {:ok, broker} <- broker(boundary) do
      {:ok,
       %{
         executor: route.executor,
         executor_opts: route.executor_opts,
         broker: broker.broker,
         broker_opts: broker.broker_opts,
         broker_descriptor: broker.descriptor
       }}
    else
      :error -> {:error, {:executor_route_not_configured, executor_ref, contract_ref}}
      {:error, _reason} = error -> error
    end
  end

  def fetch(_boundary, _executor_ref, _contract_ref),
    do: {:error, :invalid_execution_boundary}

  @doc "Returns the configured capability broker without invoking it."
  @spec broker(Boundary.t()) :: {:ok, map()} | {:error, term()}
  def broker(%{broker: nil}), do: {:error, :broker_not_configured}
  def broker(%{broker: broker}) when is_map(broker), do: {:ok, broker}
  def broker(_boundary), do: {:error, :invalid_execution_boundary}

  @doc "Checks that a broker profile covers the HostProfile frozen by an Act."
  @spec broker_supports_act(State.t(), Spectre.Act.t(), map()) :: :ok | {:error, term()}
  def broker_supports_act(%State{} = projection, act, broker) do
    profile_supports_act(projection, act, broker.descriptor)
  end

  @doc "Checks an Act against an explicit broker descriptor."
  @spec profile_supports_act(State.t(), Spectre.Act.t(), map()) :: :ok | {:error, term()}
  def profile_supports_act(%State{} = projection, act, descriptor) do
    broker_profile = descriptor.profile

    with {:ok, host_profile} <- Map.fetch(projection.host_profiles, act.host_profile_ref),
         true <- Boundary.profile_covers?(broker_profile, host_profile.mode) do
      :ok
    else
      :error -> {:error, {:act_host_profile_not_found, act.host_profile_ref}}
      false -> {:error, {:broker_profile_too_weak, broker_profile, act.host_profile_ref}}
    end
  end

  defp candidate_profile(%State{} = projection, %{profile: broker_profile}) do
    case State.host_profile(projection) do
      %Spectre.HostProfile{} = profile ->
        if Boundary.profile_covers?(broker_profile, profile.mode),
          do: :ok,
          else: {:error, {:broker_profile_too_weak, broker_profile, profile.ref}}

      nil ->
        {:error, :host_profile_not_initialized}
    end
  end
end
