# ADR 0003: Steering replaces a stream attempt

Status: accepted

## Context

Steering can either mutate a provider stream in place or start a replacement
attempt. In-place mutation would require the consumer to update its expected
epoch while it is enumerating and would weaken the simple invariant that one
Enumerable observes exactly one fenced attempt.

## Decision

The first steering slice is restart-based replacement.

`Spectre.Inference.Stream.steer/3` sends a revision-fenced command to the
owning Instance. The Instance:

1. verifies the bearer token and complete stream ownership;
2. commits the command as `:pending` and increments the control generation;
3. reserves capacity for a successor;
4. builds and commits a successor Invocation with a new dispatch and epoch;
5. commits the command as `:applied` and starts the successor session;
6. tells the old session to terminate as `:superseded`.

The call returns the successor `%Spectre.Inference.Stream{}`. The original
Enumerable never follows an `:epoch_advanced` control event and never yields
successor deltas.

Provider-native steering is reserved for a future separately negotiated
capability. It cannot be substituted silently for these semantics.

## Races and recovery

- If the old terminal wins before the steering command is accepted, steering
  returns a terminal/stale error and no successor starts.
- Once the successor commit wins, late events from the old generation,
  dispatch, control revision or epoch are rejected.
- Cancellation is idempotent. A committed cancel prevents recovery from
  resurrecting the old attempt; uncertain remote cancellation remains
  `:ambiguous`.
- If the Instance restarts after committing a pending steering command but
  before committing the successor, recovery rejects the command with
  `:instance_restarted_before_control_apply` and terminalizes the uncertain
  attempt. No canonical command remains pending forever.
- A recovered provider resume is a new epoch even though it is not a user
  steering command.

## Consequences

Ordering is local to one handle and one epoch. Applications that want a
continuous UI transcript must join attempts explicitly using their own
presentation model; the core will not concatenate them invisibly.
