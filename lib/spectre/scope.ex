defmodule Spectre.Scope do
  @moduledoc """
  Ephemeral handle binding a scope identifier to authenticated ingress context.

  A Scope is a projection over the Domain ledger. Copying this struct does not
  copy a Mandate, a balance, or any other authority.
  """

  alias Spectre.Domain
  alias Spectre.SubmissionContext

  @enforce_keys [:domain, :ref, :context]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            domain: Domain.t(),
            ref: String.t(),
            context: SubmissionContext.t()
          }

  @spec new(Domain.t(), String.t(), SubmissionContext.t()) ::
          {:ok, t()} | {:error, term()}
  def new(%Domain{ref: domain_ref} = domain, ref, %SubmissionContext{} = context)
      when is_binary(ref) and ref != "" do
    cond do
      context.domain_ref != domain_ref -> {:error, :scope_domain_mismatch}
      context.scope_ref != ref -> {:error, :scope_context_mismatch}
      true -> {:ok, %__MODULE__{domain: domain, ref: ref, context: context}}
    end
  end

  def new(_domain, _ref, _context), do: {:error, :invalid_scope}
end
