#!/usr/bin/env bash
# Create the lab domain controller VM. Run as your normal user after
# 00-host-setup.sh, from a shell that has libvirt group membership:
#
#   lab/01-create-dc-vm.sh
#   sg libvirt -c lab/01-create-dc-vm.sh    # if you have not re-logged-in yet
#
# Deliberately boring hardware: SATA disk and an e1000e NIC, both of which
# Windows Setup drives with in-box drivers. virtio would be faster and would
# also mean loading storage drivers mid-install for a machine whose entire job
# is to answer one question about NTAuth. The virtio ISO is attached anyway so
# the guest can be converted later without re-downloading it.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab.env
source "${HERE}/lab.env"

die() {
	echo "error: $*" >&2
	exit 1
}

command -v virt-install >/dev/null || die "virt-install missing; run lab/00-host-setup.sh first"
virsh -c qemu:///system version >/dev/null 2>&1 ||
	die "cannot reach qemu:///system — no libvirt group membership in this shell? try: sg libvirt -c $0"

virsh -c qemu:///system dominfo "${VM_NAME}" >/dev/null 2>&1 &&
	die "domain ${VM_NAME} already exists; destroy it first (lab/99-destroy-dc-vm.sh)"

# --- stage the install media into the pool ------------------------------------
# qemu cannot read out of $HOME, so the ISOs have to live in the pool directory.
stage_iso() {
	local iso="$1" required="$2"
	if [[ -f "${POOL_DIR}/${iso}" ]]; then
		chmod 0644 "${POOL_DIR}/${iso}"
		return 0
	fi
	if [[ ! -f "${DOWNLOAD_DIR}/${iso}" ]]; then
		[[ ${required} == required ]] &&
			die "missing ${iso} in both ${POOL_DIR} and ${DOWNLOAD_DIR}"
		return 1
	fi
	echo "staging ${iso} into ${POOL_DIR} ..."
	cp "${DOWNLOAD_DIR}/${iso}" "${POOL_DIR}/${iso}.part"
	mv "${POOL_DIR}/${iso}.part" "${POOL_DIR}/${iso}"
	chmod 0644 "${POOL_DIR}/${iso}"
}

stage_iso "${WINDOWS_ISO}" required
# Nothing in this build needs virtio, so a missing driver ISO is not fatal.
VIRTIO_DISK=()
if stage_iso "${VIRTIO_ISO}" optional; then
	VIRTIO_DISK=(--disk "path=${POOL_DIR}/${VIRTIO_ISO},device=cdrom,bus=sata,readonly=on")
else
	echo "note: ${VIRTIO_ISO} not present; creating the VM without the driver ISO"
fi

# --- pin the DC's address -----------------------------------------------------
# A domain controller needs a predictable address. Reserving it on virbr0 means
# it is correct from first boot, before anyone logs in to set it statically.
if ! virsh -c qemu:///system net-dumpxml default | grep -q "${DC_MAC}"; then
	echo "reserving ${DC_IP} for ${DC_MAC} on the default network ..."
	virsh -c qemu:///system net-update default add ip-dhcp-host \
		"<host mac='${DC_MAC}' name='${DC_NAME}' ip='${DC_IP}'/>" \
		--live --config
fi

# Ask virt-install rather than osinfo-query: the latter lives in libosinfo-bin,
# which --no-install-recommends does not pull in, and its absence would silently
# select the fallback instead of the right variant. The variant only seeds
# defaults we mostly override, so degrading is acceptable — doing so unknowingly
# is not.
OS_VARIANT=""
for candidate in win2k25 win2k22 win2k19; do
	if virt-install --osinfo list 2>/dev/null | grep -qx "${candidate}"; then
		OS_VARIANT="${candidate}"
		break
	fi
done
[[ -n ${OS_VARIANT} ]] || die "no usable Windows os-variant found in the libosinfo database"
echo "using --os-variant ${OS_VARIANT}"

virt-install \
	--connect qemu:///system \
	--name "${VM_NAME}" \
	--vcpus "${VM_VCPUS}" \
	--memory "${VM_MEMORY_MB}" \
	--cpu host-passthrough \
	--os-variant "${OS_VARIANT}" \
	--disk "path=${POOL_DIR}/${VM_NAME}.qcow2,size=${VM_DISK_GB},format=qcow2,bus=sata" \
	--disk "path=${POOL_DIR}/${WINDOWS_ISO},device=cdrom,bus=sata,readonly=on" \
	"${VIRTIO_DISK[@]}" \
	`# --cdrom would pick bus=ide over the sata requirement above; this keeps sata` \
	--install bootdev=cdrom \
	--network "network=default,model=e1000e,mac=${DC_MAC}" \
	--graphics spice,listen=127.0.0.1 \
	--video qxl \
	--boot cdrom,hd \
	--noautoconsole \
	--wait -1 &
# --wait keeps this backgrounded virt-install alive to catch Windows Setup's
# first internal reboot and flip the persistent boot order to hd-only. Without
# it, --noautoconsole returns immediately and libvirt just shuts the domain
# off at that reboot instead of continuing — recoverable with a plain
# `virsh start`, but avoid it going forward.
disown

cat <<EOF

Created ${VM_NAME}. Open the console with:

  virt-viewer --connect qemu:///system ${VM_NAME}

Windows Setup shows a "Press any key to boot from CD" prompt for a few seconds.
Open the console first, then start clicking. If you miss it the VM lands in the
boot manager — just reset it and try again:

  virsh -c qemu:///system reset ${VM_NAME}

Install target: ${DC_FQDN} at ${DC_IP}, domain ${LAB_DOMAIN} (${LAB_NETBIOS}).
Next: lab/README.md, "Building the DC".
EOF
