#!/bin/bash
# Copy a local file into the pkinit-dc01 guest via qemu-guest-agent
# (guest-file-open/write/close) — no CD-ROM attach/eject required.
#
# Usage:
#   push-file.sh <local_path> <guest_path> [chunk_bytes]
#
# Example:
#   push-file.sh ~/vms/pki/kdc/kdc.pfx 'C:\Users\Administrator\kdc.pfx'
#
# See ../SKILL.md for the full procedure and gotchas.

set -euo pipefail

DOM="${PKINIT_DC_DOMAIN:-pkinit-dc01}"
LOCAL="${1:?usage: push-file.sh <local_path> <guest_path> [chunk_bytes]}"
GUEST="${2:?usage: push-file.sh <local_path> <guest_path> [chunk_bytes]}"
CHUNK="${3:-32768}"

[ -f "$LOCAL" ] || { echo "push-file.sh: local file not found: $LOCAL" >&2; exit 1; }

USE_SG=1
if virsh -c qemu:///system list --all >/dev/null 2>&1; then
  USE_SG=0
fi

qga_cmd() {
  local json="$1"
  if [ "$USE_SG" = "1" ]; then
    sg libvirt -c "virsh -c qemu:///system qemu-agent-command $DOM '$json'"
  else
    virsh -c qemu:///system qemu-agent-command "$DOM" "$json"
  fi
}

# Windows paths carry backslashes; JSON needs them doubled.
GUEST_ESC=$(printf '%s' "$GUEST" | sed 's/\\/\\\\/g; s/"/\\"/g')

OPEN_JSON="{\"execute\":\"guest-file-open\",\"arguments\":{\"path\":\"$GUEST_ESC\",\"mode\":\"wb\"}}"
OPEN_RESULT=$(qga_cmd "$OPEN_JSON") || { echo "guest-file-open failed: $OPEN_RESULT" >&2; exit 1; }
HANDLE=$(echo "$OPEN_RESULT" | grep -o '"return":[0-9]*' | grep -o '[0-9]*$')
[ -n "$HANDLE" ] || { echo "push-file.sh: could not parse file handle: $OPEN_RESULT" >&2; exit 1; }

close_handle() {
  qga_cmd "{\"execute\":\"guest-file-close\",\"arguments\":{\"handle\":$HANDLE}}" >/dev/null 2>&1 || true
}

SIZE=$(stat -c%s "$LOCAL")
OFFSET=0
while [ "$OFFSET" -lt "$SIZE" ]; do
  B64=$(dd if="$LOCAL" bs="$CHUNK" skip=$((OFFSET / CHUNK)) count=1 2>/dev/null | base64 -w0)
  WRITE_JSON="{\"execute\":\"guest-file-write\",\"arguments\":{\"handle\":$HANDLE,\"buf-b64\":\"$B64\"}}"
  if ! qga_cmd "$WRITE_JSON" >/dev/null; then
    close_handle
    echo "push-file.sh: guest-file-write failed at offset $OFFSET" >&2
    exit 1
  fi
  OFFSET=$((OFFSET + CHUNK))
done

close_handle
echo "push-file.sh: wrote $SIZE bytes to $GUEST on $DOM"
