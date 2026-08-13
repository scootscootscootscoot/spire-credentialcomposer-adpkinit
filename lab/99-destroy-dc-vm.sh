#!/usr/bin/env bash
# Tear the lab DC down. Destructive and deliberately noisy about it.
#
#   lab/99-destroy-dc-vm.sh          # prompts
#   lab/99-destroy-dc-vm.sh --yes    # does not
#
# Leaves the install ISOs alone — they are ~6 GB and re-downloading them is the
# slowest part of rebuilding.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab.env
source "${HERE}/lab.env"

if [[ ${1:-} != "--yes" ]]; then
	echo "This destroys VM ${VM_NAME} and its disk ${POOL_DIR}/${VM_NAME}.qcow2."
	echo "The lab AD forest and everything in it goes with it."
	read -r -p "Type the VM name to confirm: " confirm
	[[ ${confirm} == "${VM_NAME}" ]] || {
		echo "aborted"
		exit 1
	}
fi

virsh -c qemu:///system destroy "${VM_NAME}" 2>/dev/null || true
virsh -c qemu:///system undefine "${VM_NAME}" --remove-all-storage 2>/dev/null ||
	virsh -c qemu:///system undefine "${VM_NAME}" 2>/dev/null || true

rm -f "${POOL_DIR}/${VM_NAME}.qcow2"

# Drop the address reservation so a rebuild re-adds it cleanly.
virsh -c qemu:///system net-update default delete ip-dhcp-host \
	"<host mac='${DC_MAC}'/>" --live --config 2>/dev/null || true

echo "Destroyed ${VM_NAME}. Install ISOs kept in ${POOL_DIR}."
