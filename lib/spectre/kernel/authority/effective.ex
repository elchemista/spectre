defmodule Spectre.Kernel.Authority.Effective do
  @moduledoc """
  Immutable authority resolution for one admission decision.

  This is a capability-free, non-durable value. Both forms retain the exact
  content-addressed Candidate reference checked by Authority, preventing a
  successful resolution from being reused for another proposal. The ordinary
  form otherwise points to the already-validated Mandate instead of copying
  all of its fields; the retained-controller form adds only its controller.

  Keeping this distinct from `Spectre.Mandate` prevents an ephemeral narrowing
  from masquerading as a content-addressed durable Mandate with a stale ref.
  """

  alias Spectre.{Candidate, Mandate}
  alias Spectre.GovernedAct.Class

  @retained_revocation_class "mandate.revoke"

  @enforce_keys [:mandate, :mode, :candidate_ref]
  defstruct @enforce_keys ++ [controller_ref: nil]

  @type t :: %__MODULE__{
          mandate: Mandate.t(),
          mode: :ordinary | :retained_revocation,
          candidate_ref: String.t(),
          controller_ref: String.t() | nil
        }

  @type snapshot :: Mandate.t() | map()

  @doc "Projects an ordinary durable Mandate into the Decision boundary."
  @spec from_mandate(Mandate.t(), Candidate.t()) :: t()
  def from_mandate(%Mandate{} = mandate, %Candidate{} = candidate) do
    %__MODULE__{mandate: mandate, mode: :ordinary, candidate_ref: candidate.ref}
  end

  @doc "Builds the one-operation authority retained by a revocation controller."
  @spec retained_revocation(Mandate.t(), Candidate.t(), String.t()) :: t()
  def retained_revocation(%Mandate{} = mandate, %Candidate{} = candidate, controller_ref) do
    %__MODULE__{
      mandate: mandate,
      mode: :retained_revocation,
      candidate_ref: candidate.ref,
      controller_ref: controller_ref
    }
  end

  @doc "Returns the durable Mandate identity represented by this resolution."
  @spec ref(t()) :: String.t()
  def ref(%__MODULE__{mandate: %Mandate{ref: ref}}), do: ref

  @doc "Returns the durable Mandate revision represented by this resolution."
  @spec revision(t()) :: pos_integer()
  def revision(%__MODULE__{mandate: %Mandate{revision: revision}}), do: revision

  @doc "Materializes the exact authority fields consumed by Decision."
  @spec snapshot(t(), Candidate.t()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(
        %__MODULE__{
          mandate: %Mandate{} = mandate,
          mode: :ordinary,
          candidate_ref: candidate_ref,
          controller_ref: nil
        },
        %Candidate{ref: candidate_ref}
      )
      when is_binary(candidate_ref) and candidate_ref != "",
      do: {:ok, mandate}

  def snapshot(
        %__MODULE__{
          mandate: %Mandate{} = mandate,
          mode: :retained_revocation,
          candidate_ref: candidate_ref,
          controller_ref: controller_ref
        },
        %Candidate{ref: candidate_ref} = candidate
      )
      when is_binary(candidate_ref) and candidate_ref != "" and is_binary(controller_ref) and
             controller_ref != "" do
    {:ok,
     %{
       ref: mandate.ref,
       revision: mandate.revision,
       grantor_ref: controller_ref,
       holder_ref: controller_ref,
       accountable_ref: mandate.accountable_ref,
       scope_refs: [candidate.scope_ref],
       subject_refs: [],
       target_refs: [mandate.ref],
       classes: [@retained_revocation_class],
       ceiling: candidate.row,
       purpose_ref: Class.retained_revocation_purpose_ref(),
       purpose_params: %{},
       conditions: [],
       not_before: mandate.not_before,
       expires_at: mandate.expires_at,
       meters: %{}
     }}
  end

  def snapshot(%__MODULE__{}, %Candidate{}),
    do: {:error, :effective_authority_candidate_mismatch}
end
