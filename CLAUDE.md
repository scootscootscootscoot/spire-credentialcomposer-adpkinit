# CLAUDE.md — spire-credentialcomposer-adpkinit

## What this is

A SPIRE **CredentialComposer** server plugin (research stage) that shapes workload
X.509-SVIDs so they can pass Active Directory PKINIT, by closing two certificate-shape gaps:

1. **Gate 1 — revocation pointer:** add a CRL Distribution Point (CDP) extension.
2. **Gate 2 — strong mapping:** add the AD SID security extension
   (`szOID_NTDS_CA_SECURITY_EXT`, OID `1.3.6.1.4.1.311.25.2`) so the KDC maps the cert
   to the intended AD account without re-key-fragile `altSecurityIdentities` entries.

Full research plan with phases, validation matrix, and open decisions:
`docs/RESEARCH-PLAN.md`. Read it before proposing scope changes.

This is a **spare-time personal project**, developed in parallel with (not as part of) the
owner's day job. Related-but-separate: the home-lab SPIRE fleet rollout at
`~/Desktop/spire/PLAN.md` — that fleet is the phase-3 integration target.

## Hard rules (do not relax without explicit owner decision)

**Security invariants:**
- Fail closed. No mapping entry, malformed SID, SPIFFE ID outside allowed namespace,
  or missing CDP policy ⇒ refuse composition with a structured error. Never issue a
  "partially shaped" cert.
- Never derive an AD SID from the SPIFFE ID path or any workload-controlled input.
  The mapping is data from an authoritative source, full stop.
- Never mutate the SPIFFE URI SAN or drop incoming attributes not intentionally changed.
- Extension handling is deterministic: never emit duplicate OIDs; replacement/dedup
  rules are explicit and tested.
- No arbitrary user-supplied DER pass-through in default builds.
- In phase 1, do **not** infer the AD SID extension encoding from documentation alone —
  fixtures must come from a real ADCS-issued cert or authoritative Microsoft test vector,
  and golden tests pin the exact bytes.

**Repo hygiene (pre-public checklist lives here):**
- Repo is **private until the owner completes an employment-IP review**. Do not make it
  public, and do not push content anywhere else.
- No work artifacts ever: no internal doc names/paths/links, no employer name, no real
  AD exports, SIDs from real forests, production certs, or private keys. Fixtures are
  synthetic or sanitized. (`docs/RESEARCH-PLAN.md` was already scrubbed of one internal
  reference — keep it that way.)
- Commits: sign-off habit (`git commit -s`, DCO style) — required anyway for future
  upstream SPIFFE contributions.

## Decisions log

| Date | Decision |
|---|---|
| 2026-08-12 | Clean plugin in own repo (not a fork of `spiffe/spire-credentialcomposer-cel`). Reuse only the standard plugin-SDK serve/config pattern. Engage upstream issue #3 ("x509 support") with findings once we have something real to show. |
| 2026-08-12 | Mapping design: plugin consumes a **local mapping snapshot** (versioned, schema-validated, freshness-checked); snapshot *production* is a separate pluggable concern — GitOps pipeline first, AD-attribute sync controller later. See "Mapping architecture". |
| 2026-08-12 | Phase 4–5 lab: Windows Server eval VM under KVM **on this machine** (`/dev/kvm` verified). Not built yet — do not build before phase 2 exits. |
| 2026-08-12 | Private GitHub repo until IP review. |
| 2026-08-12 | Pins: SPIRE v1.15.2, spire-plugin-sdk v1.15.2, Go 1.26.5. Matches latest SPIRE release and the home-fleet plan. |

## Mapping architecture (the "massive org" answer)

The SPIFFE-ID→SID registry question is split into two contracts so the plugin never
couples cert issuance to a remote system's availability:

1. **Consumption contract (this repo, `internal/mapping`):** the plugin reads a local
   snapshot file — versioned, schema-validated, with a `generated_at` freshness bound.
   Miss ⇒ fail closed. Stale-beyond-bound ⇒ policy decision (default: keep serving last
   known good + surface staleness loudly; mappings change rarely, issuance must not
   flap with the registry).
2. **Production contract (separate component, later):** something authoritative writes
   the snapshot. v1: a GitOps pipeline (code-owner-reviewed mapping repo, CI validates
   SID format + namespace policy, deploys the artifact). v2 direction: a sync controller
   that reads the mapping from AD itself (e.g., a custom attribute on the target account,
   so the AD object's ACL is the authorization model and AD's audit trail is the review
   trail). Either way the plugin code does not change.

## Layout

```
cmd/spire-credentialcomposer-adpkinit/  plugin binary (pluginmain.Serve wiring)
internal/plugin/                        Configure + composer hooks; only
                                        ComposeWorkloadX509SVID will be implemented
internal/mapping/                       snapshot contract + SID validation
internal/encoding/                      phase-1 DER builders (CDP, AD SID ext) + golden/fuzz tests
docs/RESEARCH-PLAN.md                   the governing research plan
```

## Dev environment (this machine, labhost)

- Go 1.26.5 at `~/.local/go` (symlinked into `~/.local/bin`, already on PATH).
- **No docker/podman installed.** Phase 3 SPIRE integration: use the home fleet's SPIRE
  server (see `~/Desktop/spire/PLAN.md`) or install a container runtime first.
- KVM available for the phase-4 Windows lab; 20 cores / 15G RAM.
- GitHub: `gh` authed as `scootscootscootscoot` (SSH).

## Verify

```
go build ./...
go vet ./...
go test ./...
```

All three must pass before any commit. DER builders (phase 1) additionally require
golden tests against real fixtures and fuzz tests before they may be wired into the
plugin.

## Upstream pointers

- Interface: `spire-plugin-sdk/proto/spire/plugin/server/credentialcomposer/v1/credentialcomposer.proto`
  — note `X509SVIDAttributes.extra_extensions` (OID + criticality + opaque DER value),
  and that the SPIFFE URI SAN cannot be replaced by a composer.
- Prior art: `spiffe/spire-credentialcomposer-cel` (JWT-only, X.509 hooks Unimplemented;
  open issue #3 asks for x509 support). Apache-2.0. No code copied from it as of the
  decisions above — if any ever is, carry attribution in NOTICE.
- A composer changes certificate attributes only. It does not issue keys, publish to
  `NTAuthCertificates`, sign/host CRLs, own the mapping registry, or change KDC policy.
