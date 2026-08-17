# Finding — `NTAuthCertificates` requires the direct issuing CA

Recorded: 2026-08-17
Status: **open decision 11 answered.** Changes the phase-4 exit criteria and the
operational model for SPIRE CA rotation.
Affects: open decision 11, open decision 9 (TTL), phase 5 (continuity), the decision
record's viability argument

Evidence: `~/vms/lab-evidence/row-{A..G}-*.txt` (full transcripts, outside the repo —
they contain lab hostnames and SIDs, and per `CLAUDE.md` lab material stays out of git).
Rig: `lab/03-run-row.sh`, one row per invocation.

---

## The question

> Does `NTAuthCertificates` accept a **root** CA, or must the **direct issuing** CA be
> published?

It matters because in the real design the direct issuer is SPIRE's intermediate — the
certificate SPIRE rotates *by design*. If publishing the root sufficed, the root could
be published once and SPIRE could rotate freely underneath it.

## The answer

**The direct issuing CA must be published. A root CA in `NTAuthCertificates` is not
sufficient — it is neither necessary nor sufficient.**

A row authenticates if and only if the leaf's **immediate issuer** is in
`NTAuthCertificates`. Nothing else about the chain changes the outcome.

## The matrix

`R` = root, `I1`/`I2` = two intermediates under `R`. `leaf-i1` is issued by `I1`,
`leaf-i2` by `I2`. `leaf-i2` stands in for a leaf issued after a SPIRE CA rotation.

| Row | `NTAuthCertificates` | Leaf | Result | KDC result code |
|---|---|---|---|---|
| A | `{I1}` | leaf-i1 | **PASS** | `0x0` |
| B | `{R}` | leaf-i1 | FAIL | `0x3E` |
| C | `{I2}` | leaf-i1 | FAIL | `0x3E` |
| D | `{R, I1}` | leaf-i1 | **PASS** | `0x0` |
| E | `{R}` | leaf-i2 | FAIL | `0x3E` |
| F | `{I1}` | leaf-i2 | FAIL | `0x3E` |
| G | `{I2}` | leaf-i2 | **PASS** | `0x0` |

`0x0` = success, with the test account's real SID in the 4768 audit record.
`0x3E` = `KDC_ERR_CLIENT_NOT_TRUSTED`, with a null SID (`S-1-0-0`).

How the rows discharge their jobs:

- **A vs B** is the single-variable comparison that answers the question. Same leaf,
  same mapping, same relaxed revocation, same everything — only NTAuth membership
  changes, `{I1}` → `{R}`. Pass becomes fail. **The root alone does not work.**
- **D** rules out interference: with `{R, I1}` it still passes, so the root's presence
  neither helps nor harms. `I1` is doing the work in both A and D.
- **C** is the negative control. It must fail or the rig proves nothing.
- **E** is the operationally decisive row (see below). It fails.
- **F** confirms the requirement is specifically the *direct* issuer, not "any CA from
  the same lab" — `{I1}` does not rescue a leaf issued by `I2`.
- **G** closes an attribution gap that the original six rows had (see "Row G" below).

## Row E is the one that matters, and it fails

Row E is a rotated issuer under an already-published root: exactly what SPIRE CA
rotation produces. It fails. Consequences, stated plainly:

1. **SPIRE CA rotation breaks AD authentication** until the new intermediate is
   published to `NTAuthCertificates` *and* that publication has replicated to every
   KDC that might service the request.
2. Every rotation therefore imposes **an AD write plus a replication wait** on the
   critical path. The write needs Enterprise Admin-equivalent rights on the forest's
   configuration partition — a privilege level that does not belong in a certificate
   rotation loop, and cannot be delegated to SPIRE itself without effectively granting
   SPIRE the ability to add trusted CAs to the forest.
3. The "publish the internal root once and let SPIRE rotate freely" model — the
   cheap outcome `lab/README.md` hoped for — **is not available**. The blast-radius
   trade-off it implied is moot; the option does not exist.
4. This is a property of AD, independent of anything this plugin does. **No composer
   change can fix it**, because it is not about certificate shape at all. It joins
   Gate 1 as a dependency that lives outside the plugin's reach.

This does not by itself kill the approach, but it removes the graceful version of it.
Any viable design now needs an answer to "what publishes the new SPIRE intermediate to
NTAuth, with what privileges, and what happens to issuance during the replication
window" — and that answer is a prerequisite for the decision record, not a detail.

Open decision 9 (approved short-lived TTL) inherits a hard constraint from this: the
TTL floor is now bounded below by AD replication convergence, not just by KDC caching.

## Row G — a gap in the original six-row matrix

Rows E and F both rest on `leaf-i2`, and both failed with `0x3E`. `0x3E` is a *trust*
failure rather than `0x4B` (name mismatch, the mapping-failure signature), which is
suggestive — but it is not proof, because the KDC may evaluate trust before mapping and
never reach the mapping at all. Without a row in which `leaf-i2` **succeeds**, "E and F
failed because of NTAuth" is not separable from "leaf-i2 is simply broken."

Row G (`NTAuth={I2}`, `leaf-i2`) is the `I2` mirror of row A. It passes, with the test
account's real SID. That makes `leaf-i2` demonstrably sound and attributes E's and F's
failures to NTAuth membership alone.

Recorded as a correction to the matrix design, not just an extra data point: the
original six rows had two conclusions resting on an unverified premise.

## Caveats attached to every row above

- **Revocation checking is deliberately relaxed** on this KDC
  (`UseCachedCRLOnlyAndIgnoreRevocationUnknownErrors=1`), because the lab's leaves carry
  no CDP — this project's own unsolved Gate 1 gap. Bypassed, not closed. The NTAuth
  result is not sensitive to it (the relaxation is identical across all seven rows), but
  no row here is evidence about revocation behaviour.
- **Mapping was `X509SKI`, not `X509IssuerSerialNumber`.** See "Unresolved" below. Both
  are strong mappings under KB5014754, so the enforcement level drops out either way,
  and the mapping was held constant across all rows.
- **Row C substitutes `{I2}` for an empty NTAuth.** AD will not produce an empty one:
  `cACertificate` is `systemMustContain` on the `certificationAuthority` class, so it can
  be replaced but not cleared. `{I2}` satisfies README's "neither", and is a stronger
  control than empty — it shows the KDC checks *which* CA is present, not merely whether
  NTAuth is populated.
- Windows Server 2025, build `10.0.26100`, UBR `33296`, 24H2, last hotfix `KB5120232`.
  `StrongCertificateBindingEnforcement` is **absent from the registry** — the value
  stopped being honoured on 2025-09-09, so the DC is in full enforcement with no way
  back. That is the realistic configuration, and it is why a strong mapping was required
  for the rig to work at all.

## Unresolved: the `X509IssuerSerialNumber` string format

The matrix ran on `X509SKI` mappings. `X509IssuerSerialNumber` — the mapping the
previous session recorded, and the one closest to what a real deployment would use —
**still does not resolve**, and three candidate issuer-DN renderings were tried and all
failed with `0x4B` / `S-1-0-0`:

```
X509:<I>O=PKINIT Lab, CN=PKINIT Lab Intermediate CA 1<SR>6032…E22D   (.NET IssuerName.Name, with space)
X509:<I>O=PKINIT Lab,CN=PKINIT Lab Intermediate CA 1<SR>6032…E22D    (RFC2253, no space)
X509:<I>CN=PKINIT Lab Intermediate CA 1,O=PKINIT Lab<SR>6032…E22D    (DER order)
```

What *is* established: **the serial number is correct.** The KDC's own 4768 audit record
prints `Certificate Serial Number: 60328D94115295AFEBDD9BFC95A4E6A7635CE22D`, byte-for-byte
what `openssl x509 -serial` prints and what was in the `<SR>` field. So the previous
session's serial-encoding correction was right, and the remaining discrepancy is in the
`<I>` issuer-DN rendering alone.

Note this leaf's issuer DN is encoded `CN` **before** `O`, which is unusual — most CA
DNs are encoded least-specific-first. That is why the reversal convention derived from
Microsoft's `DC=com,DC=fabrikam,CN=CONTOSO-DC-CA` example is ambiguous here: for a
DC-prefixed DN, "reversed" and "as-encoded" coincide, so the example cannot distinguish
them. For this DN they differ, and neither worked.

This is **not on the critical path** for decision 11 — `X509SKI` is an equally strong
mapping and the matrix is valid on it — but it should be resolved before any claim is
made about what a real deployment's mapping looks like. It also does not affect Gate 2,
whose entire premise is *replacing* `altSecurityIdentities` with the SID extension.

Do not re-derive it by reasoning about byte order again; that has now failed twice.
Get the KDC to state the string it computes, or obtain a known-good
`X509IssuerSerialNumber` mapping from an ADCS-issued certificate and work backwards.

## Prerequisite bugs fixed to get here

None of these were NTAuth. All were real, and all had to be fixed before any row could
run. Recorded so they are not re-discovered:

1. **Client-side chain completion** — `pkinit_pool` entries for `I1` and `I2` in
   `lab/krb5.conf`. Without them the client fails on its own leaf before sending
   anything.
2. **`altSecurityIdentities` format** — the strings recorded before this session were
   wrong and had never been exercised. Still only partly resolved; see above.
3. **Revocation checking** — relaxed on the KDC, since the lab's leaves have no CDP.
4. **krb5 client too old** — Windows Server 2025's KDC requires `paChecksum2`, added in
   MIT krb5 **1.22**. Ubuntu 24.04 ships 1.20.1 and LTS never backports protocol
   features, so there is no `apt` path. Built 1.22.2 from source into `~/vms/krb5-1.22`
   (tarball PGP signature verified against MIT's published fingerprint for
   `ghudson@mit.edu`). **A stock LTS distro cannot do PKINIT against current Windows
   Server at all** — a production-relevant finding independent of NTAuth.
5. **KDC certificate SAN validation** — the client rejected the *KDC's* certificate with
   `KDC name mismatch` *after* the KDC had already accepted the client and issued the
   AS-REP, which reads like a KDC-side rejection but is entirely client-side. RFC 4556
   wants an `id-pkinit-san` otherName; the lab's openssl-built KDC cert carries a plain
   `dNSName` SAN, which MIT krb5 only accepts when told which hostname to match. Fixed
   with `pkinit_kdc_hostname` in `lab/krb5.conf`.

A `configure`-time trap worth recording separately: **MIT krb5's `configure` exits 0
with PKINIT silently disabled** when OpenSSL headers are missing, printing only
`configure: Disabling PKINIT support`. The build then installs a krb5 that cannot do
PKINIT at all and fails much later with a confusing error. `lab/03-run-row.sh` now
preflights for `pkinit.so`.
