# Finding — CA chaining and revocation plumbing

Recorded: 2026-08-12T23:47:09Z
Status: research finding; changes open decision 3 and adds a new open decision
Affects: Gate 1, phase 4 lab scope, gate ordering

Origin: Claude Code session `7f3832b2-c493-4c5e-8c83-d71a9fc32189`, 2026-08-12.
Local Claude Code sessions have no shareable web URL — the transcript is a local file,
not a hosted page. To reopen it on this machine:

```
claude --resume 7f3832b2-c493-4c5e-8c83-d71a9fc32189
# transcript: ~/.claude/projects/<this-repo-path-slug>/7f3832b2-c493-4c5e-8c83-d71a9fc32189.jsonl
```

The two findings below came from asking a scoping question — "do I need a Windows CA
estate to do this?" — and are recorded because both change the plan rather than merely
answering it.

---

## Finding 0 — ADCS is not in the issuance path (the question that started this)

SPIRE is the CA. Workload certificates are minted by SPIRE's CA and shaped by this
composer. ADCS has no role in producing them, in the lab or in any deployment.

ADCS appears in this project in exactly one place: as a **fixture source** for the AD
SID extension's bytes (`docs/FIXTURES.md`). That is a read-once reference, not
infrastructure to operate. A Windows Server VM is still needed — for AD DS and the KDC,
which are the artifacts under test and have no Linux stand-in — but "a whole CA system"
is not.

Practical consequence: the phase-4 lab is **one Windows Server evaluation VM**, running
DC + KDC, with the ADCS role added only long enough to issue one fixture certificate.
Publishing a CA to `NTAuthCertificates` uses `certutil`, a base Windows component; the
NTAuth store is an AD object and accepts non-Microsoft CAs. (Exact invocation to be
confirmed in the lab.)

---

## Finding 1 — Gate 1's prior question is what *signs* the CRL, not who hosts it

Open decision 3 is currently phrased as "which component issues and publishes the CRL
referenced by the CDP?". That phrasing skips a question that has to be answered first,
and the answer to it is unfavourable.

**SPIRE has no CRL or OCSP surface for X.509-SVIDs, by design.** Revocation in SPIFFE
is short TTLs plus deletion of the registration entry; the documentation is explicit
that private keys and certificates are "short lived, rotated frequently and
automatically" in place of a revocation protocol. This is a design stance, not a gap
awaiting a feature.

A CDP in a leaf certificate must point at a CRL signed by **that leaf's issuer**. For a
SPIRE-issued SVID, the issuer is SPIRE's server CA, whose key SPIRE neither exposes for
CRL signing nor uses to produce a CRL.

Consequences that are easy to get wrong:

- **Running a CA on Linux does not solve this.** Vault, step-ca, EJBCA, Dogtag or plain
  OpenSSL would all be signing with the wrong key. The OS was never the constraint.
- **Chaining does not solve it either.** With an upstream root you control (see finding
  2) you can issue a CRL covering what the root signs — SPIRE's intermediate — but not
  the leaves that intermediate issues.
- **Windows checks revocation at every level of the chain**, so covering only the
  intermediate is not sufficient.

**Gate 1 as specified may not be closeable by a composer plugin at all.** That is a
legitimate research finding and belongs in the decision record, not a failure to route
around. The plugin can place a syntactically correct CDP in a certificate — that part is
built and golden-tested — but a CDP is not a CRL operating model, and the operating
model has no available signer.

### Options, least to most invasive

1. **Bypass revocation checking in the lab** to isolate Gate 2. Cheapest path to the
   answer that actually decides the project. Must be recorded as "Gate 1 deliberately
   bypassed, not closed" so the bypass is never mistaken for a pass.
2. **Upstream feature request to SPIRE** for CRL issuance. Expands the existing plan to
   engage `spire-credentialcomposer-cel` issue #3 into a broader upstream conversation.
3. **Take the AD-facing certificate out of SPIRE's issuance path** entirely, so a CA
   that can sign CRLs issues it. At that point this is no longer a composer plugin, and
   the project's premise has changed.

### Recommendation

Reorder the gates: **test Gate 2 first**, with KDC revocation checking relaxed. Gate 2
is the novel part, the part this plugin uniquely addresses, and the part where a fixture
answers a real unknown. Gate 1 is a known, unsolved infrastructure problem that is
mostly not this project's to solve.

---

## Finding 2 — Chaining SPIRE under an internal root collides with NTAuth rotation

Chaining an internal root ("Scoot CA") above SPIRE is directly supported: SPIRE's
`UpstreamAuthority` plugins (`disk`, `vault`, `cert_manager`, `aws_pca`, `gcp_cas`,
nested `spire`) make SPIRE's server CA an intermediate signed by the upstream. The chain
becomes **internal root → SPIRE server CA → workload SVID**.

The complication is specific to AD and would not have shown up in a prior Teleport
database-access setup, which needs a trust chain both ends agree on but neither NTAuth
publication nor the SID extension.

**NTAuth requires the *issuing* CA — the certificate that directly signed the leaf — not
the root.** Microsoft's guidance for third-party CAs states the logon certificate must
be issued from a CA that is in the NTAuth store; the root matters for chain trust, but
NTAuth membership is checked against the issuer.

In a SPIRE chain, that issuing CA is SPIRE's intermediate, **which SPIRE rotates by
design**. On the naive reading, every SPIRE CA rotation then requires republishing to
NTAuth and waiting for AD replication before newly issued SVIDs can authenticate — an AD
write coupled to SPIRE's rotation schedule. That is precisely the coupling the mapping
architecture was designed to avoid for the SID registry, reappearing one layer down in
the CA plumbing.

### The experiment this implies

**Does a root in NTAuth suffice, or must the direct issuer be present?** This is
probably the single highest-value experiment in the phase-4 lab, because it decides
whether the whole approach is operationally viable:

- **If root-in-NTAuth works:** publish the internal root once, let SPIRE rotate freely.
  Chaining becomes very attractive. The cost is blast radius — everything that root ever
  signs can then attempt AD authentication, which is far wider than a narrow SPIRE
  intermediate. A trade, not a free win, and it sharpens the NTAuth blast-radius item
  already in phase 6.
- **If the direct issuer is required:** the approach has an operational problem that no
  amount of plugin code fixes, and the recovery model has to be designed around SPIRE CA
  rotation before anything else proceeds.

This must be answered from observed KDC behaviour on the target patch level, not from
documentation — the same standard `docs/FIXTURES.md` applies to the SID extension.

---

## Changes this makes to the plan

- **Open decision 3 is restated.** Not "who hosts and publishes the CRL" but: *what can
  sign a CRL covering SPIRE-issued leaves, given SPIRE does not?* Hosting is downstream
  of that and currently moot.
- **New open decision (11):** does NTAuth accept a root, or must the direct issuing CA
  be published? If the latter, what is the republication procedure on SPIRE CA rotation,
  and what is the issuance blackout during AD replication?
- **Gate ordering changes.** Gate 2 is tested before Gate 1, with revocation checking
  relaxed and that fact recorded explicitly.
- **Phase 4 lab scope shrinks** to one Windows Server VM (DC + KDC, ADCS only as a
  fixture source), which is a smaller commitment than the plan implied.
- **No change to the plugin's code or configuration surface.** `cdp_uris` is
  configuration; the plugin does not care who hosts or signs the CRL. The Windows
  coupling lives entirely in the validation lab. The portability goal is already met.

## To verify in the lab

- [ ] Does NTAuth accept a root CA, or only the direct issuing CA?
- [ ] What exactly does the KDC do with a leaf whose CDP is unreachable, versus a leaf
      with no CDP at all? These are different failures and may have different policy
      controls.
- [ ] Which KDC-side revocation controls exist at the target patch level, and what is
      the precise configuration used for the Gate 2 bypass?
- [ ] Confirm `certutil` NTAuth publication works without the ADCS role installed.
- [ ] Does SPIRE CA rotation invalidate NTAuth publication in practice, and how long is
      the resulting issuance blackout?

## Sources

- [Working with SVIDs — SPIFFE](https://spiffe.io/docs/latest/deploying/svids/)
- [SPIFFE concepts](https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/)
- [spiffe/spire#1934 — Forced Rotation and Revocation](https://github.com/spiffe/spire/issues/1934)
- [Enabling smart card logon with third-party certification authorities — Microsoft Learn](https://learn.microsoft.com/en-us/troubleshoot/windows-server/certificates-and-public-key-infrastructure-pki/enabling-smart-card-logon-third-party-certification-authorities)
- [Import third-party CA to the Enterprise NTAuth store — Microsoft Learn](https://learn.microsoft.com/en-US/troubleshoot/windows-server/certificates-and-public-key-infrastructure-pki/import-third-party-ca-to-enterprise-ntauth-store)
- [Certificate revocation check for PKINIT in KDC — MIT Kerberos list](https://mailman.mit.edu/pipermail/kerberos/2017-August/021789.html)
