defmodule Spectre.Inference.Profile do
  @moduledoc """
  Provider-neutral cognitive capability profile.
  """

  alias Spectre.Inference.Constraints

  defstruct [
    :id,
    :rank,
    :model,
    :context_window,
    :cost_tier,
    :latency_tier,
    :profile_hash,
    supports: MapSet.new([:text]),
    privacy: :cloud,
    fallback: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          id: term(),
          rank: integer(),
          model: term(),
          supports: MapSet.t(atom()),
          context_window: pos_integer() | nil,
          privacy: :local | :private_cloud | :cloud,
          cost_tier: :low | :medium | :high,
          latency_tier: :low | :medium | :high,
          fallback: [term()],
          metadata: map(),
          profile_hash: String.t() | nil
        }

  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = profile), do: finalize(profile)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    supports = attrs |> Map.get(:supports, [:text]) |> MapSet.new()

    profile =
      attrs
      |> Map.put(:supports, supports)
      |> Map.update(:fallback, [], &List.wrap/1)
      |> then(&struct(__MODULE__, Map.take(&1, fields())))

    finalize(profile)
  end

  @doc """
  Returns whether this profile satisfies all hard request constraints.
  """
  @spec compatible?(t(), Spectre.Inference.Request.t(), [t()]) :: boolean()
  def compatible?(%__MODULE__{} = profile, request, profiles) do
    constraints = Constraints.new(request.constraints)

    modalities_supported?(profile, request.modalities) and
      structured_supported?(profile, constraints) and
      context_supported?(profile, constraints) and
      privacy_supported?(profile, constraints) and
      cost_supported?(profile, constraints) and
      latency_supported?(profile, constraints) and
      minimum_supported?(profile, constraints, profiles)
  end

  @spec hash(t()) :: String.t()
  def hash(%__MODULE__{} = profile) do
    safe =
      profile
      |> Map.from_struct()
      |> Map.drop([:profile_hash])
      |> Map.update!(:supports, &(&1 |> MapSet.to_list() |> Enum.sort()))
      |> Map.update!(:metadata, &Map.drop(&1, [:api_key, :token, :secret, :credentials]))

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(safe, [:deterministic]))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  @spec modalities_supported?(t(), [atom()]) :: boolean()
  defp modalities_supported?(profile, modalities),
    do: Enum.all?(modalities, &MapSet.member?(profile.supports, &1))

  @spec structured_supported?(t(), Constraints.t()) :: boolean()
  defp structured_supported?(_profile, %Constraints{structured_output?: false}), do: true

  defp structured_supported?(profile, %Constraints{}),
    do: MapSet.member?(profile.supports, :structured_output)

  @spec context_supported?(t(), Constraints.t()) :: boolean()
  defp context_supported?(_profile, %Constraints{context_tokens: nil}), do: true
  defp context_supported?(%__MODULE__{context_window: nil}, %Constraints{}), do: false

  defp context_supported?(profile, constraints),
    do: profile.context_window >= constraints.context_tokens

  @spec privacy_supported?(t(), Constraints.t()) :: boolean()
  defp privacy_supported?(%__MODULE__{privacy: :local}, _constraints), do: true

  defp privacy_supported?(%__MODULE__{privacy: :private_cloud}, %Constraints{
         privacy: privacy
       }),
       do: privacy in [:cloud_allowed, :private_cloud_only]

  defp privacy_supported?(%__MODULE__{privacy: :cloud}, %Constraints{privacy: privacy}),
    do: privacy == :cloud_allowed

  @spec cost_supported?(t(), Constraints.t()) :: boolean()
  defp cost_supported?(_profile, %Constraints{maximum_cost_tier: nil}), do: true

  defp cost_supported?(profile, constraints) do
    tier_rank(profile.cost_tier) <= tier_rank(constraints.maximum_cost_tier)
  end

  @spec latency_supported?(t(), Constraints.t()) :: boolean()
  defp latency_supported?(_profile, %Constraints{maximum_latency_ms: nil}), do: true

  defp latency_supported?(profile, constraints) do
    case Map.get(profile.metadata, :estimated_latency_ms) do
      latency when is_integer(latency) -> latency <= constraints.maximum_latency_ms
      _unknown -> true
    end
  end

  @spec minimum_supported?(t(), Constraints.t(), [t()]) :: boolean()
  defp minimum_supported?(_profile, %Constraints{minimum_level: nil}, _profiles), do: true

  defp minimum_supported?(profile, constraints, profiles) do
    case Enum.find(profiles, &(&1.id == constraints.minimum_level)) do
      %__MODULE__{rank: rank} -> profile.rank >= rank
      nil -> false
    end
  end

  @spec tier_rank(atom()) :: integer()
  defp tier_rank(:low), do: 10
  defp tier_rank(:medium), do: 20
  defp tier_rank(:high), do: 30

  @spec validate!(t()) :: :ok
  defp validate!(%__MODULE__{} = profile) do
    if is_nil(profile.id), do: raise(ArgumentError, "profile id is required")
    unless is_integer(profile.rank), do: raise(ArgumentError, "profile rank must be an integer")
    if is_nil(profile.model), do: raise(ArgumentError, "profile model is required")

    unless profile.privacy in [:local, :private_cloud, :cloud],
      do: raise(ArgumentError, "invalid profile privacy")

    unless profile.cost_tier in [:low, :medium, :high],
      do: raise(ArgumentError, "invalid profile cost tier")

    unless profile.latency_tier in [:low, :medium, :high],
      do: raise(ArgumentError, "invalid profile latency tier")

    unless is_map(profile.metadata), do: raise(ArgumentError, "profile metadata must be a map")
    :ok
  end

  @spec finalize(t()) :: t()
  defp finalize(%__MODULE__{} = profile) do
    validate!(profile)

    case profile.profile_hash do
      nil -> %{profile | profile_hash: hash(profile)}
      hash when is_binary(hash) and hash != "" -> profile
      _invalid -> raise ArgumentError, "profile hash must be a non-empty string"
    end
  end

  @spec fields() :: [atom()]
  defp fields do
    __MODULE__.__struct__()
    |> Map.keys()
    |> List.delete(:__struct__)
  end
end
