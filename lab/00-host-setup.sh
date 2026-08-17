#!/usr/bin/env bash
# Host preparation for the phase-4 lab. Run once, on labhost.
#
# This is the only step that needs root. Everything after it runs as the lab operator.
#
#   sudo lab/00-host-setup.sh
#
# Installs KVM/libvirt, a PKINIT-capable Kerberos client, and starts the
# default NAT network (virbr0, 192.168.122.0/24) that the DC will live on.

set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
	echo "must run as root: sudo $0" >&2
	exit 1
fi

# The invoking user, not root — that is who needs libvirt access.
TARGET_USER="${SUDO_USER:-}"
if [[ -z ${TARGET_USER} ]]; then
	echo "SUDO_USER unset; run via sudo from your normal account" >&2
	exit 1
fi

# krb5-user asks for a default realm via debconf. We never use the system
# krb5.conf — the lab passes KRB5_CONFIG explicitly — so take the defaults.
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
	qemu-system-x86 \
	qemu-system-modules-spice \
	qemu-utils \
	libvirt-daemon-system \
	libvirt-clients \
	virtinst \
	virt-manager \
	virt-viewer \
	krb5-user \
	krb5-pkinit \
	acl

systemctl enable --now libvirtd

# qemu runs as libvirt-qemu and cannot traverse /home/labop (mode 0750), so
# disks and ISOs live in the default pool. Grant the lab operator write access
# there rather than requiring sudo for every image operation.
setfacl -m "u:${TARGET_USER}:rwx" /var/lib/libvirt/images

# The default NAT network is what puts the DC on a subnet the host can reach
# directly. Ships defined but not always started on a fresh install.
virsh net-info default >/dev/null 2>&1 || {
	echo "libvirt 'default' network is missing; unexpected on Ubuntu" >&2
	exit 1
}
virsh net-start default 2>/dev/null || true
virsh net-autostart default

usermod -aG libvirt,kvm "${TARGET_USER}"

echo
echo "Host prepared."
echo
echo "Group membership was added but does not apply to already-running shells."
echo "Either open a new terminal, or prefix commands with: sg libvirt -c '...'"
echo
virsh net-info default | sed 's/^/  /'
