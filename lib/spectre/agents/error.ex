defmodule Spectre.Error do
  @moduledoc """
  Small, payload-free descriptions of common public failure reasons.

  `message/1` accepts a reason or its `{:error, reason}` envelope. It never
  inspects arbitrary terms, formats exception messages, evaluates callbacks or
  prints references, credentials, input or adapter options. Unknown reasons get
  a constant fallback. Keep the original structured term for application policy
  and trusted diagnostics; these descriptions are not error classification or
  permission to retry. Use `Spectre.Proposal.Result.status/1` for admission and
  execution results: `{:ok, result}` does not imply successful execution.
  """

  @messages %{
    instance_busy: "The Instance's waiting queue is full.",
    ingress_busy: "The Domain's ingress worker limit has been reached.",
    submission_queue_full: "The Domain's submission queue is full.",
    ingress_timeout: "The ingress callback did not finish within its deadline.",
    ingress_worker_failed: "The ingress worker stopped before completing its request.",
    instance_operation_stopped:
      "The local worker stopped. This does not prove that an external effect did not occur.",
    submission_context_generation_mismatch:
      "The authenticated context belongs to an earlier Domain generation.",
    sequencer_halted: "The Domain halted because it could not safely continue.",
    conflict: "The expected revision is no longer current.",
    ambiguous: "The result is uncertain. Do not assume no effect or retry an executor blindly.",
    not_found: "The requested record was not found.",
    unknown_class: "The consequence class is not declared on this Surface.",
    definition_surface_mismatch:
      "Fixed Definition declarations disagree with the Surface; inspect the structured report.",
    missing_foundation_fields:
      "Required foundation choices are missing; none were supplied implicitly.",
    genesis_verifier_required: "The Domain requires an explicit external Genesis verifier.",
    genesis_verifier_failed: "The external Genesis verifier could not establish the foundation.",
    genesis_constitution_mismatch: "The Constitution differs from the one named by Genesis.",
    unknown_agent_flow: "The exact Definition does not declare that flow.",
    unwired_flow_pipeline: "A flow's named input pipeline has not been wired by the host.",
    prompt_byte_limit_exceeded:
      "The complete prompt exceeds its byte budget; no text was silently dropped.",
    prompt_part_limit_exceeded: "The prompt exceeds its contribution count limit.",
    prompt_evidence_outside_turn: "The prompt cites Evidence outside the Turn's visible context.",
    candidate_template_override:
      "Occurrence data attempts to override a fixed Candidate template field."
  }
  @fallback "Spectre could not complete the request. Consult its structured result in a trusted diagnostic context."

  @doc "Describes a known reason without serializing its potentially sensitive details."
  @spec message(term()) :: String.t()
  def message({:error, reason}), do: describe(reason)
  def message(reason), do: describe(reason)

  defp describe(reason) when is_atom(reason), do: Map.get(@messages, reason, @fallback)

  defp describe(reason)
       when is_tuple(reason) and tuple_size(reason) > 0 and is_atom(elem(reason, 0)),
       do: Map.get(@messages, elem(reason, 0), @fallback)

  defp describe(_reason), do: @fallback
end
