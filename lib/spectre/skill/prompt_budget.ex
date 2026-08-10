defmodule Spectre.Skill.PromptBudget do
  @moduledoc """
  Closed per-Skill prompt budget derived from canonical fragments.

  A budget is part of the Skill Definition rather than a best-effort option at
  render time. Runtime Skills must cap every fragment, and the sum of those
  caps must fit inside the Skill ceiling. Compiled Skills may retain legacy
  uncapped fragments; their current content estimate is charged in full.
  """

  alias Spectre.Canonical.Value
  alias Spectre.Prompt.Fragment

  @schema_version 1
  @default_token_cap 512
  @absolute_token_cap 4_096

  @enforce_keys [
    :schema_version,
    :token_cap,
    :reserved_tokens,
    :estimated_tokens,
    :fragment_count
  ]
  defstruct schema_version: @schema_version,
            token_cap: @default_token_cap,
            reserved_tokens: 0,
            estimated_tokens: 0,
            fragment_count: 0

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          token_cap: pos_integer(),
          reserved_tokens: non_neg_integer(),
          estimated_tokens: non_neg_integer(),
          fragment_count: non_neg_integer()
        }

  @doc "Returns the current Skill prompt-budget schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Builds and validates a budget from canonical fragments."
  @spec new([Fragment.t() | map()], keyword()) :: {:ok, t()} | {:error, term()}
  def new(fragments, opts \\ [])

  def new(fragments, opts) when is_list(fragments) and is_list(opts) do
    token_cap = Keyword.get(opts, :token_cap, @default_token_cap)
    reserved_tokens = Keyword.get(opts, :reserved_tokens, 0)
    require_caps? = Keyword.get(opts, :require_fragment_caps?, false)

    with :ok <- validate_options(opts),
         :ok <- validate_cap(token_cap),
         :ok <- validate_reserved(reserved_tokens, token_cap),
         {:ok, usage} <- fragment_usage(fragments, require_caps?),
         :ok <- validate_usage(usage.reserved_tokens, token_cap) do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         token_cap: token_cap,
         reserved_tokens: max(reserved_tokens, usage.reserved_tokens),
         estimated_tokens: usage.estimated_tokens,
         fragment_count: length(fragments)
       }}
    end
  end

  def new(fragments, opts),
    do: {:error, {:invalid_skill_prompt_budget_input, shape(fragments), shape(opts)}}

  @doc "Builds a prompt budget or raises with its stable validation reason."
  @spec new!([Fragment.t() | map()], keyword()) :: t()
  def new!(fragments, opts \\ []) do
    case new(fragments, opts) do
      {:ok, budget} -> budget
      {:error, reason} -> raise ArgumentError, "invalid Skill prompt budget: #{inspect(reason)}"
    end
  end

  @doc "Restores and validates a budget from canonical data."
  @spec from_data(map()) :: {:ok, t()} | {:error, term()}
  def from_data(%{
        schema_version: schema_version,
        token_cap: token_cap,
        reserved_tokens: reserved_tokens,
        estimated_tokens: estimated_tokens,
        fragment_count: fragment_count
      }) do
    validate_data(schema_version, token_cap, reserved_tokens, estimated_tokens, fragment_count)
  end

  def from_data(%{
        "schema_version" => schema_version,
        "token_cap" => token_cap,
        "reserved_tokens" => reserved_tokens,
        "estimated_tokens" => estimated_tokens,
        "fragment_count" => fragment_count
      }) do
    validate_data(schema_version, token_cap, reserved_tokens, estimated_tokens, fragment_count)
  end

  def from_data(value), do: {:error, {:invalid_skill_prompt_budget, shape(value)}}

  @doc "Returns the portable canonical representation."
  @spec to_data(t()) :: map()
  def to_data(%__MODULE__{} = budget) do
    %{
      schema_version: budget.schema_version,
      token_cap: budget.token_cap,
      reserved_tokens: budget.reserved_tokens,
      estimated_tokens: budget.estimated_tokens,
      fragment_count: budget.fragment_count
    }
  end

  @doc "Returns the canonical SHA-256 budget digest."
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{} = budget), do: budget |> to_data() |> Value.digest!()

  @spec validate_data(term(), term(), term(), term(), term()) ::
          {:ok, t()} | {:error, term()}
  defp validate_data(@schema_version, token_cap, reserved, estimated, count) do
    with :ok <- validate_cap(token_cap),
         :ok <- validate_reserved(reserved, token_cap),
         true <- is_integer(estimated) and estimated >= 0,
         true <- is_integer(count) and count >= 0 do
      {:ok,
       %__MODULE__{
         schema_version: @schema_version,
         token_cap: token_cap,
         reserved_tokens: reserved,
         estimated_tokens: estimated,
         fragment_count: count
       }}
    else
      false -> {:error, :invalid_skill_prompt_budget_counters}
      {:error, _reason} = error -> error
    end
  end

  defp validate_data(version, _token_cap, _reserved, _estimated, _count),
    do: {:error, {:unsupported_skill_prompt_budget_schema, version}}

  @spec validate_options(keyword()) :: :ok | {:error, term()}
  defp validate_options(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [] <- Keyword.keys(opts) -- [:token_cap, :reserved_tokens, :require_fragment_caps?],
         true <- is_boolean(Keyword.get(opts, :require_fragment_caps?, false)) do
      :ok
    else
      false ->
        {:error, :invalid_skill_prompt_budget_options}

      [_first | _rest] = unknown ->
        {:error, {:unknown_skill_prompt_budget_options, Enum.uniq(unknown)}}
    end
  end

  @spec validate_cap(term()) :: :ok | {:error, term()}
  defp validate_cap(cap) when is_integer(cap) and cap > 0 and cap <= @absolute_token_cap,
    do: :ok

  defp validate_cap(cap),
    do: {:error, {:invalid_skill_prompt_token_cap, cap, @absolute_token_cap}}

  @spec validate_reserved(term(), pos_integer()) :: :ok | {:error, term()}
  defp validate_reserved(reserved, cap)
       when is_integer(reserved) and reserved >= 0 and reserved <= cap,
       do: :ok

  defp validate_reserved(reserved, cap),
    do: {:error, {:invalid_skill_prompt_reserved_tokens, reserved, cap}}

  @spec fragment_usage([Fragment.t() | map()], boolean()) :: {:ok, map()} | {:error, term()}
  defp fragment_usage(fragments, require_caps?) do
    fragments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{reserved_tokens: 0, estimated_tokens: 0}}, fn
      {fragment, index}, {:ok, usage} ->
        with {:ok, content, cap} <- fragment_fields(fragment, index),
             estimated = estimate(content),
             :ok <- require_fragment_cap(cap, require_caps?, index),
             :ok <- validate_fragment_cap(cap, estimated, index) do
          reserved = cap || estimated

          {:cont,
           {:ok,
            %{
              reserved_tokens: usage.reserved_tokens + reserved,
              estimated_tokens: usage.estimated_tokens + estimated
            }}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
    end)
  end

  @spec fragment_fields(Fragment.t() | map(), non_neg_integer()) ::
          {:ok, String.t(), pos_integer() | nil} | {:error, term()}
  defp fragment_fields(%Fragment{content: content, token_cap: cap}, index),
    do: validate_fragment_fields(content, cap, index)

  defp fragment_fields(fragment, index) when is_map(fragment) do
    content = Map.get(fragment, :content, Map.get(fragment, "content"))
    cap = Map.get(fragment, :token_cap, Map.get(fragment, "token_cap"))
    validate_fragment_fields(content, cap, index)
  end

  defp fragment_fields(value, index),
    do: {:error, {:invalid_skill_prompt_fragment, index, shape(value)}}

  @spec validate_fragment_fields(term(), term(), non_neg_integer()) ::
          {:ok, String.t(), pos_integer() | nil} | {:error, term()}
  defp validate_fragment_fields(content, cap, _index)
       when is_binary(content) and (is_nil(cap) or (is_integer(cap) and cap > 0)),
       do: {:ok, content, cap}

  defp validate_fragment_fields(_content, cap, index),
    do: {:error, {:invalid_skill_prompt_fragment_cap, index, cap}}

  @spec require_fragment_cap(term(), boolean(), non_neg_integer()) :: :ok | {:error, term()}
  defp require_fragment_cap(nil, true, index),
    do: {:error, {:runtime_skill_prompt_fragment_requires_cap, index}}

  defp require_fragment_cap(_cap, _required?, _index), do: :ok

  @spec validate_fragment_cap(pos_integer() | nil, non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, term()}
  defp validate_fragment_cap(nil, _estimated, _index), do: :ok
  defp validate_fragment_cap(cap, estimated, _index) when estimated <= cap, do: :ok

  defp validate_fragment_cap(cap, estimated, index),
    do: {:error, {:skill_prompt_fragment_over_budget, index, estimated, cap}}

  @spec validate_usage(non_neg_integer(), pos_integer()) :: :ok | {:error, term()}
  defp validate_usage(reserved, cap) when reserved <= cap, do: :ok
  defp validate_usage(reserved, cap), do: {:error, {:skill_prompt_budget_exceeded, reserved, cap}}

  @spec estimate(String.t()) :: non_neg_integer()
  defp estimate(""), do: 0
  defp estimate(content), do: div(byte_size(content) + 3, 4)

  @spec shape(term()) :: atom()
  defp shape(value) when is_list(value), do: :list
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_binary(value), do: :binary
  defp shape(_value), do: :other
end
