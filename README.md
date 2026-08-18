# spire-credentialcomposer-adpkinit

A research-stage [SPIRE](https://github.com/spiffe/spire) CredentialComposer server
plugin that shaped workload X.509-SVIDs for Active Directory PKINIT.

> **Status: parked — 2026-08-17.** The lab answered the question this project existed
> to answer, and the answer rules out the plugin approach. Nothing here is finished,
> and nothing here should be deployed. The repository is kept for the lab, the
> finding, and the encoding work.

## Why it is parked

The open question was whether AD's `NTAuthCertificates` store accepts a **root** CA,
or requires the **direct issuing** CA. It matters because in a SPIRE chain the direct
issuer is SPIRE's intermediate — the certificate SPIRE rotates by design. If the root
sufficed, it could be published once and SPIRE could rotate freely underneath it.

A seven-row lab matrix against Windows Server 2025, with both controls behaving,
settled it:

**The direct issuing CA must be published. A root is neither necessary nor
sufficient** — a leaf authenticates if and only if its immediate issuer is in
`NTAuthCertificates`.

The decisive row is a rotated issuer under an already-published root — exactly what
SPIRE CA rotation produces. It fails. So every rotation costs an AD write plus a
replication wait on the critical path, at a privilege level (Enterprise
Admin-equivalent, on the forest configuration partition) that does not belong in a
certificate rotation loop.

That is a property of AD, not of certificate shape, so **no composer change can
affect it.** Of the three constraints that bind this problem, exactly one — the shape
of the certificate — is inside a CredentialComposer's reach. The other two, NTAuth
membership at a rotating issuer and revocation infrastructure, are outside it. A
plugin that closes one of three is not a solution.

Full evidence and reasoning: `docs/findings/2026-08-17-ntauth-requires-direct-issuer.md`.

Work continues in a successor project — a standalone credential broker that exchanges
a SPIFFE SVID for a certificate AD will accept, sitting beside SPIRE rather than
inside it. In PKI terms it is a registration authority, which is the role these three
constraints actually call for.

## What this repo still holds

- **`lab/`** — the phase-4 rig: a one-VM Windows Server 2025 AD lab under KVM, an
  openssl two-level CA chain, and `03-run-row.sh`, which runs one row of the NTAuth
  matrix and writes a self-contained transcript. Reproducible from scratch.
- **`docs/findings/`** — the two findings that changed the plan, including the
  seven-row matrix above.
- **`internal/encoding`** — the CDP extension builder (Gate 1), golden-tested
  byte-for-byte against the extension `crypto/x509` emits in a real certificate, plus
  the MS-DTYP binary SID codec. Both carry over to the successor.
- **`internal/mapping`** — the snapshot contract: strict schema, fail-closed lookup,
  and a freshness bound reported separately from the policy applied to it.

`ComposeWorkloadX509SVID` was never implemented. Gate 2 — the AD SID security
extension (`szOID_NTDS_CA_SECURITY_EXT`) — stayed blocked on acquiring a real ADCS
fixture, because its encoding must be pinned to observed bytes rather than inferred
from documentation. `docs/FIXTURES.md` records what that fixture must answer.

## Design intent, for the record

The plugin would have added a CRL Distribution Point extension and the AD SID security
extension, with the SID sourced from an authoritative SPIFFE-ID→SID mapping snapshot —
**never derived from the SPIFFE ID itself**, since a certificate carrying a SID
authenticates as that account. Everything failed closed: unknown SPIFFE ID, missing
mapping, malformed SID, or missing CDP policy refuses composition.

This was never a "passwordless" product and never production-ready. The SVID private
key is credential material while live; CRL hosting, `NTAuthCertificates` publication,
mapping governance, and KDC policy all sit outside a composer plugin's boundary — which
is, in the end, the finding above restated.

See `docs/RESEARCH-PLAN.md` for the phased plan and validation matrix, `docs/CONTEXT.md`
for the resume point at parking, and `CLAUDE.md` for working rules and decisions.

Related prior art: [spiffe/spire-credentialcomposer-cel](https://github.com/spiffe/spire-credentialcomposer-cel)
(JWT-only; X.509 hooks unimplemented). Not affiliated with the SPIFFE project.

## Build & test

```
go build ./...
go vet ./...
go test ./...
```

## License

Apache-2.0.
