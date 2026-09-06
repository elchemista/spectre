# Security policy

Spectre 0.4 is a governed-act kernel, not a sandbox for arbitrary host code.
It enforces authority and causal accounting on the declared, mediated paths.
The application still authenticates real identities, protects credentials,
establishes Genesis and supplies trustworthy observations.

Read [Governed surface and trust assumptions](GOVERNED_SURFACE.md) before making
a deployment security claim. The 0.4.0 checkout is unreleased and not yet declared
stable. Historical 0.3 APIs and security mechanisms must not be assumed to exist
in the new runtime.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub Security Advisories for
`elchemista/spectre`. Include:

- the affected version or commit and Elixir/OTP versions;
- a minimal reproduction and the expected versus observed boundary;
- the HostProfile, adapter types and attacker access required;
- whether the issue involves input, provider results, ledger corruption,
  replay, authority amplification, information disclosure or Duty disposal;
- any known mitigation.

Use synthetic identities and payloads. Do not include credentials, production
exports, personal data or real conversations.

## Trust boundaries

Mind and routing output is untrusted proposal data, not permission. Ingress
authenticates identities and binds observed Evidence; the kernel recognizes
authority separately. Prompt injection must not gain an execution credential
simply by changing a proposal.

Broker and executor integrations are privileged host code. Scope their
capabilities to the exact committed Act and Attempt. Never expose reusable
credentials through Candidates, Evidence, callbacks into a Mind or logs.
A sealed runtime value is not isolation against its own host process or node
administrator. Internal Elixir functions remain callable regardless of
`@doc false`.

The external world and the ledger are not one atomic transaction. Treat missing
or conflicting receipts as uncertainty, not authorization to retry. Preserve
Duty and Meter containment until an authorized, evidenced resolution.

## Storage, clocks and evidence

Store reads are validated, but an internally consistent rewritten history is
not detected by a hash chain alone. Spectre does not provide ledger signatures,
external witnessing or proof that an export is the latest complete history.
Protect ledger writers, exports, backups and independently trusted anchors.

Host time is trusted. Nondecreasing ledger timestamps do not prove correct
wall-clock time; the runtime clamp can mask a backward clock. Monitor clock
health independently.

Observed Evidence is only as reliable as its issuer and acquisition path.
Authenticate receipts, preserve causal references and source labels, and do
not promote model output into observed fact without the required host evidence.

Keep confidential content in an appropriately protected payload store rather
than the append-only ledger. Erasure metadata does not delete provider copies,
backups or logs, and hashes/references can still reveal sensitive information.

## Validation limits

Tests, offline audit, Credo, Dialyzer and Doctor address different properties.
None proves physical isolation, truthful Evidence or absence of alternate
effect paths. Coverage and performance qualification remain open release gates.
Report a violated supported invariant even if the static checks pass.
