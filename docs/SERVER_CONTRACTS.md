# Application contracts and permission diagnostics

Spectre 0.4 keeps application callbacks as ordinary Elixir functions. Two optional
callbacks help detect mistakes in growing workflows. Existing Servers need no
changes: both callbacks default to `nil` (checks disabled).

```elixir
defmodule MyApp.ResearchServer do
  use Spectre.Server

  @impl true
  def assigns_schema do
    %{contacts: {:list, :string}, page_title: {:optional, :string}}
  end

  @impl true
  def continuation_contracts do
    %{
      extracted: {:one_of, [
        {:tuple, [{:enum, [:ok]}, {:map, %{emails: {:list, :string}}}]},
        {:tuple, [{:enum, [:error]}, :any]}
      ]}
    }
  end

  @impl true
  def init(_opts, ctx), do: {:ok, assign(ctx, :contacts, [])}

  # Commands using on_result: :extracted must produce one of the declared shapes.
  # Implement the corresponding ordinary handle_result/3 clauses as usual.
end
```

`assigns_schema/0` describes application `ctx.assigns`, never GAM state. Required
fields must be initialized by `init/2`. Extra fields are allowed; optional means a
field can be absent, not that an arbitrary value or `nil` is accepted. Use
`{:one_of, [:string, {:enum, [nil]}]}` for a nullable string.

Types are `:any`, `:string`, `:integer`, `:number`, `:boolean`, `:atom`, `:map`,
`:list`, `{:enum, atoms_or_numbers}`, `{:list, type}`, `{:map, fields}`,
`{:tuple, types}`, `{:one_of, types}`, and `{:optional, type}` for optional fields.
Typed maps accept plain maps, not structs. No coercion or generated atoms occur.

Returned assigns are checked before callback commands are acquired and before
checkpointing. This applies to conversational and native OTP callbacks;
`code_change/3` is checked too. Restored assigns are checked **after** any explicit
checkpoint migration and **before** application initialization or command recovery.
Retained explicit continuations are also checked after migration and during
`code_change/3`, before recovery can run. New checkpoints preserve whether a tag
was explicitly requested, so normalized tool defaults remain implicit. Older
snapshots are checked where their original command or reply-wait metadata proves
an explicit tag; they cannot supply provenance they never recorded.

A changed compiled Server already changes the checkpoint definition fingerprint;
use the existing explicit migration mechanism when changing persisted schemas.

When continuation contracts are enabled, every explicit `on_result` tag must be
in the declared map. An empty map disallows explicit continuation tags; `nil`
disables this check. Result shape validation runs before `handle_result/3` for
declared tags, including matching implicit callbacks. This is a runtime contract,
not a proof that arbitrary Elixir pattern matching is exhaustive. Use `:any` for
a tag whose result shape intentionally remains open.

A bad tag is rejected before its command executes. An invalid result is consumed
and quarantined as a structured callback error; Spectre does not rerun the effect
to repair an application contract. Diagnostics include the contract, tag, shape,
field path and available interaction/command IDs, never rejected values. Existing
callback error handling and bounded dead letters remain the recovery interface.
A validation failure does not undo an effect already recorded by GAM.

## Root and Skill permissions

Root operation configuration and Skill mount restrictions form an intersection.
Installing a package grants no authority. A root can intentionally enable fewer
operations than a reusable Skill declares.

```elixir
Spectre.Server.PermissionDiagnostics.report(MyApp.Agent, root_operations)
# [%{code: :mount_operation_not_enabled, mount: :research,
#    operation: :send_email, severity: :warning}]
```

The report checks concrete `governed:` mount references, or bound operation
references when `governed:` is absent. It does not inspect arbitrary callback code
or infer resource-level authority. Default startup remains permissive for a
narrower root; execution still enforces GAM and mount restrictions.

For deployments that expect every mount operation to be configured, pass
`strict_permissions: true` to `Spectre.Server.start_link/1` alongside the managed
`gam: [operations: root_operations, ...]` options. A concrete mismatch then fails
startup before managed resources are started. This option does not widen authority
and does not change an externally supplied GAM adapter's policy.

Enum schemas accept atom and numeric literals. String values are validated with
`:string`; they are not echoed into contract diagnostics.
