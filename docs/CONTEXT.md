# Resume point

Parked: 2026-08-12. Host: `labhost`.

This is the cold-start file. It records machine state that is *not* recoverable from
the code or git history, plus the decisions that are already settled so they don't get
re-argued. It is a living document — overwrite it when parking, don't append.

The tracker (`docs/status.html`, deliberately untracked) is the board. This is the
notebook behind it.

---

## Where the work is, in one paragraph

The plugin's phase-1 encoding work is built and tested (CDP golden-tested against
`crypto/x509`, MS-DTYP SID codec with known-value vectors, ~7M fuzz executions clean).
Phase 2 — `ComposeWorkloadX509SVID` itself — is **not** started. Gate 2 is blocked on a
DER fixture that must come from a real ADCS cert or an authoritative Microsoft vector
(`docs/FIXTURES.md`). Gate 1 turned out to be blocked on something the plugin cannot fix
at all: nothing can sign a CRL covering SPIRE-issued leaves
(`docs/findings/2026-08-12-ca-chaining-and-revocation.md`). So attention moved to the
one question that is both answerable now and decisive.

## The one question in flight

**Open decision 11.** Does `NTAuthCertificates` accept a **root** CA, or must the
**direct issuing** CA be published?

It matters because in a SPIRE chain the direct issuer is SPIRE's intermediate — the
certificate SPIRE rotates by design. If NTAuth demands the direct issuer, every SPIRE CA
rotation forces an AD write plus a replication wait before newly issued SVIDs can
authenticate, and no amount of plugin code fixes that.

The full experiment design, the six-row test matrix, and the controls are in
`lab/README.md`. Read that before touching the lab.

## Machine state — verified 2026-08-12, after `lab/00-host-setup.sh`

Installed and confirmed working:

| Component | Version | State |
|---|---|---|
| qemu | 8.2.2 (Ubuntu 1:8.2.2+ds-0ubuntu1.18) | — |
| libvirtd | 10.0.0 | `active`, `enabled` |
| virsh / virt-install | 10.0.0 / 4.1.0 | — |
| virt-viewer | installed | — |
| krb5-user, krb5-pkinit | 1.20.1-6ubuntu2.7 | PKINIT plugin present |
| Go | 1.26.5 | — |
| kernel | 7.0.0-28-generic | Ubuntu 24.04.4 |

- `scoot` is in `kvm` and `libvirt`. **Group membership does not apply to shells that
  were already open when the setup ran** — a shell started before then still needs
  `sg libvirt -c '...'`. A fresh terminal is fine.
- libvirt `default` network is active, autostart on, bridge `virbr0`,
  `192.168.122.0/24`.
- `/var/lib/libvirt/images` has an ACL granting `scoot` `rwx`, so image operations need
  no further sudo.
- `osinfo-query` is **not** installed (`--no-install-recommends` skips `libosinfo-bin`).
  This is fine — `lab/01-create-dc-vm.sh` asks `virt-install --osinfo list` instead,
  which does have `win2k25`. Don't reintroduce an `osinfo-query` dependency.

Not built yet:

- **No libvirt domains exist.** `virsh list --all` is empty. The DC VM has not been
  created; nothing is consuming RAM.
- No CA chain, no AD forest, no test account, no `krb5.conf` for the lab.
- `lab/` steps 02 onward (CA chain, publication, PKINIT runs) are **not written**. Only
  `00`, `01`, `99` and `lab.env` exist.

Install media, staged outside the repo in `~/vms/iso` (6.8 GB, plus `SHA256SUMS`):

| File | Bytes | SHA-256 |
|---|---|---|
| `windows-server-2025-eval-x64-en-us.iso` | 6014152704 | `d0ef4502e350e3c6c53c15b1b3020d38a5ded011bf04998e950720ac8579b23d` |
| `virtio-win-0.1.285.iso` | 789645312 | `e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331` |

Windows Server 2025 evaluation, 180 days, build 26100.1742. Those hashes are local
rebuild baselines, not independent verification — neither upstream publishes an ISO
hash. See `lab/README.md`, "Install media".

Resources: 20 cores, 15 GB RAM (~7 GB free with a normal desktop session), 104 GB free
on `/`. The VM is specced at 4 vCPU / 4096 MB / 60 GB sparse qcow2. **4 GB is a
deliberate compromise** — 6 GB would be more comfortable for AD DS but leaves ~1 GB for
the host. Raise it in `lab/lab.env` if the desktop is quiet.

## The exact next command

From a **new** terminal (for group membership):

```
cd ~/Desktop/spire_credential_helper_plugin
lab/01-create-dc-vm.sh
virt-viewer --connect qemu:///system pkinit-dc01
```

Open the console *before* clicking through — Windows Setup shows a "Press any key to
boot from CD" prompt for a few seconds and there is no second chance without
`virsh reset pkinit-dc01`.

## The sequence after that

1. Install Windows Server 2025 **with Desktop Experience**.
2. Static `192.168.122.10/24`, gw `192.168.122.1`, DNS `127.0.0.1`. The DHCP reservation
   already hands out that address; setting it static keeps the AD DS wizard quiet.
3. Rename to `dc01`, reboot.
4. Promote to a new forest `pkinitlab.internal` / NetBIOS `PKINITLAB`.
5. Patch fully; record the build number.
6. **Write `lab/02-make-ca-chain.sh`** — openssl root `R`, intermediates `I1` and `I2`,
   a KDC cert for the DC (EKU `1.3.6.1.5.2.3.5`, `dNSName` SAN of the FQDN), and leaf
   certs. Keys under `~/vms/`, never in the tree.
7. Write the lab `krb5.conf` pinning the KDC by address, used via `KRB5_CONFIG=` so the
   host's own Kerberos config is never touched.
8. Run the six-row matrix from `lab/README.md`, recording everything that section lists.

## Settled — do not re-litigate

- **The experiment needs no SPIRE and no plugin code.** NTAuth root-vs-issuer is a
  property of AD; any two-level chain exercises it. This is why building the lab now
  does not front-run phase 2, and why the "not before phase 2 exits" entry in CLAUDE.md
  is marked superseded.
- **No ADCS.** The CA chain is openssl. ADCS gets installed later, briefly, only as the
  Gate 2 fixture source.
- **No Windows client, no virtual smartcard.** The PKINIT client is the Linux host,
  which is also what a real workload is: a process holding a cert and key calling
  `kinit -X X509_user_identity=FILE:...`.
- **The test account is mapped with `altSecurityIdentities` =
  `X509IssuerSerialNumber`.** Since KB5014754, a DC in full enforcement (default since
  2025-02-11; the registry override stopped being honoured 2025-09-09) rejects any cert
  without a strong mapping. A UPN-only cert would fail *every* row and read as an NTAuth
  result when it was a mapping-enforcement result. A strong mapping holds at every
  enforcement value, so patch level drops out of the experiment.
- **The root is published for chain trust and the intermediate installed on the DC in
  every row**, so a failure can never be a missing intermediate in disguise. NTAuth
  membership is the only variable.
- **Row A must pass and row C must fail** before any other row is believed.
- **SATA + e1000e, not virtio**, so Windows Setup needs no injected drivers. The virtio
  ISO is attached anyway for later conversion.
- Every strong mapping except the SID extension is issuer- or key-bound, so all of them
  break on re-issuance. That fragility is *why* the project wants Gate 2. Here we
  rewrite the mapping per leaf and keep the two questions separate. Record it; don't
  conflate it.

## Gotchas waiting for whoever picks this up

- Group membership in pre-existing shells (above).
- The "press any key" prompt (above).
- Memory headroom is thin at 4 GB guest + desktop. If AD DS promotion is painfully slow,
  close things and raise `VM_MEMORY_MB`.
- `lab/99-destroy-dc-vm.sh` removes the domain, the disk, and the DHCP reservation but
  deliberately keeps the ISOs — re-downloading 6 GB is the slow part of a rebuild.
- The lab must never be pointed at, or joined to, any real AD. `pkinitlab.internal` is
  synthetic; `.internal` is ICANN-reserved for private use.

## Deliberately not being worked on

- **Phase 2** (`ComposeWorkloadX509SVID`). Untouched by design while decision 11 is open.
- **Gate 1.** Parked as a research finding, not a task: SPIRE has no CRL surface, and no
  available signer covers SPIRE-issued leaves. Gate 2 is tested first with revocation
  checking relaxed, and that must be recorded as "deliberately bypassed, not closed".
- **The Gate 2 DER fixture.** Still blocked; the procedure is written
  (`docs/FIXTURES.md`) and the ADCS role on this same VM is the intended source, but
  only after decision 11 is answered.

## Pointers

| Thing | Where |
|---|---|
| Governing plan, open decisions | `docs/RESEARCH-PLAN.md` |
| Why Gate 1 and NTAuth rotation are problems | `docs/findings/2026-08-12-ca-chaining-and-revocation.md` |
| Gate 2 fixture procedure | `docs/FIXTURES.md` |
| Experiment design and matrix | `lab/README.md` |
| Hard rules, decisions log | `CLAUDE.md` |
| Board | `docs/status.html` (untracked; open with `file://`) |

Verify before any commit: `go build ./... && go vet ./... && go test ./...`, plus
`gofmt -l .` clean. Commits are signed off (`git commit -s`).
