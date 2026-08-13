# Phase-4 lab — the NTAuth chaining experiment

This lab exists to answer **one question**, open decision 11:

> Does `NTAuthCertificates` accept a **root** CA, or must the **direct issuing** CA be
> published?

Everything here is scoped to that. Resist growing it. The answer decides whether the
whole approach is operationally viable, because in a SPIRE chain the direct issuer is
SPIRE's intermediate — the certificate SPIRE rotates by design. See
`../docs/findings/2026-08-12-ca-chaining-and-revocation.md`, finding 2.

## Why this does not need SPIRE, or this plugin

The question is about a property of AD, not a property of SPIRE. Any two-level chain
exercises it:

```
Root CA  ──signs──▶  Intermediate CA  ──signs──▶  leaf cert for a test AD user
```

SPIRE's only role in the real design is *being* that intermediate, and being one that
rotates. An openssl-generated intermediate rotates just as well and costs nothing. So
this experiment is runnable now, with no plugin code, no `ComposeWorkloadX509SVID`, and
no SPIRE deployment.

That matters for sequencing: the recorded decision "do not build the lab before phase 2
exits" assumed the lab was only useful once there was something to put in it. For this
question that assumption does not hold.

**It also does not need the Gate 2 SID extension.** See the next section — that is a
deliberate choice, not an oversight.

## The confounder that would silently wreck this

Since KB5014754, a domain controller in **Full Enforcement** mode rejects certificates
that lack a *strong* mapping to the account. A cert mapped only by UPN — the classic
smartcard-logon setup — now fails. If we used a UPN-only cert here, every row of the
matrix would fail, and it would look like an NTAuth answer when it was actually a
mapping-enforcement answer.

`HKLM\SYSTEM\CurrentControlSet\Services\Kdc\StrongCertificateBindingEnforcement`:

| Value | Behaviour |
|---|---|
| 0 | check disabled entirely (disables the security enhancement; not used here) |
| 1 | compatibility — weak mapping allowed if the account predates the certificate |
| 2 | full enforcement — no strong mapping, no authentication |

Default became **2** on 2025-02-11, and the **key stopped being honoured on
2025-09-09** — a current DC is in full enforcement with no way back.

**Control chosen:** map the test account with `altSecurityIdentities` =
`X509IssuerSerialNumber`, which KB5014754 classifies as a *strong* mapping. Strong
mappings satisfy the check at every enforcement value, so the enforcement setting drops
out of the experiment entirely and the DC can be fully patched — which is the realistic
configuration anyway.

Strong: `X509IssuerSerialNumber`, `X509SKI`, `X509SHA1PublicKey`.
Weak: `X509IssuerSubject`, `X509SubjectOnly`, `X509RFC822`.

Note the irony, and record it: *every* strong mapping except the SID extension is
issuer- or key-bound, so each one breaks on re-issuance. That fragility is the reason
this project wants the SID extension. Here we accept it and re-write the mapping per
leaf, because we are testing NTAuth, not mapping durability. Do not let the two
questions merge.

## The other control: chain building must not be the failure

A leaf can be rejected for a missing intermediate rather than for NTAuth. Those look
similar and mean opposite things. So in every row:

- the **root** is published to `CN=Certification Authorities,CN=Public Key Services,…`
  (chain trust), and
- the **intermediate** is in the DC's `Intermediate Certification Authorities` store,

regardless of what NTAuth contains. NTAuth membership is then the only variable.

## Test matrix

`R` = root, `I1` = first intermediate, `I2` = a second intermediate under the same root
standing in for a rotated SPIRE CA. `I2` is never published to NTAuth.

| # | In `NTAuthCertificates` | Leaf issued by | Purpose |
|---|---|---|---|
| A | `I1` | `I1` | baseline — proves the rig works before anything is concluded |
| B | `R` only | `I1` | **the question** |
| C | neither | `I1` | negative control — must fail, or the rig proves nothing |
| D | `R` + `I1` | `I1` | control for interference between the two |
| E | `R` only | `I2` | **the operationally decisive row** — a rotated issuer under a published root |
| F | `I1` only | `I2` | if B fails, confirms republication is genuinely required |

Row A must pass and row C must fail before any other row is believed.

Row E is the one that decides the project. If it passes, publish the internal root once
and let SPIRE rotate freely — at the cost of blast radius, since everything that root
ever signs can then attempt AD authentication. If it fails, SPIRE CA rotation imposes an
AD write plus a replication wait on every rotation, and the recovery model has to be
designed around that before anything else proceeds.

## Topology

One VM. The PKINIT client is the Linux host, which is also what a real workload would
be — a Linux process holding a cert and key, calling `kinit`. No Windows client, no
virtual smartcard.

```
labhost (Ubuntu 24.04)                    virbr0            pkinit-dc01
├─ openssl: R, I1, I2, leaves         192.168.122.0/24   Windows Server 2025
├─ kinit -X X509_user_identity=…  ─────────────────────▶  AD DS + KDC
└─ KRB5_CONFIG=lab/krb5.conf                              192.168.122.10
```

- Domain `pkinitlab.internal`, realm `PKINITLAB.INTERNAL`, NetBIOS `PKINITLAB`.
  `.internal` is ICANN-reserved for private use. It is synthetic; it is not a real
  forest and must never be pointed at one.
- The lab `krb5.conf` pins the KDC by address, so no host DNS or `/etc/krb5.conf`
  changes are needed.
- ADCS is **not** installed for this experiment. The CA chain is openssl. ADCS gets
  added later, briefly, only as the Gate 2 fixture source (`../docs/FIXTURES.md`).

The DC also needs its own KDC certificate for PKINIT — EKU `1.3.6.1.5.2.3.5`
(KDC Authentication), a `dNSName` SAN of the DC FQDN, chaining to a root the client
trusts. It is issued from the same lab root. Note it is *not* an NTAuth question: NTAuth
governs client authentication certificates, not the KDC's own.

## Install media

Downloaded to `~/vms/iso` (outside the repo — 6.8 GB of binaries never enter git):

| File | Bytes | SHA-256 |
|---|---|---|
| `windows-server-2025-eval-x64-en-us.iso` | 6014152704 | `d0ef4502e350e3c6c53c15b1b3020d38a5ded011bf04998e950720ac8579b23d` |
| `virtio-win-0.1.285.iso` | 789645312 | `e14cf2b94492c3e925f0070ba7fdfedeb2048c91eea9c5a5afb30232a3976331` |

Windows Server 2025 evaluation, 180 days, build **26100.1742** (`ge_release_svc_refresh`,
2024-09-06) — via `https://go.microsoft.com/fwlink/?linkid=2293312`, which redirects to
`software-static.download.prss.microsoft.com`. virtio-win from the Fedora virt group.

**What those hashes are and are not:** neither Microsoft nor the virtio-win project
publishes a hash for these ISOs (fedorapeople's `CHECKSUM` covers only the RPMs), so
these are *local baselines*, recorded so a rebuild can prove it used identical media.
They are not independent verification. What is verified: both transfers matched the
advertised `Content-Length` exactly over TLS, and both are valid ISO 9660 images with
the Windows one bootable.

## Build order

```
sudo lab/00-host-setup.sh      # only step needing root: KVM, libvirt, krb5 PKINIT client
lab/01-create-dc-vm.sh         # defines and starts the VM
virt-viewer --connect qemu:///system pkinit-dc01
```

Then, in the guest:

1. Install Windows Server 2025 **with Desktop Experience** (the Server Core install is
   smaller but every step below is easier with a GUI, and this VM is disposable).
2. Set the adapter static: `192.168.122.10/24`, gateway `192.168.122.1`, DNS
   `127.0.0.1`. The address is already DHCP-reserved, so it matches from first boot;
   setting it static keeps the AD DS wizard quiet.
3. Rename to `dc01`, reboot.
4. Install AD DS, promote to a new forest `pkinitlab.internal`, NetBIOS `PKINITLAB`.
5. Patch fully, then record the build number. With a strong mapping the patch level does
   not change the result — recording it is how we prove that rather than assume it.

Steps 6 onward (CA chain, publication, PKINIT runs) are scripted separately as they are
written. Nothing beyond this point is built yet.

## What to record for every row

A result without these is not evidence:

- exact Windows build (`winver` / `[System.Environment]::OSVersion`) and patch date
- `StrongCertificateBindingEnforcement` value as actually read from the registry
- the full `kinit` invocation and its verbatim output, including `KRB5_TRACE=/dev/stderr`
- the KDC-side event: Event Viewer → Applications and Services → Microsoft → Windows →
  Kerberos-Key-Distribution-Center
- `certutil -viewstore -enterprise NTAuth` output, to prove NTAuth contained exactly
  what the row claims
- time between publication and the observed behaviour change (this is the AD
  replication cost that row E is really measuring)

## Hygiene

Repo rules apply here in full (`../CLAUDE.md`):

- Everything is synthetic. No real forest names, no real SIDs, no production certs, no
  private keys in the repo — the lab writes keys under `~/vms/`, never into the tree.
- ISOs and disk images live in `~/vms/iso` and `/var/lib/libvirt/images`, never in git.
- This lab is never connected to any real AD, and the host is not joined to anything.

## Teardown

```
lab/99-destroy-dc-vm.sh        # domain, disk, and the DHCP reservation
```
