# VCredentialPlugin — ephemeral certificate gap research plan

Status: rough research plan; not a production design  
Date: 2026-08-12

## 1. Objective

Investigate a small, purpose-built SPIRE Credential Composer plugin that can produce X.509 workload SVIDs suitable for the AD PKINIT path by addressing the two gaps identified in the comparison research:

1. Gate 1: the certificate needs a usable revocation pointer, principally a CRL Distribution Point (CDP).
2. Gate 2: the certificate needs durable strong mapping to the intended AD account, preferably the AD SID security extension rather than a re-key-fragile `altSecurityIdentities` mapping.

The research outcome should be an evidence-backed decision: continue with a maintained fork/plugin, pursue an issuer/platform feature instead, or stop.

This project must not be described as “passwordless” or production-ready merely because the certificate is short-lived. The private key remains credential material while live, and the CA/NTAuth trust decision remains forest-wide.

## 2. Starting point and verified constraints

Reference material:

- Local comparison research: gmsad vs. PKINIT (private notes, kept out of this repository)
- Upstream project: [spiffe/spire-credentialcomposer-cel](https://github.com/spiffe/spire-credentialcomposer-cel)
- SPIRE plugin SDK interface: [credentialcomposer.proto](https://github.com/spiffe/spire-plugin-sdk/blob/main/proto/spire/plugin/server/credentialcomposer/v1/credentialcomposer.proto)

The current upstream CEL project is explicitly experimental. Its published implementation supports JWT composition; the X.509 methods return `Unimplemented`. The SDK nevertheless exposes:

- `ComposeWorkloadX509SVID`
- `X509SVIDAttributes.extra_extensions`
- opaque extension values keyed by OID and criticality
- preservation of the SPIFFE URI SAN, which the plugin cannot replace

Important boundary: a composer changes certificate attributes. It does not issue keys, publish a CA to `NTAuthCertificates`, host or sign CRLs, maintain the AD mapping registry, or change KDC policy.

## 3. Working hypotheses

- The workload X.509 composer hook can add a CDP and the AD SID extension without violating the SPIFFE X.509-SVID shape.
- A typed Go implementation is safer than asking CEL to construct arbitrary DER. CEL may remain useful for JWT behavior, but binary X.509 extension construction should be code with strict validation and a narrow configuration surface.
- A SPIFFE-ID-to-AD-SID registry can make short-lived re-issuance stable without rewriting `altSecurityIdentities` for every certificate.
- The plugin can close the certificate-shape gap, but the end-to-end path still depends on CRL infrastructure, NTAuth approval, KDC behavior, AD replication/caching, and a tested recovery model.

## 4. Proposed research architecture

Start with a pinned fork of the upstream repository for SDK/plugin integration, but keep the X.509 implementation conceptually separate from the CEL evaluator.

Initial scope:

- Implement `ComposeWorkloadX509SVID` first.
- Copy the incoming attributes and mutate only approved fields.
- Preserve the SPIFFE URI SAN and existing valid attributes.
- Add only whitelisted, typed extensions:
  - CDP extension
  - AD security identifier extension (`szOID_NTDS_CA_SECURITY_EXT`)
- Fail closed when the workload has no approved mapping, the SPIFFE ID is outside an allowed namespace, the SID is malformed, or the CDP policy is missing.
- Leave server CA, server SVID, agent SVID, and JWT behavior unchanged until a separate use case requires them.
- Make extension replacement/deduplication deterministic; never silently emit duplicate security-critical OIDs.

Suggested configuration concepts:

- allowed SPIFFE-ID prefixes or selectors
- explicit SPIFFE ID → AD SID mapping source
- CDP URI(s), with environment-specific validation
- extension criticality policy
- issuer/trust-domain identity and configuration version
- audit-safe mapping and issuance decision logs that contain no private key material

Do not derive an AD SID from an untrusted SPIFFE path. The mapping must be authoritative, reviewable, and revocable.

## 5. Work phases

### Phase 0 — Freeze the baseline

- Pin the upstream commit and SPIRE plugin SDK version.
- Record the current X.509 hook behavior and the exact proto contract.
- Preserve Apache-2.0 notices and document the fork point.
- Capture the current comparison findings as the research baseline.
- Confirm the target SPIRE release before writing integration code.

### Phase 1 — Prove the extension encodings in isolation

Build pure Go helpers before wiring them into gRPC:

- Encode and decode CDP values as valid DER.
- Encode and decode the AD SID extension using a known-good ADCS certificate or authoritative Microsoft test fixture.
- Verify OIDs, criticality, nesting, byte order, and SID representation.
- Compare generated certificates with `openssl x509 -text`, `openssl asn1parse`, and Go `crypto/x509`.
- Add golden tests, malformed-input tests, duplicate-extension tests, and fuzz tests for the DER builders.

Do not infer the AD extension encoding from the OID alone. This phase must establish the exact bytes accepted by the target Windows/KDC versions.

### Phase 2 — Implement the composer plugin

- Add the X.509 workload RPC implementation.
- Add typed configuration and strict validation.
- Preserve all incoming attributes that are not intentionally changed.
- Add structured errors for missing mapping, invalid SID, invalid CDP, unsupported hook, and policy violation.
- Add unit tests using synthetic requests and certificate fixtures.
- Add CI for formatting, static analysis, dependency review, and reproducible builds.
- Keep arbitrary user-provided DER disabled by default; if a diagnostic escape hatch is needed, make it lab-only.

### Phase 3 — Run SPIRE integration in a Linux environment

Native macOS SPIRE installation is not a prerequisite. Use macOS for Go unit/DER tests and run the SPIRE server/plugin integration in a Linux container, VM, or CI runner unless a supported Darwin build is confirmed.

- Build the forked plugin.
- Register it as a SPIRE Credential Composer.
- Issue a workload X.509-SVID from a minimal test trust domain.
- Inspect the complete chain and leaf certificate.
- Verify the SPIFFE URI SAN is unchanged and the two intended extensions are present exactly once.
- Exercise renewal and concurrent issuance.
- Test malformed configuration and plugin restart behavior.

### Phase 4 — Validate the AD PKINIT gates in a disposable lab

Use a non-production AD/KDC lab with a test account and test CA:

- Gate 0: EKU and certificate profile behavior.
- Gate 1: chain trust, `NTAuthCertificates`, CDP reachability, CRL freshness, and KDC revocation behavior.
- Gate 2: SID-based strong mapping, including wrong-SID and missing-SID negatives.
- Obtain a TGT from the SVID key and a service ticket for the target SQL Server service.
- Confirm the SQL Server login/object mapping separately; a TGT/TGS is not proof that the database authorization is complete.
- Test short-lived issuance and repeated renewal without manual AD mapping changes.

Record exact Windows build, KDC patch level, CA configuration, SPIRE version, plugin commit, TTL, CRL publication timing, and observed KDC errors.

### Phase 5 — Test revocation, failure, and continuity

- Revoke a certificate and publish a new CRL.
- Measure the time until the KDC refuses the revoked credential.
- Test unreachable, stale, malformed, and unavailable CRLs.
- Test issuer outage, SPIRE outage, AD replication delay, and plugin restart.
- Confirm behavior at expiry: fail closed, with no fallback to UPN-only or stale mapping.
- Define emergency CA/NTAuth removal, mapping removal, and recovery procedures.
- Document what happens when the workload cannot obtain a fresh certificate.

A CDP in the certificate is not a CRL operating model. Identify who hosts, signs, publishes, monitors, and rotates the CRL before treating Gate 1 as closed.

### Phase 6 — Security, governance, and decision review

Produce:

- threat model and trust-boundary diagram
- SPIFFE-ID-to-AD-SID ownership and provisioning model
- NTAuth blast-radius analysis
- private-key-at-rest and host-compromise analysis
- plugin supply-chain, fork-maintenance, and CVE response plan
- continuity/recovery runbook
- governance/control checklist, including non-password credential approval
- comparison against the Teleport-native feature path

Decision gate: the research succeeds only if the evidence demonstrates certificate issuance, PKINIT acceptance, stable re-key mapping, revocation behavior, and an operable failure/recovery model. Otherwise classify the result as a useful prototype or feature request, not a deployable solution.

## 6. Validation matrix

| Area | Positive evidence | Required negative evidence |
|---|---|---|
| DER | CDP and AD SID extensions parse and match known-good fixtures | malformed SID/CDP, duplicate OIDs, wrong criticality |
| SPIFFE | URI SAN and chain remain valid; intended extensions survive renewal | attempted URI SAN mutation, unsupported config, plugin restart |
| PKINIT | TGT and target service ticket obtained | untrusted CA, missing EKU, missing CDP, missing/incorrect SID |
| Rotation | repeated short-lived renewals authenticate to the same AD account | no silent fallback to weak mapping; old cert behavior is understood |
| Revocation | revoked cert is rejected within documented bounds | stale/unreachable CRL produces a known safe result |
| Isolation | workload namespace and mapping policy prevent cross-account use | unknown SPIFFE ID cannot select an arbitrary privileged SID |
| Operations | outage, recovery, and emergency-revocation steps work | no undocumented manual repair is required |

## 7. Deliverables

- pinned research fork with a clearly named plugin binary
- extension-builder package with unit, golden, and fuzz tests
- X.509 composer implementation and sample SPIRE configuration
- lab deployment notes for Linux/SPIRE and Windows/AD
- certificate/DER inspection report
- PKINIT, renewal, and revocation test report
- threat model and operations/recovery runbook
- dependency/license/CVE inventory
- short decision record: continue, upstream, replace with platform feature, or stop

Keep private keys, production certificates, AD exports, and sensitive mappings out of the repository. Fixtures should be synthetic or sanitized.

## 8. Open decisions

1. What exact SPIRE release and SDK version will be supported?
2. What authoritative system owns the SPIFFE ID → AD SID registry?
3. Which component issues and publishes the CRL referenced by the CDP?
4. Does the target KDC accept the chosen SID extension encoding and CRL behavior at the required patch level?
5. Does the target SPIRE release preserve/merge `extra_extensions` as expected on renewal?
6. Are only workload SVIDs in scope, or are agent/server certificates also needed?
7. Is this a fork of the CEL repository with X.509 support, or a clean Go plugin that only reuses its integration pattern?
8. Who owns the fork indefinitely, including upstream tracking, security review, releases, and incident response?
9. What is the approved short-lived TTL, and how are KDC/AD replication and caching accounted for?
10. Which governance approvals are required before any lab is connected to enterprise AD?

## 9. Initial recommendation

Do not spend time installing SPIRE natively on macOS before the DER and plugin unit tests exist. First prove the certificate bytes and the SDK contract locally; then use Linux container/VM/CI plus a disposable Windows/KDC lab for the meaningful validation.

Treat the plugin fork as a 2–4 week research implementation. Treat the surrounding platform—SPIRE HA, CRL service, NTAuth publication, SID registry, AD/KDC lab, governance, and long-term maintenance—as a separate multi-quarter investment.
