defmodule Spectre.Reflection.Policy do
  @moduledoc """
  Host-owned authorization policy for the Reflection operation.

  Policies are compiled configuration. Runtime Skill data can request an
  inspection, but cannot supply or weaken this policy.
  """

  @enforce_keys [:actor_refs, :purposes, :max_evidence]
  defstruct actor_refs: [], purposes: [], max_evidence: 100

  @type t :: %__MODULE__{
          actor_refs: [String.t()],
          purposes: [String.t()],
          max_evidence: pos_integer()
        }

  @doc "Builds a closed Reflection policy."
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = policy), do: policy |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) and unique_keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, {:invalid_reflection_policy, :list}}
  end

  def new(attrs) when is_map(attrs) and not is_struct(attrs) do
    with [] <- Map.keys(attrs) -- [:actor_refs, :purposes, :max_evidence],
         {:ok, actors} <- names(Map.get(attrs, :actor_refs, []), :actor_refs),
         {:ok, purposes} <- names(Map.get(attrs, :purposes, []), :purposes),
         max when is_integer(max) and max > 0 and max <= 1_000 <-
           Map.get(attrs, :max_evidence, 100) do
      {:ok, %__MODULE__{actor_refs: actors, purposes: purposes, max_evidence: max}}
    else
      [_first | _rest] = unknown -> {:error, {:unknown_reflection_policy_fields, unknown}}
      {:error, _reason} = error -> error
      value -> {:error, {:invalid_reflection_policy_limit, value}}
    end
  end

  def new(value), do: {:error, {:invalid_reflection_policy, shape(value)}}

  @doc "Builds a policy or raises with its stable validation reason."
  @spec new!(map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid Reflection policy: #{inspect(reason)}"
    end
  end

  @doc "Authorizes one exact actor and purpose. Empty allowlists deny all."
  @spec authorize(t(), term(), term()) :: :ok | {:error, term()}
  def authorize(%__MODULE__{} = policy, actor_ref, purpose) do
    cond do
      not (is_binary(actor_ref) and actor_ref != "") ->
        {:error, :reflection_actor_required}

      not (is_binary(purpose) and purpose != "") ->
        {:error, :reflection_purpose_required}

      actor_ref not in policy.actor_refs ->
        {:error, :reflection_actor_not_authorized}

      purpose not in policy.purposes ->
        {:error, :reflection_purpose_not_authorized}

      true ->
        :ok
    end
  end

  defp names(values, field) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")),
      do: {:ok, values |> Enum.uniq() |> Enum.sort()},
      else: {:error, {:invalid_reflection_policy_field, field}}
  end

  defp names(_value, field), do: {:error, {:invalid_reflection_policy_field, field}}

  defp unique_keyword?(attrs),
    do: length(Keyword.keys(attrs)) == length(Enum.uniq(Keyword.keys(attrs)))

  defp shape(value) when is_map(value), do: :map
  defp shape(_value), do: :other
end
