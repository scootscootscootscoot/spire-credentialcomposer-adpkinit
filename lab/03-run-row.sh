#!/usr/bin/env bash
# Run one row of the NTAuth chaining matrix and capture the evidence that
# lab/README.md's "What to record for every row" section demands. Doing this
# by hand six times is how rows end up with non-comparable evidence.
#
#   lab/03-run-row.sh A            # set NTAuth to row A's state, then test
#   lab/03-run-row.sh A --no-setup # test against whatever NTAuth holds now
#
# Each run writes a self-contained transcript to ~/vms/lab-evidence/. The
# transcript is the artifact — a row's result is not "recorded" because the
# terminal happened to scroll past it.
#
# This script does NOT decide whether a row passed. It records what happened
# and prints kinit's verbatim outcome. Row A must pass and row C must fail
# before any other row is believed (README.md, "Test matrix").

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
# shellcheck source=lab.env
source "${HERE}/lab.env"

RUN_PS="${REPO}/.claude/skills/pkinit-lab-shell/run-ps.sh"

# Built from source into a local prefix because Ubuntu 24.04 ships krb5
# 1.20.1, which predates paChecksum2 — the PKINIT checksum-binding field
# Windows Server 2025's KDC now requires. There is no apt upgrade path on an
# LTS release; see docs/CONTEXT.md. Override to test another build.
KRB5_PREFIX="${KRB5_PREFIX:-${HOME}/vms/krb5-1.22}"

EVIDENCE_DIR="${EVIDENCE_DIR:-${HOME}/vms/lab-evidence}"

TEST_USER="pkinittest"

die() {
	echo "error: $*" >&2
	exit 1
}

usage() {
	echo "usage: $(basename "$0") <row A-G> [--no-setup]" >&2
	exit 2
}

[[ $# -ge 1 ]] || usage
ROW="${1^^}"
shift
SETUP=1
while [[ $# -gt 0 ]]; do
	case "$1" in
	--no-setup) SETUP=0 ;;
	*) usage ;;
	esac
	shift
done

# --- the matrix -----------------------------------------------------------
# NTAUTH is the set published to NTAuthCertificates for this row; LEAF is the
# client cert presented. Keep in lockstep with README.md's table — I2 stands
# in for a rotated SPIRE CA and is never published to NTAuth in any row.
#
# EXPECT records only what the two control rows must do. The four real
# question rows are deliberately blank: this experiment exists because their
# answers are unknown, and writing a guess here would invite reading the
# guess back out as a result.
case "${ROW}" in
A) NTAUTH="i1"; LEAF="leaf-i1"; EXPECT="pass (baseline control — the rig itself)" ;;
B) NTAUTH="root-ca"; LEAF="leaf-i1"; EXPECT="" ;;
# Row C is the negative control: NTAuth must contain NEITHER R nor I1.
# README.md words that as "neither", which an empty NTAuth would satisfy —
# but AD will not give us one: cACertificate is in systemMustContain for the
# certificationAuthority class, so it cannot be cleared, only replaced or the
# whole object deleted. We use I2 instead: a real CA that is genuinely absent
# from leaf-i1's chain (leaf-i1 -> I1 -> R). That satisfies "neither", needs
# no new material, and is a STRONGER control than empty would be — it proves
# the KDC checks which CA is in NTAuth, not merely whether NTAuth is
# populated at all. Recorded as a deliberate substitution, not a deviation.
C) NTAUTH="i2"; LEAF="leaf-i1"; EXPECT="fail (negative control — if this passes, the rig proves nothing)" ;;
D) NTAUTH="root-ca i1"; LEAF="leaf-i1"; EXPECT="" ;;
E) NTAUTH="root-ca"; LEAF="leaf-i2"; EXPECT="" ;;
F) NTAUTH="i1"; LEAF="leaf-i2"; EXPECT="" ;;
# Row G is not in README.md's original six. It closes a real gap in them:
# rows E and F both rest on leaf-i2, and both failed with 0x3E (client not
# trusted). 0x3E is a trust failure rather than 0x4B (name mismatch), but it
# does not by itself prove leaf-i2 is otherwise sound — the KDC may evaluate
# trust before mapping and never reach the mapping at all. Without a row
# where leaf-i2 SUCCEEDS, "E and F failed because of NTAuth" is not
# separable from "leaf-i2 is broken". G is the I2 mirror of row A.
G) NTAUTH="i2"; LEAF="leaf-i2"; EXPECT="pass (baseline control for I2 — without it, rows E/F cannot be attributed to NTAuth)" ;;
*) die "unknown row '${ROW}' (expected A-G)" ;;
esac

# --- preflight ------------------------------------------------------------
[[ -x ${RUN_PS} ]] || die "${RUN_PS} missing or not executable"

KINIT="${KRB5_PREFIX}/bin/kinit"
KLIST="${KRB5_PREFIX}/bin/klist"
KDESTROY="${KRB5_PREFIX}/bin/kdestroy"
if [[ ! -x ${KINIT} ]]; then
	die "no kinit at ${KINIT}
The stock Ubuntu krb5 (1.20.1) cannot do PKINIT against Windows Server 2025 —
it lacks paChecksum2. Build 1.22.x into that prefix first; see docs/CONTEXT.md."
fi

# A krb5 built without OpenSSL configures and installs happily but silently
# omits PKINIT entirely, and only fails at -X time with a confusing error.
# Catch that here rather than three steps into a row.
[[ -e ${KRB5_PREFIX}/lib/krb5/plugins/preauth/pkinit.so ]] ||
	die "krb5 at ${KRB5_PREFIX} has no PKINIT plugin (pkinit.so).
It was almost certainly configured without OpenSSL headers — configure prints
'Disabling PKINIT support' and still exits 0. Install libssl-dev and bison,
re-run configure, and check the log for 'Disabling PKINIT' before rebuilding."

LEAF_DIR="${PKI_DIR}/${LEAF}"
LEAF_CRT="${LEAF_DIR}/${LEAF}.crt"
LEAF_KEY="${LEAF_DIR}/${LEAF}.key"
[[ -f ${LEAF_CRT} ]] || die "leaf cert missing: ${LEAF_CRT}"
[[ -f ${LEAF_KEY} ]] || die "leaf key missing: ${LEAF_KEY}"

[[ -f ${HERE}/krb5.conf.in ]] || die "${HERE}/krb5.conf.in missing"

# krb5.conf takes absolute paths and does no variable expansion, so the
# committed file is a template and the effective config is rendered per run
# with this operator's PKI_DIR substituted in. Keeps a machine-specific
# absolute path out of the repository.
KRB5_CONF="${PKI_DIR}/krb5.conf"
sed "s|@PKI_DIR@|${PKI_DIR}|g" "${HERE}/krb5.conf.in" >"${KRB5_CONF}"

mkdir -p "${EVIDENCE_DIR}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="${EVIDENCE_DIR}/row-${ROW}-${STAMP}.txt"

# Base DN for the AD config partition, derived rather than hardcoded.
BASE_DN="$(echo "${LAB_DOMAIN}" | sed 's/\./,DC=/g; s/^/DC=/')"
NTAUTH_DN="CN=NTAuthCertificates,CN=Public Key Services,CN=Services,CN=Configuration,${BASE_DN}"

# Everything below tees into the transcript.
exec > >(tee "${OUT}") 2>&1

echo "=========================================================================="
echo " NTAuth chaining matrix — row ${ROW}"
echo "=========================================================================="
echo "run at        : ${STAMP} (UTC)"
echo "host          : $(hostname)"
echo "NTAuth state  : {${NTAUTH:-empty}}"
echo "leaf          : ${LEAF}"
echo "principal     : ${TEST_USER}@${LAB_REALM}"
echo "krb5 client   : ${KRB5_PREFIX}"
echo "krb5 version  : $("${KLIST}" -V 2>&1 | head -1 || echo unknown)"
[[ -n ${EXPECT} ]] && echo "control        : must ${EXPECT}"
echo
echo "CAVEAT: revocation checking is deliberately relaxed on this KDC"
echo "(UseCachedCRLOnlyAndIgnoreRevocationUnknownErrors=1) because the lab's"
echo "leaf certs carry no CDP — this project's own unsolved Gate 1 gap. Every"
echo "row's result carries that caveat. It is bypassed, not closed."
echo

# --- 1. set the row's NTAuth state ---------------------------------------
if [[ ${SETUP} -eq 1 ]]; then
	echo "--- setting NTAuth to {${NTAUTH:-empty}} ------------------------------"
	PUBLISH_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	# Set the whole attribute in one atomic -Replace rather than
	# clear-then-add. Two reasons:
	#   1. -Clear cannot work: cACertificate is systemMustContain on the
	#      certificationAuthority class, so AD rejects it with "A required
	#      attribute is missing".
	#   2. certutil -dspublish only ADDS, so without a clear the row's state
	#      would be the previous row's plus this one's — silently wrong, and
	#      wrong in the direction that makes rows pass.
	# Verified: -Replace removals do propagate to the KDC's local cached
	# store after -pulse, not just additions.
	# Build the value list with '+= ,(...)'. The unary comma is load-bearing:
	# a bare @($derBytes) flattens the byte[] into ~1000 single-byte values
	# and AD rejects the write with "The specified value already exists"
	# (error 8323) once two of those bytes collide.
	PS_SETUP="\$ErrorActionPreference='Stop'
\$vals = @()
"
	for c in ${NTAUTH}; do
		PS_SETUP+="\$vals += ,([System.Security.Cryptography.X509Certificates.X509Certificate2]::new('C:\\pki\\${c}.crt').RawData)
"
	done
	PS_SETUP+="Set-ADObject -Identity '${NTAUTH_DN}' -Replace @{cACertificate=\$vals}
\"NTAuth cACertificate replaced with \$(\$vals.Count) entry(ies)\"
"
	# The local NTAuth store is a cached copy of the AD attribute and
	# refreshes on its own schedule; -pulse forces it now so the row tests
	# NTAuth membership rather than cache timing. See docs/CONTEXT.md — the
	# unforced propagation delay is a separate measurement, not yet taken.
	PS_SETUP+="certutil -pulse
"
	"${RUN_PS}" "${PS_SETUP}" 120
	PUBLISH_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	echo
	echo "published at : ${PUBLISH_START} -> ${PUBLISH_END} (certutil -pulse forced)"
	echo
else
	echo "--- NTAuth setup SKIPPED (--no-setup) --------------------------------"
	echo "Testing against whatever NTAuth currently holds. The 'NTAuth state'"
	echo "line above is the row's nominal state, NOT a verified fact — read the"
	echo "actual contents below."
	echo
fi

# --- 2. record the KDC-side preconditions --------------------------------
echo "--- KDC preconditions ------------------------------------------------"
"${RUN_PS}" '
"## OS build"
[System.Environment]::OSVersion.Version.ToString()
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DisplayVersion
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").UBR
"## last patch"
(Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 1 | ForEach-Object { "$($_.HotFixID) $($_.InstalledOn)" })
"## StrongCertificateBindingEnforcement (as actually read)"
$v = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name StrongCertificateBindingEnforcement -ErrorAction SilentlyContinue).StrongCertificateBindingEnforcement
if ($null -eq $v) { "not set (registry value absent; key stopped being honoured 2025-09-09 — DC is in full enforcement)" } else { $v }
"## UseCachedCRLOnlyAndIgnoreRevocationUnknownErrors"
(Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc" -Name UseCachedCRLOnlyAndIgnoreRevocationUnknownErrors -ErrorAction SilentlyContinue).UseCachedCRLOnlyAndIgnoreRevocationUnknownErrors
"## KDC service"
(Get-Service kdc).Status
"## altSecurityIdentities on the test account"
(Get-ADUser -Identity '"${TEST_USER}"' -Properties altSecurityIdentities).altSecurityIdentities
' 120
echo

# --- 3. prove NTAuth contains exactly what the row claims ----------------
echo "--- NTAuth contents, as the KDC sees them ----------------------------"
echo "(AD attribute and local cache shown separately — they are different"
echo " things and can disagree; that disagreement is itself a finding.)"
echo
"${RUN_PS}" '
"## AD attribute (authoritative)"
$o = Get-ADObject -Identity "'"${NTAUTH_DN}"'" -Properties cACertificate -ErrorAction SilentlyContinue
if ($null -eq $o) { "NTAuthCertificates object does not exist" }
elseif ($null -eq $o.cACertificate) { "cACertificate: EMPTY" }
else {
  "cACertificate: $($o.cACertificate.Count) entry(ies)"
  foreach ($b in $o.cACertificate) {
    $c = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$b)
    "  $($c.Subject)  sha1=$($c.Thumbprint)"
  }
}
"## local enterprise NTAuth cache"
certutil -store -enterprise NTAuth 2>&1 | Select-String -Pattern "Subject:|Cert Hash|Cannot|CertUtil"
' 120
echo

# --- 4. the actual PKINIT attempt ----------------------------------------
echo "--- kinit ------------------------------------------------------------"
KINIT_START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "started at : ${KINIT_START}"
echo
echo "\$ KRB5_CONFIG=${KRB5_CONF} \\"
echo "  KRB5_TRACE=/dev/stderr ${KINIT} \\"
echo "    -X X509_user_identity=FILE:${LEAF_CRT},${LEAF_KEY} \\"
echo "    ${TEST_USER}@${LAB_REALM}"
echo

export KRB5_CONFIG="${KRB5_CONF}"
export LD_LIBRARY_PATH="${KRB5_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
"${KDESTROY}" 2>/dev/null || true

set +e
KRB5_TRACE=/dev/stderr "${KINIT}" \
	-X X509_user_identity="FILE:${LEAF_CRT},${LEAF_KEY}" \
	"${TEST_USER}@${LAB_REALM}" 2>&1
KINIT_RC=$?
set -e
KINIT_END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo
echo "kinit exit code : ${KINIT_RC}"
echo "finished at     : ${KINIT_END}"
echo

if [[ ${KINIT_RC} -eq 0 ]]; then
	echo "--- klist (TGT obtained) ---------------------------------------------"
	"${KLIST}" 2>&1 || true
	echo
	echo "NOTE: a TGT is not proof that downstream service authorization works."
	echo "It proves the KDC accepted this certificate for this account."
fi

# --- 5. the KDC's side of the same event ---------------------------------
echo "--- KDC-side events --------------------------------------------------"
"${RUN_PS}" '
"## Security log 4768 (Kerberos TGT request), last 5 minutes"
$since = (Get-Date).AddMinutes(-5)
try {
  Get-WinEvent -FilterHashtable @{LogName="Security"; Id=4768; StartTime=$since} -ErrorAction Stop |
    Select-Object -First 5 | ForEach-Object {
      "--- $($_.TimeCreated) ---"
      $_.Message -split "`n" | Select-String -Pattern "Account Name|User ID|Result Code|Certificate" | ForEach-Object { $_.Line.Trim() }
    }
} catch { "no 4768 events in window" }
"## Kerberos-Key-Distribution-Center/Operational, last 5 minutes"
try {
  Get-WinEvent -FilterHashtable @{LogName="Microsoft-Windows-Kerberos-Key-Distribution-Center/Operational"; StartTime=$since} -ErrorAction Stop |
    Select-Object -First 10 | ForEach-Object { "[$($_.TimeCreated)] Id=$($_.Id) $($_.Message)" }
} catch { "no KDC operational events in window" }
' 150

echo
echo "=========================================================================="
echo " row ${ROW}: kinit exit ${KINIT_RC} — $([[ ${KINIT_RC} -eq 0 ]] && echo 'TGT OBTAINED' || echo 'NO TGT')"
[[ -n ${EXPECT} ]] && echo " control row — must ${EXPECT}"
echo " transcript: ${OUT}"
echo "=========================================================================="
