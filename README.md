# spire-credentialcomposer-adpkinit

**Research-stage** [SPIRE](https://github.com/spiffe/spire) CredentialComposer server
plugin that shapes workload X.509-SVIDs for Active Directory PKINIT:

- adds a CRL Distribution Point extension (revocation pointer), and
- adds the AD SID security extension (`szOID_NTDS_CA_SECURITY_EXT`) for KDC strong
  certificate mapping, sourced from an authoritative SPIFFE-ID→SID mapping snapshot —
  never derived from the SPIFFE ID itself.

Everything fails closed: unknown SPIFFE ID, missing mapping, malformed SID, or missing
CDP policy refuses composition.

**Status:** scaffold only. `ComposeWorkloadX509SVID` is not implemented yet; do not
deploy. See `docs/RESEARCH-PLAN.md` for the phased plan and validation matrix, and
`CLAUDE.md` for working rules and decisions.

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
