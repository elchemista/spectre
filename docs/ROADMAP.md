# Roadmap

Spectre is meant to sit in a small family of focused packages.

Works well today:

- `spectre_kinetic` integrates cleanly as the Action Language and tool-planning
  layer. Spectre delegates AL extraction and planning to Kinetic, receives
  staged action effects, then applies policies and execution boundaries.

Future integration work:

- `spectre_lens` should become easier to plug into action modules and agent
  tools for browsing the web.
- `spectre_mnemonic` should become a smoother first-class memory adapter for
  recall, turn persistence, and long-running conversation context.
- `spectre_directive` should integrate above Spectre for mission-level
  orchestration: multi-step goals, delegated agents, and longer-running
  workflows.

The direction is not to make Spectre a giant framework. The direction is to keep
each package responsible for one layer, with clean Elixir boundaries between
them.
