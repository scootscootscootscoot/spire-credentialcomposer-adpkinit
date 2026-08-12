# Fixture acquisition — AD SID security extension

Status: procedure, not yet executed
Date: 2026-08-12

## Why this document exists

`szOID_NTDS_CA_SECURITY_EXT` (`1.3.6.1.4.1.311.25.2`) is the Gate 2 extension. It is
the one piece of this project with no reference implementation available to check
against: unlike the CDP extension — which RFC 5280 specifies and `crypto/x509`
already implements, so `internal/encoding/cdp.go` can be golden-tested against a
certificate the standard library produces — there is nothing in Go, OpenSSL, or any
other library the project can call that emits this extension.

The standing rule is therefore that its encoding **must not be inferred from
documentation, from the OID, or from a prose description of the structure.** A
plausible-looking encoding that the KDC silently rejects, or worse, accepts while
mapping to the wrong account, is precisely the failure mode this project exists to
avoid. The extension builder stays unimplemented until a fixture exists.

This document defines what would end that blocked state.

## What the fixture must answer

These are open questions, not gaps in the write-up. Each must be answered from
observed bytes, and each is a place where a wrong guess produces a certificate that
looks correct:

1. **Outer structure.** Is the extension value a `GeneralNames` SEQUENCE containing
   one `OtherName`, or some other container?
2. **Inner value encoding.** Does the `OtherName` value carry the SID as its
   **binary** MS-DTYP form (what `internal/encoding.MarshalSID` produces) or as its
   **string** rendering (`"S-1-5-21-…"`) in an OCTET STRING? This is the single most
   consequential unknown; the two are not distinguishable from the OID alone.
3. **String termination.** If the value is a string, is it NUL-terminated, and is it
   ASCII or UTF-8?
4. **Tagging.** Is the `OtherName` value explicitly or implicitly tagged, and with
   what class and number?
5. **Criticality.** Does ADCS mark the extension critical or non-critical? Match what
   ADCS does rather than reasoning about what it should do.
6. **Position and multiplicity.** Where does ADCS place the extension relative to the
   others, and does the KDC care? (Answering the KDC half needs the phase-4 lab; the
   ADCS half comes from the fixture.)

Question 2 also decides whether `internal/encoding.MarshalSID` sits on the issuance
path at all. That codec is not wasted work either way — AD stores `objectSid` in
binary, so the mapping-snapshot producer needs it regardless — but do not treat its
existence as evidence for the binary answer.

## Acceptable sources, in order of authority

1. **A certificate issued by a real ADCS instance in a disposable lab.** Strongest
   evidence: it is the exact producer whose output the KDC is built to consume, and
   the CA configuration that produced it can be recorded alongside.
2. **An authoritative Microsoft-published test vector** — a byte-level example in
   Microsoft's own protocol documentation or security-advisory guidance. Weaker than
   (1) only because it may lag the behaviour of the patch level actually deployed.
   Verify the specific document contains real bytes; a structural description in
   prose does **not** qualify, and no such vector has been confirmed to exist yet.
3. **A third-party certificate observed to contain the extension** — acceptable only
   as corroboration for (1) or (2), never on its own, and only if it can be shown to
   carry no real forest's SID (see sanitization). Provenance is usually too weak to
   rely on.

An implementation in another open-source project is **not** a source. It has the same
inference problem this rule exists to prevent, and copying its interpretation would
launder a guess into an apparent fact. Such an implementation may be used to
*cross-check* a fixture already obtained from (1) or (2).

## Capture procedure

**Sequencing constraint:** the decisions log says the Windows Server eval VM must not
be built before phase 2 exits. That still holds — this section is the procedure to
run when it does, not authorisation to start now. If source (2) turns up a usable
published vector, Gate 2 can unblock without any VM.

When the lab is authorised:

1. Stand up a Windows Server evaluation VM under KVM with AD DS and AD CS roles, in a
   forest created for this purpose and connected to nothing.
2. Create a throwaway user account in that forest.
3. Issue a certificate to that account from a template that produces the SID
   extension — on current patch levels ADCS adds it to certificates issued through
   account-based enrolment.
4. Export the certificate as DER. **The public certificate only. Never the private
   key**, which must not leave the VM and must never be written to this repository.
5. Record, in the same commit as the fixture: Windows Server build number, patch
   level, CA name and template used, and the date of issue. A fixture whose
   provenance is not recorded cannot be re-derived and is not evidence.
6. Decode the extension and answer all six questions above from the bytes:

   ```
   openssl x509 -in fixture.der -inform DER -text -noout
   openssl asn1parse -in fixture.der -inform DER -strparse <offset>
   ```

   Cross-check the structure with Go's `encoding/asn1` rather than trusting a single
   parser's rendering.

## Sanitization

The fixture is committed to a repository that will eventually be public. Before it
goes in:

- It must come from a **disposable lab forest**, never a real one. A SID from a real
  forest is a work artifact and must not appear in this repository under any
  circumstances — this is not a redaction problem, it is a "do not obtain it from
  there" problem.
- The certificate must contain **no private key** and no key material of any kind.
- Domain names, account names, and CA names in the fixture must be synthetic
  (`example.org`-style), which is achieved by naming the lab forest that way at
  creation time rather than by editing bytes afterwards. **Do not hand-edit DER to
  sanitize it** — an edited fixture is no longer evidence of what ADCS emits, which
  destroys the only reason to have it.
- Record in the fixture's provenance note that the forest was created disposable and
  destroyed afterwards.

## Storage

Fixtures live in `internal/encoding/testdata/`.

`.gitignore` currently excludes `*.der` repository-wide, deliberately. It is **not**
being pre-emptively relaxed: the negation should be added in the same change that
adds the first reviewed, sanitized fixture, so that no `.der` can be committed by
accident before someone has looked at it. When that change lands, add:

```gitignore
# Sanitized, synthetic ADCS fixtures — reviewed before commit. See docs/FIXTURES.md.
!internal/encoding/testdata/*.der
```

Each fixture gets a sibling `.md` provenance file recording the six answers and the
capture metadata from step 5.

## How the golden test pins it

Once the fixture exists, the extension builder is written to match it, and the golden
test asserts equality against the fixture's exact bytes — the same standard
`TestCRLDistributionPointsGoldenBytes` and `TestCRLDistributionPointsMatchesStdlib`
already apply to Gate 1:

1. Read the fixture certificate from `testdata/`.
2. Extract the extension with OID `1.3.6.1.4.1.311.25.2`, and assert its criticality
   matches what ADCS emitted.
3. Feed the same SID to the builder and require **byte-for-byte** equality with the
   fixture's extension value.
4. Add a decode test asserting the builder's output parses back to exactly the input
   SID, and malformed-input tests for every rejection path.
5. Add a fuzz target with the same shape as `FuzzMarshalSID`: never panic, and
   anything accepted round-trips unchanged.

A builder that produces bytes merely *equivalent* to the fixture is not sufficient.
Two DER encodings can be semantically equal and still differ, and the KDC's tolerance
for that variation is unknown — which is the whole reason for this document.

## Exit criteria

Gate 2 leaves the blocked state when all of these hold:

- [ ] A fixture from source (1) or (2) is in `internal/encoding/testdata/`, sanitized,
      with provenance recorded.
- [ ] All six questions above are answered from observed bytes and written down.
- [ ] The extension builder exists and its golden test asserts byte-for-byte equality
      with the fixture.
- [ ] Malformed-input and fuzz tests cover the builder.
- [ ] Only then may the plugin call it.

Answering these makes the *certificate* correct. It does not close Gate 2
end-to-end — that needs the KDC to accept the resulting certificate for the intended
account, and the wrong-SID and missing-SID negatives, which is phase 4.
