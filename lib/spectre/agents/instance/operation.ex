defmodule Spectre.Instance.Operation do
  @moduledoc false

  # Only this small execution snapshot crosses into a temporary worker. The
  # owner retains the last completed value and its queue; neither enters GAM
  # authority. All effects still use the public facade and its durable boundary.
  alias Spectre.Agent.Runtime
  alias Spectre.Instance.Checkpoint
  alias Spectre.{Portable, Scope}

  @reserved_mind_options [:definition_ref, :state_revision]

  @typep snapshot :: %{
           required(:scope) => Scope.t(),
           optional(:definition_ref) => String.t(),
           optional(:instance_ref) => String.t(),
           optional(:authoring) => map() | nil,
           optional(:revision) => non_neg_integer(),
           optional(:value) => term()
         }
  @typep request ::
           {:turn, term(), keyword()}
           | {:advance, Spectre.Instance.Request.t(), keyword()}
           | {:recover_advance, Spectre.Instance.Request.t(), Spectre.Proposal.Result.t()}
           | {:propose, term(), keyword()}
           | {:checkpoint, Spectre.Store.config(), String.t(), non_neg_integer()}

  @doc "Runs one owner-selected mutation in its temporary worker; local state advances only after a fresh Scope check."
  @spec run(request(), snapshot()) ::
          {:reply, term()}
          | {:deferred, Spectre.Instance.Request.t(), Spectre.Proposal.Result.t()}
          | {:advance, {:ok, map()}, term()}
          | {:authoring, term(), term(), map()}
  def run({:turn, input, opts}, %{authoring: authoring} = snapshot) when not is_nil(authoring),
    do: Runtime.turn(input, opts, snapshot)

  def run({:advance, request, opts}, snapshot),
    do: Runtime.advance(request, opts, snapshot)

  def run({:recover_advance, request, proposal}, snapshot),
    do: Runtime.recover(request, proposal, snapshot)

  def run({:turn, input, opts}, snapshot) do
    with {:ok, opts} <- bind_mind_options(opts, snapshot),
         {:ok, result} <- Spectre.turn(snapshot.scope, input, snapshot.value, opts),
         {:ok, _scope} <- current_scope(snapshot.scope) do
      # A slow Mind must not publish local state based on a now-invalid Scope.
      # Input Evidence is already durable; rejecting this result does not undo it.
      {value, result} = Map.pop!(result, :state)
      {:advance, {:ok, result}, value}
    else
      {:error, _} = error -> {:reply, error}
    end
  end

  def run({:propose, candidate, opts}, snapshot),
    do: {:reply, Spectre.propose(snapshot.scope, candidate, opts)}

  def run({:checkpoint, store, key, expected}, snapshot) do
    reply =
      with {:ok, scope} <- current_scope(snapshot.scope) do
        Checkpoint.save(
          store,
          key,
          expected,
          Scope.domain_ref(scope),
          snapshot.definition_ref,
          %{
            revision: snapshot.revision,
            value: snapshot.value,
            components:
              if(Map.get(snapshot, :authoring), do: snapshot.authoring.components, else: %{})
          }
        )
      end

    {:reply, reply}
  end

  @doc "Revalidates the original authenticated Scope, without silently refreshing authentication after a restart."
  @spec current_scope(Scope.t()) :: {:ok, Scope.t()} | {:error, term()}
  def current_scope(%Scope{} = scope), do: Spectre.resume_scope(scope.domain, scope.context)

  defp bind_mind_options(opts, snapshot) do
    mind_opts = Keyword.get(opts, :mind_opts, [])

    if Portable.keyword?(mind_opts) do
      case Enum.find(@reserved_mind_options, &Keyword.has_key?(mind_opts, &1)) do
        nil ->
          bound =
            Keyword.merge(mind_opts,
              definition_ref: snapshot.definition_ref,
              state_revision: snapshot.revision
            )

          {:ok, Keyword.put(opts, :mind_opts, bound)}

        option ->
          {:error, {:reserved_instance_mind_option, option}}
      end
    else
      {:error, :invalid_mind_options}
    end
  end
end
