defmodule Spectre.Scope do
  @moduledoc """
  Ephemeral handle binding a scope identifier to authenticated ingress context.

  A Scope is a projection over the Domain ledger. Copying this struct does not
  copy a Mandate, a balance, or any other authority.
  """

  alias Spectre.Domain
  alias Spectre.SubmissionContext

  @enforce_keys [:domain, :context]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            domain: Domain.t(),
            context: SubmissionContext.t()
          }

  @spec new(Domain.t(), SubmissionContext.t()) :: {:ok, t()} | {:error, term()}
  def new(%Domain{ref: domain_ref} = domain, %SubmissionContext{} = context) do
    if context.domain_ref == domain_ref,
      do: {:ok, %__MODULE__{domain: domain, context: context}},
      else: {:error, :scope_domain_mismatch}
  end

  def new(_domain, _context), do: {:error, :invalid_scope}

  @doc "Returns the durable Scope reference bound by the authenticated context."
  @spec ref(t()) :: String.t()
  def ref(%__MODULE__{context: %SubmissionContext{scope_ref: ref}}), do: ref

  @doc "Returns the Domain reference bound by both the handle and its context."
  @spec domain_ref(t()) :: String.t()
  def domain_ref(%__MODULE__{domain: %Domain{ref: ref}}), do: ref
end
