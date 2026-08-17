# Resume point

Parked: 2026-08-17. Host: `labhost`.

This is the cold-start file. It records machine state that is *not* recoverable from
the code or git history, plus the decisions that are already settled so they don't get
re-argued. It is a living document — overwrite it when parking, don't append.

The tracker (`docs/status.html`, deliberately untracked) is the board. This is the
notebook behind it.

---

## Where the work is, in one paragraph

**Open decision 11 is answered.** The full NTAuth matrix ran end to end — all seven rows,
with both controls behaving — and the answer is that `NTAuthCertificates` requires the
**direct issuing CA**; a root is neither necessary nor sufficient. The operationally
decisive row (E: rotated issuer under a published root) **fails**, which means SPIRE CA
rotation imposes an AD write plus a replication wait on every rotation, and the cheap
"publish the root once and rotate freely" model is not available at all. Written up in
`docs/findings/2026-08-17-ntauth-requires-direct-issuer.md` — read that, it is the
substantive output of this session. The phase-4 lab has now delivered what it was opened
to deliver.

## The result, in one table

| Row | `NTAuth` | Leaf | Result |
|---|---|---|---|
| A | `{I1}` | leaf-i1 | **PASS** |
| B | `{R}` | leaf-i1 | FAIL |
| C | `{I2}` | leaf-i1 | FAIL (negative control) |
| D | `{R, I1}` | leaf-i1 | **PASS** |
| E | `{R}` | leaf-i2 | FAIL ← the decisive row |
| F | `{I1}` | leaf-i2 | FAIL |
| G | `{I2}` | leaf-i2 | **PASS** (added this session) |

A row passes iff the leaf's **immediate issuer** is in NTAuth. Transcripts:
`~/vms/lab-evidence/row-{A..G}-*.txt` (outside the repo by design).

Row G is not in `lab/README.md`'s original six. It was added because rows E and F both
rest on `leaf-i2`, so without a row where `leaf-i2` *succeeds*, their failures could not
be attributed to NTAuth rather than to a broken leaf. It passes, closing that gap.

## What was fixed to get here

Five prerequisite bugs, none of them NTAuth, all enumerated with detail in the finding
doc. The two worth knowing before touching anything:

- **krb5 1.22.2 is built at `~/vms/krb5-1.22`** and is required. Ubuntu 24.04's stock
  1.20.1 cannot do PKINIT against Windows Server 2025 (missing `paChecksum2`), and there
  is no `apt` path to a fix on an LTS release. Tarball signature was verified against
  MIT's published fingerprint. **Trap: MIT krb5's `configure` exits 0 with PKINIT
  silently disabled if OpenSSL headers are missing** — it only prints
  `configure: Disabling PKINIT support`. Build deps: `bison libssl-dev pkg-config`.
- **`lab/krb5.conf` gained `pkinit_kdc_hostname`.** Without it the client rejects the
  *KDC's own* cert with `KDC name mismatch` — after the KDC has already accepted the
  client and issued the AS-REP, so it reads like a KDC-side rejection when it is
  entirely client-side.

## The one thing still open from the lab

**The `X509IssuerSerialNumber` mapping string still does not resolve.** The matrix ran on
`X509SKI` instead, which is an equally strong mapping under KB5014754 and was held
constant across all rows, so the result is unaffected.

What is established: **the serial number is correct** — the KDC's own 4768 record prints
it byte-for-byte identical to `openssl x509 -serial` and to the `<SR>` field. The
discrepancy is in the `<I>` issuer-DN rendering alone. Three renderings were tried
(.NET-with-space, RFC2253-no-space, DER-order) and all three failed with `0x4B` /
`S-1-0-0`.

**Do not re-derive this by reasoning about byte order or RDN order again — that has now
failed twice.** Either get the KDC to state the string it computes, or obtain a
known-good `X509IssuerSerialNumber` mapping from an ADCS-issued cert and work backwards.
Note this lab's issuer DN is encoded `CN` before `O`, which is why Microsoft's
`DC=com,DC=fabrikam,CN=…` example cannot settle the convention: for a DC-prefixed DN,
"reversed" and "as-encoded" coincide.

This is off the critical path — Gate 2's whole premise is *replacing*
`altSecurityIdentities` with the SID extension.

## Current live lab state

- VM `pkinit-dc01` **running**. All state survived a cold boot this session.
- `NTAuth` = `{I2}` (row G's state, whatever ran last — set per row by the runner).
- `altSecurityIdentities` on `pkinittest` = two `X509SKI` entries:
  `366BF3066E0C591ABB11BB3B7C69AB4122ACC7FD` (leaf-i1),
  `60927B20A3D6242AAD308EE3A054398593764B72` (leaf-i2).
- KDC cert thumbprint `5ACB70E0C27DAFA491905D426714059FBB26521B`, valid to 2028-08-12.
- Revocation relaxed: `UseCachedCRLOnlyAndIgnoreRevocationUnknownErrors=1`.
- `StrongCertificateBindingEnforcement` **absent** from the registry — stopped being
  honoured 2025-09-09, so the DC is in full enforcement with no way back. This is why a
  strong mapping was mandatory for the rig to work at all.
- Windows Server 2025, `10.0.26100`, UBR `33296`, 24H2, last hotfix `KB5120232`.
- Cert files staged on the guest at `C:\pki\{root-ca,i1,i2}.crt`.

## How to run a row

```bash
cd /home/labop/Desktop/spire_credential_helper_plugin
./lab/03-run-row.sh A            # sets NTAuth to row A's state, then tests
./lab/03-run-row.sh A --no-setup # tests against whatever NTAuth holds now
```

Writes a full transcript per run to `~/vms/lab-evidence/`, capturing everything
`lab/README.md`'s "What to record for every row" demands. It does not judge pass/fail —
it records and prints `kinit`'s verbatim outcome.

Two mechanics inside it that were painful to find and must not be undone:

- **NTAuth is set with one atomic `Set-ADObject -Replace`, never clear-then-publish.**
  `-Clear` cannot work — `cACertificate` is `systemMustContain` on the
  `certificationAuthority` class, so AD rejects it with "A required attribute is
  missing". And `certutil -dspublish` only *adds*, so without a clear a row's state
  silently becomes the previous row's plus its own — wrong in the direction that makes
  rows pass.
- **The value list is built with `+= ,(...)`.** The unary comma is load-bearing: a bare
  `@($derBytes)` flattens the byte array into ~1000 single-byte values and AD rejects the
  write with "The specified value already exists" (error 8323).

Verified this session: `-Replace` **removals** do propagate to the KDC's local cached
store after `certutil -pulse`, not just additions. Unforced propagation timing is still
unmeasured.

## Settled — do not re-litigate

- **The experiment needed no SPIRE and no plugin code.** It is now finished.
- **No ADCS.** The CA chain is openssl. ADCS is still wanted for one thing only: the
  Gate 2 fixture.
- **No Windows client, no virtual smartcard.** The Linux host is the PKINIT client, via
  the locally-built krb5 1.22.2.
- **Revocation checking is deliberately relaxed** and every row's result carries that
  caveat. Bypassed, not closed.
- **`pkinit-lab-shell` is the standard way to interact with `pkinit-dc01`.** SPICE
  clipboard paste is a known-bad fallback for long lines. See
  `.claude/skills/pkinit-lab-shell/SKILL.md`.
- None of the lab scripts, `krb5.conf`, evidence transcripts, or
  `.claude/skills/pkinit-lab-shell/` are git-committed. Whether/when to commit is the
  owner's call. Note the evidence transcripts contain lab SIDs and hostnames — synthetic,
  but `CLAUDE.md`'s hygiene rules point at keeping them out regardless.

## What this result changes downstream

- **Open decision 9 (TTL)** now has a hard floor it did not have: AD replication
  convergence, not just KDC caching.
- **Phase 5 / the decision record** need an answer to "what publishes the new SPIRE
  intermediate to NTAuth, with what privileges, and what happens to issuance during the
  replication window". The privilege level required is forest-configuration write —
  which does not belong in a rotation loop.
- **Neither gate moved.** Gate 1 is still parked (nothing can sign a CRL over
  SPIRE-issued leaves). Gate 2 is still blocked on the fixture.

## Deliberately not being worked on

- **Phase 2** (`ComposeWorkloadX509SVID`). Still untouched.
- **Gate 1.** Still parked as a research finding.
- **The Gate 2 DER fixture.** Was blocked on decision 11; decision 11 is now answered, so
  this is the natural next thing — it needs the ADCS role on this same VM, or an
  authoritative published Microsoft byte vector if one exists.

## Pointers

| Thing | Where |
|---|---|
| **This session's result** | `docs/findings/2026-08-17-ntauth-requires-direct-issuer.md` |
| Governing plan, open decisions | `docs/RESEARCH-PLAN.md` |
| Why Gate 1 and NTAuth rotation are problems | `docs/findings/2026-08-12-ca-chaining-and-revocation.md` |
| Gate 2 fixture procedure | `docs/FIXTURES.md` |
| Experiment design and matrix | `lab/README.md` |
| Row runner | `lab/03-run-row.sh` |
| Evidence transcripts | `~/vms/lab-evidence/` (outside the repo) |
| Hard rules, decisions log | `CLAUDE.md` |
| Board | `docs/status.html` (untracked; open with `file://`) |
| Openssl CA chain (built, not in git) | `~/vms/pki` |
| Remote-exec into the DC | `.claude/skills/pkinit-lab-shell/SKILL.md` |
| krb5 1.22.2 build | `~/vms/krb5-1.22` |

Verify before any commit: `go build ./... && go vet ./... && go test ./...`, plus
`gofmt -l .` clean. Commits are signed off (`git commit -s`).
