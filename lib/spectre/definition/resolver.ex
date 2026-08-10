defmodule Spectre.Definition.Resolver do
  @moduledoc """
  Verified resolution of published canonical Definitions.

  Resolution always re-reads Definition, Manifest, and publication receipt
  from the configured Store. Code drift is never hidden: without trusted
  observations the result is marked `:unobserved`; matching builds are marked
  `:matched`; changed or missing builds fail by default and can be returned as
  evidence only with the explicit `on_drift: :report` host policy.
  """

  alias Spectre.Definition.Candidate
  alias Spectre.Definition.Candidate.Ref, as: CandidateRef
  alias Spectre.Definition.Ref
  alias Spectre.Definition.Store
  alias Spectre.Execution.Closure

  @type drift_status ::
          %{status: :unobserved | :matched, drifts: []}
          | %{status: :drifted, drifts: [Closure.drift()]}

  @type resolution :: %{
          required(:definition_ref) => Ref.t(),
          required(:definition) => Spectre.Definition.Canonical.t(),
          required(:manifest) => Spectre.Definition.Manifest.t(),
          required(:publication_receipt) => Store.receipt(),
          required(:drift) => drift_status()
        }

  @doc "Fetches and verifies a Definition plus its current build observations."
  @spec resolve(Store.config(), Ref.t() | String.t(), keyword()) ::
          :not_found | {:ok, resolution()} | {:error, term()}
  def resolve(store, ref, opts \\ []) when is_list(opts) do
    with {:ok, artifact} <- Store.fetch(store, ref, opts),
         {:ok, drift} <- resolve_drift(artifact.manifest.execution_closure, opts) do
      {:ok,
       %{
         definition_ref: artifact.manifest.definition_ref,
         definition: artifact.definition,
         manifest: artifact.manifest,
         publication_receipt: artifact.receipt,
         drift: drift
       }}
    else
      :not_found -> :not_found
      {:error, _reason} = error -> error
    end
  end

  @doc "Resolves a Definition or raises when it is missing or invalid."
  @spec resolve!(Store.config(), Ref.t() | String.t(), keyword()) :: resolution()
  def resolve!(store, ref, opts \\ []) do
    case resolve(store, ref, opts) do
      {:ok, resolution} -> resolution
      :not_found -> raise ArgumentError, "Definition does not resolve: #{inspect(ref)}"
      {:error, reason} -> raise ArgumentError, "invalid Definition resolution: #{inspect(reason)}"
    end
  end

  @doc """
  Enforces the Definition-before-activation publication protocol.

  This does not perform activation or CAS. It verifies the durability pairing,
  then re-reads the published artifact through `resolve/3`; the returned
  resolution is the only acceptable input to a later activation CAS.
  """
  @spec resolve_for_activation(Store.config(), Ref.t() | String.t(), keyword()) ::
          :not_found | {:ok, resolution()} | {:error, term()}
  def resolve_for_activation(store, ref, opts \\ []) when is_list(opts) do
    with :ok <- Store.validate_durability_pair(Keyword.get(opts, :checkpoint_store), store) do
      resolve(store, ref, opts)
    end
  end

  @doc """
  Creates and publishes a minimal bootstrap Candidate from a verified
  Definition resolution.

  This boundary is for trusted host code and compiled Definition lowering;
  runtime-authored ChangeSets and promotion gates are intentionally outside
  the 0.2.3 scope.
  """
  @spec bootstrap_candidate(Store.config(), Ref.t() | String.t(), keyword()) ::
          {:ok, CandidateRef.t()} | {:error, term()} | :not_found
  def bootstrap_candidate(store, definition_ref, opts \\ []) when is_list(opts) do
    with {:ok, resolution} <- resolve_for_activation(store, definition_ref, opts),
         {:ok, candidate} <- Candidate.from_resolution(resolution, opts),
         do: Store.publish_candidate(store, candidate, opts)
  end

  @doc """
  Re-reads a Candidate by Ref and re-resolves its published Definition.

  The returned pair is the only accepted input to the activation snapshot
  constructor; a caller-supplied Candidate struct is never trusted.
  """
  @spec resolve_candidate_for_activation(
          Store.config(),
          CandidateRef.t() | String.t(),
          keyword()
        ) ::
          {:ok, %{candidate: Candidate.t(), resolution: resolution()}}
          | {:error, term()}
          | :not_found
  def resolve_candidate_for_activation(store, candidate_ref, opts \\ []) when is_list(opts) do
    with :ok <- Store.validate_durability_pair(Keyword.get(opts, :checkpoint_store), store),
         {:ok, candidate} <- Store.fetch_candidate(store, candidate_ref, opts),
         {:ok, resolution} <- resolve_for_activation(store, candidate.definition_ref, opts) do
      {:ok, %{candidate: candidate, resolution: resolution}}
    end
  end

  @spec resolve_drift(Closure.t(), keyword()) :: {:ok, drift_status()} | {:error, term()}
  defp resolve_drift(closure, opts) do
    case Keyword.fetch(opts, :observed_builds) do
      :error ->
        {:ok, %{status: :unobserved, drifts: []}}

      {:ok, observed} ->
        compare_builds(closure, observed, Keyword.get(opts, :on_drift, :reject))
    end
  end

  @spec compare_builds(Closure.t(), term(), term()) ::
          {:ok, drift_status()} | {:error, term()}
  defp compare_builds(closure, observed, policy) when policy in [:reject, :report] do
    case Closure.compare_builds(closure, observed) do
      {:ok, :matched} ->
        {:ok, %{status: :matched, drifts: []}}

      {:drift, drifts} when policy == :report ->
        {:ok, %{status: :drifted, drifts: drifts}}

      {:drift, drifts} ->
        {:error, {:definition_code_drift, drifts}}

      {:error, _reason} = error ->
        error
    end
  end

  defp compare_builds(_closure, _observed, policy),
    do: {:error, {:invalid_definition_drift_policy, policy}}
end
