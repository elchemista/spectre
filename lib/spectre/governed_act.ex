defmodule Spectre.GovernedAct do
  @moduledoc """
  Internal architecture of the Governed Act Model runtime.

  This namespace contains the deterministic side of Spectre. It turns a
  verified, append-only Domain history into disposable state and rejects any
  history that could not have been produced by the model. It performs no I/O
  and owns no authority outside the facts present in that history.

  The main path is:

      Ledger entries
          |
          v
      Spectre.Domain.Event          canonical event grammar
          |
          v
      Spectre.GovernedAct.Fold      ordering and transition router
          |-- Transition.*          one semantic lifecycle per module
          |-- Batch                 atomic cross-event invariants
          `-- Completeness          whole-prefix invariants
          |
          v
      Spectre.GovernedAct.State     disposable read model
          |
          `-- View                  read-only facts for kernel and host

  `Spectre.Domain.Projection` is the live replay driver. `Spectre.Audit` is an
  independent export driver; both use the same pure fold so the semantic rules
  cannot drift. `Spectre.Kernel` evaluates a Candidate from immutable views,
  while `Spectre.Domain.Sequencer` alone orders and appends the resulting batch.

  ## Transition families

    * `Transition.Foundation` establishes Genesis and revisable host facts.
    * `Transition.Authority` replays Mandate issue, restriction and revocation.
    * `Transition.Scope` binds authenticated contexts to durable Scopes.
    * `Transition.Information` handles Evidence, presentation, disclosure and
      erasure lineage.
    * `Transition.Admission` independently revalidates Decision and Act records.
    * `Transition.Execution` covers dispatch, Attempt and Outcome boundaries.
    * `Transition.Duty` materializes and disposes obligations, including their
      Meter resolution.

  Host adapters remain outside this namespace. They may supply input, clocks,
  persistence or execution, but adapter callbacks never bypass Admission or
  mutate `State` directly.
  """
end
