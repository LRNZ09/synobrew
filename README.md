# synobrew

A small, **auditable** installer for Homebrew (Linuxbrew) on Synology DSM 7.x —
a minimal alternative to heavier setups. It makes the few DSM-specific fixes
Homebrew needs, keeps them alive across reboots via a DSM boot task, and can
repair or migrate an existing install in place.

> **Unofficial / best-effort.** Homebrew does not officially support Synology.
> This runs privileged code on a data-bearing NAS — read the scripts first,
> snapshot/back up before running, and keep your NAS off the public internet.

## Requirements

- Synology NAS on **DSM 7.1+** (7.2+ recommended), **x86_64** (or aarch64 — see below).
- **User Home service** enabled: Control Panel → User & Group → Advanced → User Home.
- **SSH** enabled; log in as a **non-root** user in the `administrators` group (has sudo).
- **git** (Package Center → SynoCommunity), or install it with `brew install git` afterward.

| `uname -m` | Support |
|------------|---------|
| `x86_64` / `amd64` | Supported (full bottles). |
| `aarch64` / `arm64` | Works, but Linux bottles are thin — many formulae build from source and can OOM on low-RAM units. |
| 32-bit (`armv7l`, `i686`, …) | Not supported — the installer refuses. |

## What it changes

- Bind-mounts **only** `/home/linuxbrew` from `~/.tools/synobrew/prefix` (never the whole homes share).
- Writes a `/usr/bin/ldd` shim (Homebrew probes glibc via `ldd`; DSM has none).
- Writes `/etc/os-release` (cosmetic — silences a per-command warning).
- Registers a **DSM boot task** that runs a one-line `mount` command held in DSM's own root-only config (nothing is installed under your home for the root boot task to run), and appends one `brew shellenv` line to your shell rc.
- Existing system files are backed up as `<path>.synobrew.bak-<epoch>` before any overwrite.
- On a **fresh** install (only when Homebrew isn't already present), it downloads and runs Homebrew's official installer via `curl | bash` from `raw.githubusercontent.com/Homebrew/install/HEAD` — this is inherent to Homebrew, not synobrew-specific. That revision is unpinned (`HEAD`); set `SB_BREW_INSTALL_URL` to a specific commit/tag to pin or audit it, and use `--dry-run` to see the action without running it.

## Install

```sh
git clone https://github.com/<you>/synobrew.git
cd synobrew
less install.sh restore.sh lib/common.sh   # review before running
./install.sh                                # add --dry-run to preview, --yes for non-interactive
```

## Make it survive reboots (one manual step)

The bind mount is runtime-only. After install, register the boot task with the
**exact command the installer prints** (a one-line bind mount — no script file):

1. DSM → Control Panel → **Task Scheduler** → Create → **Triggered Task** → User-defined script.
2. **User:** `root`. **Event:** `Boot-up`.
3. **Run command:** paste the printed line, e.g.
   `mkdir -p /home/linuxbrew && mount -o bind '/volume1/homes/<you>/.tools/synobrew/prefix' /home/linuxbrew`

The command lives in DSM's root-only config, so no file under your home runs as
root at boot. It only re-creates the bind mount.

## After reboots vs after DSM updates

- **Reboot:** the boot task re-creates the mount automatically (the `ldd`/`os-release` shims persist across reboots).
- **DSM update:** a major update can wipe `/etc`, `/usr/bin`, and even the Task
  Scheduler entry. If Homebrew looks broken after an update, just re-run
  `./install.sh` — it is idempotent and repairs whatever is missing.

## Repair & migration

`install.sh` is **install-or-repair**. Re-running it detects the current state:

- **Already synobrew-managed** → re-applies any missing shims/mount/shellenv.
- **Prefix backed elsewhere** (e.g. an older whole-homes-share mount, or a plain
  directory) → **migrates** the data into `~/.tools/synobrew/prefix` and re-points
  the mount. Safe because the logical prefix `/home/linuxbrew/.linuxbrew` never
  changes. **Snapshot first**; the old copy is left aside, never deleted.
- **Homebrew at a different prefix** → left untouched (bottles are path-specific);
  the installer offers a fresh standard-prefix install alongside it.

## Uninstall (manual, conservative)

```sh
# 1. Homebrew's own uninstaller (as your user):
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"
# 2. Remove synobrew's shims (restore any *.synobrew.bak-* you want to keep first):
sudo rm -f /usr/bin/ldd /etc/os-release
# 3. Unmount and remove the mount point (only if empty / you created it):
sudo umount /home/linuxbrew && sudo rmdir /home/linuxbrew 2>/dev/null || true
# 4. Delete the Boot-up task in Task Scheduler, then remove the prefix store:
rm -rf ~/.tools/synobrew
# 5. Remove the 'brew shellenv' line from your shell rc (~/.profile, ~/.zshrc, or ~/.config/fish/config.fish).
```

## Safety

`set -euo pipefail`; runs as a non-root user with ordinary `sudo` (no `NOPASSWD`
fragment); idempotent; `--dry-run` previews every privileged action; system files
are backed up before overwrite. Prefer **clone → read → run** over piping into a shell.

## Development

```sh
shellcheck install.sh restore.sh lib/common.sh
bats tests/
```

## License

MIT — see [LICENSE](LICENSE).
