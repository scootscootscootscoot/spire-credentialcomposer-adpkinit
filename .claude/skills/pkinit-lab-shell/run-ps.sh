#!/bin/bash
# Run a PowerShell command inside the pkinit-dc01 guest via qemu-guest-agent,
# and print its stdout/stderr/exit code back to the host terminal.
#
# Usage:
#   run-ps.sh '<powershell command>' [timeout_seconds]
#
# Example:
#   run-ps.sh 'Get-ADUser -Identity pkinittest -Properties altSecurityIdentities'
#   run-ps.sh 'whoami'
#
# See ../SKILL.md for the full procedure, gotchas, and how this was set up.

set -euo pipefail

DOM="${PKINIT_DC_DOMAIN:-pkinit-dc01}"
CMD="${1:?usage: run-ps.sh '<powershell command>' [timeout_seconds]}"
TIMEOUT="${2:-30}"

# Prefer plain virsh (works in shells created after lab/00-host-setup.sh granted
# the libvirt group). Fall back to `sg libvirt -c` for older/pre-existing shells.
# NOTE: the sg path re-parses its argument through a nested shell, so the JSON
# payload must be single-quoted *within that string* rather than passed as a
# separate argv element (which would silently lose its embedded double quotes).
USE_SG=1
if virsh -c qemu:///system list --all >/dev/null 2>&1; then
  USE_SG=0
fi

qga_cmd() {
  # $1 = JSON payload (must not itself contain single-quote characters;
  # true for every payload this script builds, since values are base64/int).
  local json="$1"
  if [ "$USE_SG" = "1" ]; then
    sg libvirt -c "virsh -c qemu:///system qemu-agent-command $DOM '$json'"
  else
    virsh -c qemu:///system qemu-agent-command "$DOM" "$json"
  fi
}

# Prepend ProgressPreference silencing: module-load / cmdlet progress records
# otherwise leak into the captured stderr stream as CLIXML noise and can make
# an otherwise-successful command look like it failed.
FULL_CMD="\$ProgressPreference='SilentlyContinue'; ${CMD}"

# PowerShell -EncodedCommand requires base64 of UTF-16LE, not UTF-8.
CMD_B64=$(printf '%s' "$FULL_CMD" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)

ARGS_JSON="[\"-NoProfile\",\"-NonInteractive\",\"-EncodedCommand\",\"$CMD_B64\"]"

EXEC_JSON="{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"powershell.exe\",\"arg\":$ARGS_JSON,\"capture-output\":true}}"
EXEC_RESULT=$(qga_cmd "$EXEC_JSON" 2>&1) \
  || { echo "guest-exec failed to launch: $EXEC_RESULT" >&2; exit 1; }

PID=$(echo "$EXEC_RESULT" | grep -o '"pid":[0-9]*' | grep -o '[0-9]*' || true)
if [ -z "$PID" ]; then
  echo "Could not parse pid from guest-exec response: $EXEC_RESULT" >&2
  exit 1
fi

STATUS=""
STATUS_JSON="{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$PID}}"
for ((i = 0; i < TIMEOUT; i++)); do
  STATUS=$(qga_cmd "$STATUS_JSON" 2>&1)
  if echo "$STATUS" | grep -q '"exited":true'; then
    break
  fi
  sleep 1
done

if ! echo "$STATUS" | grep -q '"exited":true'; then
  echo "Command did not exit within ${TIMEOUT}s (pid $PID still running in guest)." >&2
  echo "Last status: $STATUS" >&2
  exit 1
fi

python3 - "$STATUS" <<'PYEOF'
import json, sys, base64

status = json.loads(sys.argv[1])
r = status["return"]
exitcode = r.get("exitcode")
out = r.get("out-data", "")
err = r.get("err-data", "")
truncated = r.get("out-truncated") or r.get("err-truncated")

if out:
    sys.stdout.write(base64.b64decode(out).decode("utf-8", errors="replace"))
if err:
    sys.stderr.write(base64.b64decode(err).decode("utf-8", errors="replace"))
if truncated:
    sys.stderr.write("\n[run-ps.sh] warning: output was truncated by qemu-ga\n")

sys.exit(exitcode if isinstance(exitcode, int) else 1)
PYEOF
