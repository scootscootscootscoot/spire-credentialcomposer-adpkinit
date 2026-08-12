# spire-credentialcomposer-adpkinit

**Research-stage** [SPIRE](https://github.com/spiffe/spire) CredentialComposer server
plugin that shapes workload X.509-SVIDs for Active Directory PKINIT:

- adds a CRL Distribution Point extension (revocation pointer), and
- adds the AD SID security extension (`szOID_NTDS_CA_SECURITY_EXT`) for KDC strong
  certificate mapping, sourced from an authoritative SPIFFE-ID→SID mapping snapshot —
  never derived from the SPIFFE ID itself.

Everything fails closed: unknown SPIFFE ID, missing mapping, malformed SID, or missing
CDP policy refuses composition.

**Status:** research, phase 1. `ComposeWorkloadX509SVID` is **not implemented**; do not
deploy — an unimplemented hook means SPIRE issues the SVID unshaped.

What exists and is tested:

- `internal/mapping` — the snapshot contract: strict schema, fail-closed lookup, and a
  freshness bound reported separately from the policy applied to it.
- `internal/encoding` — the CDP extension builder (Gate 1), golden-tested byte-for-byte
  against the extension `crypto/x509` emits in a real certificate, and the MS-DTYP
  binary SID codec.

What blocks Gate 2: the AD SID extension encoding must be pinned to a known-good ADCS
fixture rather than inferred from documentation. See `docs/FIXTURES.md` for what the
fixture must answer and what would end that blocked state.

See `docs/RESEARCH-PLAN.md` for the phased plan and validation matrix, and `CLAUDE.md`
for working rules and decisions.

This is not a "passwordless" product and not production-ready. The SVID private key is
credential material while live; CRL hosting, `NTAuthCertificates` publication, mapping
governance, and KDC policy are all outside a composer plugin's boundary.

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
