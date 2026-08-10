defmodule Spectre.Governance.Approval.Policy do
  @moduledoc """
  Host-owned approval policy keyed by Candidate risk.

  The default permits automatic approval only for low-risk Candidates. Medium,
  high, and critical changes require an explicit human approval receipt.
  """

  @risks [:low, :medium, :high, :critical]
  @modes [:automatic, :human]
  @default %{low: :automatic, medium: :human, high: :human, critical: :human}

  @enforce_keys [:requirements]
  defstruct requirements: @default

  @type mode :: :automatic | :human
  @type t :: %__MODULE__{requirements: %{required(atom()) => mode()}}

  @doc "Returns the conservative default policy."
  @spec default() :: t()
  def default, do: %__MODULE__{requirements: @default}

  @doc "Builds a complete risk policy."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = policy), do: new(policy.requirements)

  def new(attrs) when is_list(attrs) do
    if Enum.all?(attrs, &match?({_, _}, &1)),
      do: build(attrs),
      else: {:error, {:invalid_governance_approval_policy, :invalid_list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs), do: build(attrs)

  def new(value), do: {:error, {:invalid_governance_approval_policy, value}}

  defp build(attrs) do
    with {:ok, requirements} <- normalize(attrs),
         true <- Map.keys(requirements) |> Enum.sort() == Enum.sort(@risks) do
      {:ok, %__MODULE__{requirements: requirements}}
    else
      false -> {:error, :incomplete_governance_approval_policy}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the minimum approval mode for a risk class."
  @spec required_mode(t(), atom()) :: {:ok, mode()} | {:error, term()}
  def required_mode(%__MODULE__{requirements: requirements}, risk) do
    case Map.fetch(requirements, risk) do
      {:ok, mode} -> {:ok, mode}
      :error -> {:error, {:unknown_governance_risk, risk}}
    end
  end

  @doc "Checks whether an observed mode satisfies the configured policy."
  @spec allows?(t(), atom(), mode()) :: boolean()
  def allows?(%__MODULE__{} = policy, risk, mode) when mode in @modes do
    case required_mode(policy, risk) do
      {:ok, :automatic} -> true
      {:ok, :human} -> mode == :human
      {:error, _reason} -> false
    end
  end

  def allows?(%__MODULE__{}, _risk, _mode), do: false

  defp normalize(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {risk, mode}, {:ok, normalized} ->
      with {:ok, risk} <- normalize_enum(risk, @risks, :risk),
           {:ok, mode} <- normalize_enum(mode, @modes, :mode),
           false <- Map.has_key?(normalized, risk) do
        {:cont, {:ok, Map.put(normalized, risk, mode)}}
      else
        true -> {:halt, {:error, {:duplicate_governance_approval_risk, risk}}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp normalize_enum(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:invalid_governance_approval_field, field, value}}
      normalized -> {:ok, normalized}
    end
  end

  defp normalize_enum(value, allowed, field) do
    if value in allowed,
      do: {:ok, value},
      else: {:error, {:invalid_governance_approval_field, field, value}}
  end
end
