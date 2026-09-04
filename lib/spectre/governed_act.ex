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
          |-- Index                 typed access to folded records
          |-- DispatchState         live/terminal world-boundary queries
          |-- MeterState            conserved-balance transitions
          `-- View                  read-only facts for kernel and host

  `Spectre.Domain.Projection` is the live replay driver. `Spectre.Audit` is an
  independent export driver; both use the same pure fold so the semantic rules
  cannot drift. `Spectre.Kernel` evaluates a Candidate from immutable views,
  while `Spectre.Domain.Sequencer` alone orders and appends the resulting batch.

  Small shared invariants sit beside the fold rather than inside either
  driver. `Class` is the closed metadata table for runtime-reserved classes;
  `Emergency` fixes the narrow exceptional-Mandate constraints;
  `Execution` owns their completion boundary without resolving host routes;
  `Materialization` derives the canonical event suffix of an intrinsic Act for
  both the commit path and batch validation;
  `Admission.Binding` is the single Decision-to-Act field correspondence; and
  `Spectre.Attempt.Binding` fixes the identity of the world-side Attempt.

  ## Transition families

    * `Transition.Foundation` establishes Genesis and revisable host facts.
    * `Transition.Authority` replays Mandate issue, restriction and revocation.
    * `Transition.Scope` binds authenticated contexts to durable Scopes.
    * `Transition.Information` handles Evidence, presentation, disclosure and
      erasure lineage.
    * `Transition.Admission` independently revalidates Decision and Act records;
      its `Decision`, `Act` and `Presentation` proof modules keep each binding
      explicit.
    * `Transition.Execution` covers dispatch, Attempt and Outcome boundaries.
    * `Transition.Outcome` shares Outcome history and attestation rules with
      live observation planning.
    * `Transition.Duty` routes obligation events; `Opening`, `Disposal` and
      `Meter` prove each causal phase independently.

  Host adapters remain outside this namespace. They may supply input, clocks,
  persistence or execution, but adapter callbacks never bypass Admission or
  mutate `State` directly.
  """
end
