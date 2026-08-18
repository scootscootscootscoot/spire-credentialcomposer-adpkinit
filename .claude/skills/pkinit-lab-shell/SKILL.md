---
name: pkinit-lab-shell
description: Run PowerShell/cmd commands inside the pkinit-dc01 lab VM directly from the host, and get output back — no SPICE clipboard paste required. Use whenever a task needs to inspect or change state on pkinit-dc01 (registry, AD objects, services, files, etc).
---

# pkinit-lab-shell

Remote-execution channel from the lab host into the `pkinit-dc01` Windows
guest, via `qemu-guest-agent`. Replaces the old workflow of pasting PowerShell
into a SPICE console window (`virt-viewer`), which silently corrupts any single
logical line longer than the console's visual width (the pasted text gets a
literal newline inserted at the wrap column, which PowerShell treats as Enter,
breaking parameter binding — short lines and syntactically-open continuations
survive, long single-line commands don't).

## Quick start

```
.claude/skills/pkinit-lab-shell/run-ps.sh '<powershell command>' [timeout_seconds]
.claude/skills/pkinit-lab-shell/push-file.sh <local_path> <guest_path> [chunk_bytes]
```

Examples:

```
.claude/skills/pkinit-lab-shell/run-ps.sh 'whoami'
.claude/skills/pkinit-lab-shell/run-ps.sh '$PSVersionTable.PSVersion'
.claude/skills/pkinit-lab-shell/run-ps.sh 'Get-ADUser -Identity pkinittest -Properties altSecurityIdentities'
.claude/skills/pkinit-lab-shell/run-ps.sh "Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Kdc' -Name StrongCertificateBindingEnforcement -ErrorAction SilentlyContinue"

.claude/skills/pkinit-lab-shell/push-file.sh ~/vms/pki/kdc/kdc.pfx 'C:\Users\Administrator\kdc.pfx'
```

`run-ps.sh` prints the command's stdout to stdout, stderr to stderr, and exits
with the guest process's own exit code. This works for arbitrarily long single
logical lines — the command travels as base64 over the guest-agent channel,
never through the console/clipboard, so there is no line-wrapping hazard at
all.

`push-file.sh` copies a local file into the guest in chunks (default 32 KiB)
via `guest-file-open`/`guest-file-write`/`guest-file-close` — no CD-ROM
attach/eject cycle needed. Verified against `kdc.pfx` (6066 bytes, single
chunk) with a SHA-256 hash match between host and guest. Only push (host →
guest) is implemented; add a symmetric `pull-file.sh` (`guest-file-read`) if a
future task needs to pull something back out, e.g. an ADCS-issued fixture cert
for Gate 2.

Both scripts target `pkinit-dc01` by default; override with
`PKINIT_DC_DOMAIN` if ever pointed at a different domain name.

## How it works

`pkinit-dc01` has `spice-guest-tools` installed (bundles `qemu-guest-agent`,
`spice-vdagent`, and Windows virtio drivers), which gives the VM a
`org.qemu.guest_agent.0` virtio-serial channel that `libvirt`/`qemu` can talk to
directly on the host — no network, no firewall rules, no credentials. The agent
runs as the `qemu-ga` Windows service under `NT AUTHORITY\SYSTEM`, so every
command runs with full local admin rights on the guest.

`run-ps.sh`:
1. Prepends `$ProgressPreference='SilentlyContinue';` to the command (see
   Gotchas below).
2. Base64-encodes the command as **UTF-16LE** (required by PowerShell's
   `-EncodedCommand`) and calls
   `powershell.exe -NoProfile -NonInteractive -EncodedCommand <b64>` via the
   guest agent's `guest-exec` RPC with `capture-output: true`.
3. Polls `guest-exec-status` with the returned pid (1s interval) until
   `exited: true`, up to `timeout_seconds` (default 30).
4. Base64-decodes `out-data`/`err-data` and prints them, exiting with the
   guest process's `exitcode`.

### Raw command pattern (if you need to bypass the script)

```bash
# Liveness check
virsh -c qemu:///system qemu-agent-command pkinit-dc01 '{"execute":"guest-ping"}'

# Launch (arg list is argv for powershell.exe; -EncodedCommand value is
# base64 of the command string encoded as UTF-16LE)
virsh -c qemu:///system qemu-agent-command pkinit-dc01 \
  '{"execute":"guest-exec","arguments":{"path":"powershell.exe","arg":["-NoProfile","-NonInteractive","-EncodedCommand","<BASE64>"],"capture-output":true}}'
# => {"return":{"pid":1234}}

# Poll (repeat until "exited":true)
virsh -c qemu:///system qemu-agent-command pkinit-dc01 \
  '{"execute":"guest-exec-status","arguments":{"pid":1234}}'
# => {"return":{"exitcode":0,"out-data":"<BASE64>","exited":true}}
```

`out-data`/`err-data` are base64 of the raw UTF-8 bytes PowerShell wrote to
those streams (not UTF-16, unlike the input encoding).

## Gotchas

- **Shell group membership.** If this is a shell that predates
  `lab/00-host-setup.sh`'s libvirt group grant, plain `virsh` will fail with
  "Permission denied" on the libvirt socket. `run-ps.sh` detects this
  automatically and falls back to `sg libvirt -c '...'`. If working with raw
  `virsh` commands directly, try without the wrapper first; if you get a
  permission error, prefix with `sg libvirt -c '...'` (the whole `virsh...`
  invocation as one quoted string).
- **`sg libvirt -c` re-parses its argument through a nested shell.** If you
  build your own `virsh qemu-agent-command` call under that wrapper, the JSON
  payload must be *single-quoted within the outer double-quoted string*
  (`"virsh ... qemu-agent-command $DOM '$json'"`), not passed as a separate
  shell argument — otherwise the nested shell consumes the JSON's embedded
  double quotes and the call fails with a JSON parse error. `run-ps.sh`
  already handles this; only relevant if bypassing it.
- **`-EncodedCommand` wants UTF-16LE, not UTF-8.** `printf '%s' "$cmd" | iconv -f UTF-8 -t UTF-16LE | base64 -w0`.
- **CLIXML noise on stderr / misleading exit codes.** Without
  `$ProgressPreference='SilentlyContinue'`, module auto-loading progress
  records get serialized as CLIXML (`#< CLIXML ...`) onto the *stderr* stream
  and can produce a non-zero exit code even though the command itself
  succeeded. `run-ps.sh` sets this automatically; if invoking `guest-exec`
  directly, prepend it yourself.
- **Output size.** Not hit in testing, but `qemu-ga` can truncate very large
  captured output; check for an `out-truncated`/`err-truncated` field in the
  `guest-exec-status` response if a command might produce a lot of output.
  `run-ps.sh` warns on stderr if this happens.
- **Timeouts.** `run-ps.sh` polls for up to 30s by default (second argument
  overrides). A long-running command (e.g. a big AD query, a reboot-adjacent
  operation) needs a larger timeout; the guest-side process keeps running
  either way, you're only choosing how long *this script invocation* waits
  before giving up on polling — you can re-poll the same pid manually with the
  raw pattern above if needed (note: qemu-ga only tracks a process's exit
  status until the first successful `guest-exec-status` poll *after* it exits;
  polling before that is safe to repeat).
- **Only PowerShell is wired up** in `run-ps.sh` (`path` is hardcoded to
  `powershell.exe`). For `cmd.exe` or another executable, use the raw pattern
  with a different `path`/`arg` array.
- **`guest-file-write`'s content field is `buf-b64`, not `content`.** Easy
  mistake copying from generic QMP-command examples — this qemu-ga command
  specifically names it `buf-b64`; got a `Parameter 'buf-b64' is missing`
  error the first time `push-file.sh` was written and tested.
- **Windows paths need their backslashes doubled for JSON.** `push-file.sh`
  handles this automatically (`sed 's/\\/\\\\/g'` on the guest path argument);
  only relevant if bypassing the script.
- **This does not require virt-viewer to be open at all.** No SPICE session,
  no clipboard, no focus-stealing. Safe to run while a human has virt-viewer
  open and is looking at the console too — commands appear as ordinary
  PowerShell activity in whatever session is running them (there is no
  separate remote session; `guest-exec` spawns detached processes, they do
  not appear in the interactive console at all).

## Setup history (why this needed one-time repair)

As of 2026-08-13, the domain XML had **no** `org.qemu.guest_agent.0` channel
defined at all (only the SPICE vdagent channel existed). Getting this working
required, in order:

1. Hot-attach the channel (no guest reboot needed — Windows' PnP + the
   already-installed virtio-serial driver picked it up immediately):
   ```
   virsh -c qemu:///system attach-device pkinit-dc01 <device-xml> --live --config
   ```
   with `<device-xml>`:
   ```xml
   <channel type='unix'>
     <target type='virtio' name='org.qemu.guest_agent.0'/>
   </channel>
   ```
   (`--live --config` makes it both immediate and persistent; confirmed
   surviving in `virsh dumpxml pkinit-dc01 --inactive` afterward.)

2. `guest-ping` still failed after this. The `QEMU-GA` Windows service (installed
   long ago by `spice-guest-tools`) existed but was **Stopped** — it likely
   never started because at install time there was no virtio-serial channel
   for it to bind to, and it wasn't set to retry/auto-start. Fixed with
   (typed via `virsh send-key`, see below):
   ```powershell
   Start-Service qemu-ga
   Set-Service qemu-ga -StartupType Automatic
   ```

3. `guest-ping` then worked, but `guest-exec` did not — `guest-info` showed
   agent version `0.12.1`, an ancient build (pre-dates `guest-exec`, added
   around QEMU 2.5). `spice-guest-tools`' bundled agent is stale. Fixed by
   installing the modern agent from the `virtio-win-0.1.285.iso` already
   present in `/var/lib/libvirt/images/` (was already an attached-but-ejected
   CD-ROM device on this VM — re-inserted it):
   ```
   virsh -c qemu:///system change-media pkinit-dc01 sdc --insert /var/lib/libvirt/images/virtio-win-0.1.285.iso --live
   ```
   Then, in the guest (drive letter for the virtio-win ISO was `E:` at the
   time — check with `Get-Volume`/`Get-CimInstance Win32_CDROMDrive`, it can
   vary):
   ```powershell
   Stop-Service qemu-ga -Force
   msiexec /i E:\guest-agent\qemu-ga-x86_64.msi /qn /norestart /l*v C:\qga-install.log
   Start-Service qemu-ga
   ```
   The first install attempt failed silently (`MainEngineThread is returning 2`
   in the log) because the old `qemu-ga.exe` binary was still locked by the
   running service — stopping the service first fixed it. After this,
   `guest-info` reported version `110.0.2` with `guest-exec` in
   `supported_commands`, and the round-trip (`whoami` → `nt authority\system`,
   `$PSVersionTable.PSVersion` → `5.1.26100.33296`) worked.
   Afterward the ISO was ejected again (`change-media sdc --eject --live`) to
   restore the VM to its prior no-media state — the guest agent channel is
   independent of the CD-ROM and keeps working with it ejected.

4. Bootstrapping steps 2–3 (before any working exec channel existed) were done
   by driving the console blind, without SPICE clipboard, via
   `virsh send-key pkinit-dc01 --codeset linux KEY_...` (character-by-character
   keystroke injection into the guest's virtual keyboard — works with no
   viewer window open at all) plus `virsh screenshot pkinit-dc01 <file>` to see
   the result after each step. This is *not* needed going forward now that
   `guest-exec` works — it's recorded here only in case the agent ever regresses
   to disconnected again and needs re-bootstrapping the same way. It is a much
   better bootstrap primitive than SPICE clipboard paste: it types character by
   character with no wrap-column hazard, and needs no GUI viewer.

## If the agent ever stops responding again

Check, in order:
1. `virsh -c qemu:///system qemu-agent-command pkinit-dc01 '{"execute":"guest-ping"}'`
2. Is the channel still in the domain XML? `virsh -c qemu:///system dumpxml pkinit-dc01 | grep -A4 guest_agent`
3. Is the VM even running? `virsh -c qemu:///system list --all`
4. If XML and VM are fine but ping fails, the `qemu-ga` service on the guest
   is probably stopped — needs console access (send-key bootstrap, per above)
   or, if `guest-exec` was working before it stopped responding, it may come
   back on its own after a guest reboot (service is now `Automatic` startup).
