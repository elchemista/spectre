defmodule Spectre.Governance.Builder do
  @moduledoc """
  Shared construction boundary for administrative Candidate helpers.

  A helper supplies the intrinsic class, consequence, Row and execution
  identity. The caller may supply only the ordinary proposal fields listed
  here; forced fields always win. Building a Candidate still grants no
  authority and performs no ledger write.
  """

  require Spectre.Portable

  alias Spectre.{Candidate, Portable, Row, Scope}
  alias Spectre.GovernedAct.{Class, Execution}

  @candidate_fields [
    :identity_key,
    :requested_mandate_ref,
    :accountable_ref,
    :subject_refs,
    :target_refs,
    :purpose_ref,
    :purpose_params,
    :consent,
    :evidence_refs,
    :presentation_ref
  ]

  @type forced :: %{
          required(:class) => String.t(),
          required(:consequence) => map(),
          required(:row) => Row.t(),
          required(:executor_ref) => String.t(),
          required(:executor_contract_ref) => String.t(),
          required(:target_refs) => [String.t()],
          required(:meter_requests) => map(),
          required(:observation_window_ms) => non_neg_integer()
        }

  @doc false
  @spec internal(
          Scope.t(),
          String.t(),
          map(),
          map() | keyword(),
          [String.t()]
        ) :: {:ok, Candidate.t()} | {:error, term()}
  def internal(%Scope{} = scope, class, consequence, attrs, required_targets)
      when is_binary(class) and is_map(consequence) and is_list(required_targets) do
    with {:ok, row} <- intrinsic_row(class),
         {:ok, attrs} <- normalize_attrs(attrs) do
      build(
        scope,
        attrs,
        %{
          class: class,
          consequence: consequence,
          row: row,
          executor_ref: Execution.kernel_executor_ref(),
          executor_contract_ref: Execution.kernel_contract_ref(),
          target_refs: target_refs(attrs, :target_refs, required_targets),
          meter_requests: %{},
          observation_window_ms: 0
        }
      )
    end
  end

  @doc false
  @spec build(Scope.t(), map(), forced()) :: {:ok, Candidate.t()} | {:error, term()}
  def build(%Scope{} = scope, attrs, forced) when is_map(attrs) and is_map(forced) do
    with {:ok, identity_key} <- required_binary(attrs, :identity_key),
         {:ok, mandate_ref} <- required_ref(attrs, :requested_mandate_ref),
         {:ok, accountable_ref} <- required_ref(attrs, :accountable_ref),
         {:ok, purpose_ref} <- required_ref(attrs, :purpose_ref) do
      Candidate.new(%{
        identity_key: identity_key,
        class: forced.class,
        consequence: forced.consequence,
        row: forced.row,
        requested_mandate_ref: mandate_ref,
        proposer_ref: scope.context.authenticated_principal_ref,
        executor_ref: forced.executor_ref,
        accountable_ref: accountable_ref,
        scope_ref: Scope.ref(scope),
        subject_refs: Map.get(attrs, :subject_refs, []),
        target_refs: forced.target_refs,
        purpose_ref: purpose_ref,
        purpose_params: Map.get(attrs, :purpose_params, %{}),
        consent: Map.get(attrs, :consent),
        evidence_refs: Map.get(attrs, :evidence_refs, []),
        presentation_ref: Map.get(attrs, :presentation_ref),
        meter_requests: forced.meter_requests,
        executor_contract_ref: forced.executor_contract_ref,
        observation_window_ms: forced.observation_window_ms
      })
    end
  end

  @doc false
  @spec normalize_attrs(term(), [atom()]) :: {:ok, map()} | {:error, term()}
  def normalize_attrs(attrs, extra_fields \\ []) when is_list(extra_fields) do
    Portable.normalize_attrs(attrs, @candidate_fields ++ extra_fields, :governance)
  end

  @doc false
  @spec required_ref(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  def required_ref(attrs, key) do
    case Map.get(attrs, key) do
      value when Portable.is_non_empty_binary(value) -> {:ok, value}
      _missing -> {:error, {:missing_governance_candidate_field, key}}
    end
  end

  @doc false
  @spec required_binary(map(), atom()) :: {:ok, String.t()} | {:error, term()}
  def required_binary(attrs, key), do: required_ref(attrs, key)

  @doc false
  @spec required_integer(map(), atom()) :: {:ok, integer()} | {:error, term()}
  def required_integer(attrs, key) do
    case Map.get(attrs, key) do
      value when is_integer(value) -> {:ok, value}
      _missing -> {:error, {:missing_governance_candidate_field, key}}
    end
  end

  @doc false
  @spec target_refs(map(), atom(), [String.t()]) :: [String.t()]
  def target_refs(attrs, key, required) do
    attrs
    |> Map.get(key, [])
    |> List.wrap()
    |> Kernel.++(required)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc false
  @spec intrinsic_row(term()) :: {:ok, Row.t()} | {:error, term()}
  def intrinsic_row(class) do
    case Class.dimensions(class) do
      {:ok, dimensions} -> {:ok, row(dimensions)}
      :application -> {:error, {:non_intrinsic_governance_class, class}}
    end
  end

  defp row(dimensions), do: Enum.reduce(dimensions, %Row{}, &Map.replace!(&2, &1, true))
end
