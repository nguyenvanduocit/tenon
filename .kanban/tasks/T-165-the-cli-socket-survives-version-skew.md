# T-165: The CLI socket proves it survives version skew
> A protocol number alone protects nothing; named capability advertisement plus a two-way skew test is what protects — measured against Orca's remote-wire-compatibility discipline.
- **priority**: low
- **effort**: M

From `docs/research-intent-design-principles.md` (Orca section). Orca guards its wire with
~34 named capability strings (`<domain>.<feature>.vN`) advertised at handshake, an
in-file bump rule, and an e2e test running current and last-release builds against each
other in both skew directions — while honestly declaring the test covers terminal-stream
only. Tenon's `tenon-cli` ↔ app socket has versioned intent names but (to verify) no
equivalent skew evidence: an old CLI against a new app, and the reverse, after a contract
gains a `.v2`.

## Criteria
- [x] Verify what skew protection exists today for the control socket (wire version, error on mismatch, silent drift?)
- [x] Decide: capability/feature advertisement at handshake, or a documented reason the closed catalog + versioned names already suffice
- [x] If a gap: a two-way skew test (old client/new host, new client/old host) with its coverage stated, not implied

## Receipt — 2026-08-14

The socket speaks exact protocol v3. `CLIWireCodec` rejects a request before action
interpretation when its version differs, returning `unsupported_version` and naming the
version the host speaks; it does not guess or reinterpret an older envelope. The wire is a
closed five-action control plane, while domain contracts carry their own `.vN` names and are
schema-discovered through `intent.describe`, so a capability-advertisement handshake would
add a second negotiation surface without protecting an open set.

`CLIProtocolTests/testVersionSkewIsRejectedInBothDirections` covers an older v2 client against
the current v3 host and a current v3 client against an older v2 host fixture. The CLI PRD
decision log and Gherkin acceptance scenario record the boundary: any future open-ended
control surface needs named advertisement, and any protocol-major change needs both skew
directions. The focused protocol/socket/catalog/host/plugin run passed **78 / 0**.
