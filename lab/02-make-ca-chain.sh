#!/usr/bin/env bash
# Build the openssl CA chain for the NTAuth chaining experiment: a root R,
# two intermediates I1 and I2, a KDC certificate for the DC, and one PKINIT
# client leaf per intermediate. See lab/README.md, "Test matrix" — I2 stands
# in for a rotated SPIRE CA and must never be published to NTAuth.
#
#   lab/02-make-ca-chain.sh
#
# Everything lands under ~/vms/pki, never in the repo tree. Refuses to run if
# that directory already exists, since silently regenerating it would
# invalidate trust already published into NTAuth/AD without saying so —
# remove it yourself first if you want a clean rebuild.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab.env
source "${HERE}/lab.env"

die() {
	echo "error: $*" >&2
	exit 1
}

command -v openssl >/dev/null || die "openssl missing"
[[ -e ${PKI_DIR} ]] && die "${PKI_DIR} already exists; remove it first for a clean rebuild"

mkdir -p "${PKI_DIR}"/{root,intermediate1,intermediate2,kdc,leaf-i1,leaf-i2,ext}
chmod 0700 "${PKI_DIR}"

# --- shared extension profiles --------------------------------------------
# pathlen:0 on the intermediates means they can issue leaf certs but not
# further sub-CAs; pathlen:1 on the root allows exactly the one tier under it.
cat >"${PKI_DIR}/ext/intermediate.cnf" <<'EOF'
basicConstraints=critical,CA:true,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer:always
EOF

# clientAuth (1.3.6.1.5.5.7.3.2) only, deliberately: the test account maps by
# altSecurityIdentities (see README, "The confounder"), not by any SAN on
# this cert, so no UPN/SPIFFE-shaped SAN is added here either — the fewer
# moving parts, the more the six-row matrix isolates NTAuth as the variable.
cat >"${PKI_DIR}/ext/leaf.cnf" <<'EOF'
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer:always
EOF

# --- root R -----------------------------------------------------------------
echo "generating root CA (R) ..."
openssl genrsa -out "${PKI_DIR}/root/root-ca.key" 4096 2>/dev/null
openssl req -x509 -new -key "${PKI_DIR}/root/root-ca.key" \
	-sha256 -days 7300 \
	-subj "/CN=PKINIT Lab Root CA/O=PKINIT Lab" \
	-addext "basicConstraints=critical,CA:true,pathlen:1" \
	-addext "keyUsage=critical,keyCertSign,cRLSign" \
	-addext "subjectKeyIdentifier=hash" \
	-out "${PKI_DIR}/root/root-ca.crt"

# --- intermediates I1, I2 ----------------------------------------------------
for n in 1 2; do
	dir="${PKI_DIR}/intermediate${n}"
	echo "generating intermediate CA (I${n}) ..."
	openssl genrsa -out "${dir}/i${n}.key" 4096 2>/dev/null
	openssl req -new -key "${dir}/i${n}.key" \
		-subj "/CN=PKINIT Lab Intermediate CA ${n}/O=PKINIT Lab" \
		-out "${dir}/i${n}.csr"
	openssl x509 -req -in "${dir}/i${n}.csr" \
		-CA "${PKI_DIR}/root/root-ca.crt" -CAkey "${PKI_DIR}/root/root-ca.key" \
		-CAcreateserial -sha256 -days 3650 \
		-extfile "${PKI_DIR}/ext/intermediate.cnf" \
		-out "${dir}/i${n}.crt"
	cat "${dir}/i${n}.crt" "${PKI_DIR}/root/root-ca.crt" >"${dir}/i${n}-chain.pem"
	openssl verify -CAfile "${PKI_DIR}/root/root-ca.crt" "${dir}/i${n}.crt" >/dev/null ||
		die "I${n} does not chain to R"
done

# --- KDC certificate, issued by I1 -------------------------------------------
echo "generating KDC certificate for ${DC_FQDN} (issued by I1) ..."
cat >"${PKI_DIR}/ext/kdc.cnf" <<EOF
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=1.3.6.1.5.2.3.5
subjectAltName=DNS:${DC_FQDN}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always,issuer:always
EOF
openssl genrsa -out "${PKI_DIR}/kdc/kdc.key" 2048 2>/dev/null
openssl req -new -key "${PKI_DIR}/kdc/kdc.key" \
	-subj "/CN=${DC_FQDN}/O=PKINIT Lab" \
	-out "${PKI_DIR}/kdc/kdc.csr"
openssl x509 -req -in "${PKI_DIR}/kdc/kdc.csr" \
	-CA "${PKI_DIR}/intermediate1/i1.crt" -CAkey "${PKI_DIR}/intermediate1/i1.key" \
	-CAcreateserial -sha256 -days 730 \
	-extfile "${PKI_DIR}/ext/kdc.cnf" \
	-out "${PKI_DIR}/kdc/kdc.crt"
cat "${PKI_DIR}/kdc/kdc.crt" "${PKI_DIR}/intermediate1/i1.crt" "${PKI_DIR}/root/root-ca.crt" \
	>"${PKI_DIR}/kdc/kdc-chain.pem"
openssl verify -CAfile "${PKI_DIR}/root/root-ca.crt" -untrusted "${PKI_DIR}/intermediate1/i1.crt" \
	"${PKI_DIR}/kdc/kdc.crt" >/dev/null || die "KDC cert does not chain to R"

PFX_PASSWORD="$(openssl rand -base64 18)"
openssl pkcs12 -export \
	-in "${PKI_DIR}/kdc/kdc.crt" -inkey "${PKI_DIR}/kdc/kdc.key" \
	-certfile <(cat "${PKI_DIR}/intermediate1/i1.crt" "${PKI_DIR}/root/root-ca.crt") \
	-name "${DC_FQDN}" \
	-passout "pass:${PFX_PASSWORD}" \
	-out "${PKI_DIR}/kdc/kdc.pfx"

# --- leaf certs, one per intermediate ----------------------------------------
make_leaf() {
	local n="$1" issuer_dir="$2" issuer_crt="$3" issuer_key="$4"
	local dir="${PKI_DIR}/leaf-i${n}"
	echo "generating PKINIT client leaf (issued by I${n}) ..."
	openssl genrsa -out "${dir}/leaf-i${n}.key" 2048 2>/dev/null
	openssl req -new -key "${dir}/leaf-i${n}.key" \
		-subj "/CN=PKINIT Test Leaf (I${n})/O=PKINIT Lab" \
		-out "${dir}/leaf-i${n}.csr"
	openssl x509 -req -in "${dir}/leaf-i${n}.csr" \
		-CA "${issuer_crt}" -CAkey "${issuer_key}" \
		-CAcreateserial -sha256 -days 90 \
		-extfile "${PKI_DIR}/ext/leaf.cnf" \
		-out "${dir}/leaf-i${n}.crt"
	openssl verify -CAfile "${PKI_DIR}/root/root-ca.crt" -untrusted "${issuer_crt}" \
		"${dir}/leaf-i${n}.crt" >/dev/null || die "leaf-i${n} does not chain to R"
}
make_leaf 1 "${PKI_DIR}/intermediate1" "${PKI_DIR}/intermediate1/i1.crt" "${PKI_DIR}/intermediate1/i1.key"
make_leaf 2 "${PKI_DIR}/intermediate2" "${PKI_DIR}/intermediate2/i2.crt" "${PKI_DIR}/intermediate2/i2.key"

chmod 0600 "${PKI_DIR}"/*/*.key "${PKI_DIR}/kdc/kdc.pfx"

cat <<EOF

Chain built and verified under ${PKI_DIR}:

  root/root-ca.crt                 R, self-signed, 20y
  intermediate1/i1.crt              I1, signed by R, 10y
  intermediate2/i2.crt              I2, signed by R, 10y (never publish to NTAuth)
  kdc/kdc.crt + kdc.pfx             ${DC_FQDN}, issued by I1, 2y
  leaf-i1/leaf-i1.crt + .key        PKINIT test leaf, issued by I1, 90d
  leaf-i2/leaf-i2.crt + .key        PKINIT test leaf, issued by I2, 90d

KDC PFX export password (one-time use for Import-PfxCertificate on the DC,
not stored anywhere): ${PFX_PASSWORD}

Leaf issuer/serial, for the altSecurityIdentities mapping you'll set on the
test account per row:

EOF
for n in 1 2; do
	echo "  leaf-i${n}:"
	openssl x509 -in "${PKI_DIR}/leaf-i${n}/leaf-i${n}.crt" -noout -issuer -serial | sed 's/^/    /'
done

cat <<EOF

Next: lab/README.md, "Build order" step 6 onward — publish R (and per-row I1)
into the appropriate AD stores, import kdc.pfx on the DC, then run the matrix.
EOF
