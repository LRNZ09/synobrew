# syno-brew — Design Spec

**Date:** 2026-07-05
**Status:** Approved (pending user review of this spec)

## 1. Purpose

A small, **auditable** installer that gets Homebrew (Linuxbrew) working on a
Synology NAS running DSM 7.x, and keeps it working across reboots. It exists as
a deliberately minimal, easy-to-review alternative to the much larger
[MrCee/Synology-Homebrew](https://github.com/MrCee/Synology-Homebrew) (~2,600+
lines), which bundles a Neovim IDE, Oh-My-Zsh, a Powerlevel10k theme (a single
96 KB file), and a YAML-driven package manager — none of which affect whether
`brew` works.

**Design value #1: reviewability.** Because this runs privileged code on a
data-bearing, often internet-exposed NAS, the whole point is that a cautious
user can read the script top-to-bottom before running it. Every decision below
favors "small and obvious" over "clever and complete."

### Goals

- Install a working Homebrew on DSM 7.x with the minimum necessary host changes.
- Survive reboots automatically (via a DSM Task Scheduler boot task).
- Be idempotent — re-running is safe and is the documented recovery path after
  DSM updates.
- Be safe: fail fast on unsupported hardware, never run as root, back up any
  system file it overwrites, and offer a `--dry-run`.

### Non-goals

- No shell frameworks, themes, editors, or curated package lists.
- No in-script uninstall (manual revert steps documented in the README).
- No attempt to make Homebrew "officially supported" on Synology — this is a
  community best-effort setup and the README says so.

## 2. Target & compatibility

Decision is made from `uname -m`, **never** from the model name (Synology model
naming does not reliably indicate CPU arch).

| `uname -m` | Behavior |
|------------|----------|
| `x86_64` / `amd64` | **ALLOW** — Tier 1, full bottles. |
| `aarch64` / `arm64` | **ALLOW with warning** — supported arch but thin Linux bottles; many formulae build from source and can OOM on low-RAM units. |
| `armv7l`, `armv6l`, `armv5*`, `i686`, `i386`, anything else | **HARD-BLOCK** with a clear message. |

Other preflight gates:

- **Not root:** abort if `EUID == 0` (Homebrew's installer refuses root anyway).
- **sudo available:** the invoking user must be in DSM's `administrators` group;
  ordinary password-prompted `sudo` is sufficient. **Passwordless sudo is NOT
  required** and will not be configured.
- **DSM version** from `/etc.defaults/VERSION`: `< 7.1` block; `7.1` allow
  best-effort with warning; `7.2+` recommended.
- **User home service:** `/var/services/homes/$USER` (or `/volume1/homes`) must
  exist; if not, instruct the user to enable Control Panel → User & Group →
  Advanced → User Home, then re-run.
- **git present:** warn (not fatal) if missing, with SynoCommunity instructions;
  brew can `brew install git` afterward, but update/tap need git.
- **glibc:** informational only — never a hard block. DSM ships ~2.26–2.36
  (above Homebrew's 2.13 floor); if too old, Homebrew builds its own.

## 3. Repo layout

```tree
syno-brew/
├── install.sh              # one-shot installer, run over SSH — the thing to review
├── restore.sh              # idempotent shims + bind mount; run by install.sh AND the boot task
├── lib/
│   └── common.sh           # pure helpers shared by both scripts + unit-tested
├── tests/
│   ├── common.bats         # bats tests over lib/common.sh pure functions
│   └── test_helper.bash
├── .github/workflows/ci.yml# shellcheck + bats, no NAS required
├── README.md
└── LICENSE                 # MIT
```

Two entry-point scripts, one shared helper library. Single source of truth: the
shim/mount logic lives in `restore.sh`; `install.sh` calls it, and the boot task
calls the installed copy. `lib/common.sh` holds only pure, side-effect-free
functions so they can be unit-tested without a Synology.

## 4. Component: `install.sh`

Run **once**, over SSH, as a non-root admin user. Responsibilities in order:

1. **Parse args:** `--dry-run` (print every privileged/mutating action, execute
   nothing), `--yes` (skip confirmation; implies non-interactive), `-h/--help`.
2. **Preflight gates** (§2). Abort early with actionable messages.
3. **Confirm:** print exactly what will change (`/usr/bin/ldd`, `/etc/os-release`,
   `/home` bind mount, install of `restore.sh`, edit of the shell rc file) and
   prompt; `--yes` skips.
4. **Apply shims** by invoking `restore.sh` (which is idempotent and does its own
   backups). This creates the mount + shims for the current session.
5. **Install persistence artifact:** copy `restore.sh` to `$HOME/.tools/syno-brew/restore.sh`
   (a conventional `~/.tools/` grouping dir on the homes share → on the data
   volume, survives DSM updates), `chmod 755`. Resolve it to its absolute
   `/volumeX/homes/<user>/.tools/syno-brew/restore.sh` path (via `readlink -f`)
   and bake that into the printed Task Scheduler command and the README, since
   the root boot task has no `$HOME`. Then **print** the exact DSM Task Scheduler
   steps to register it as a boot task (see §6). The script cannot reliably
   create Task Scheduler entries from the CLI, so this one step is manual and
   documented.
6. **Pre-authenticate sudo** (`sudo -v`) and start a short background keep-alive
   that refreshes the sudo timestamp every ~60s until the script exits (killed
   via an EXIT trap). This lets the long Homebrew install use `sudo` without
   re-prompting and **without** any `NOPASSWD` sudoers file.
7. **Run the official installer** as the current user:
   `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`.
   Interactive by default; with `--yes`, set `NONINTERACTIVE=1` (README notes
   this path relies on the warm sudo timestamp / passwordless sudo).
8. **Session env + `HOMEBREW_TEMP`:** `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`
   for the current shell, and `export HOMEBREW_TEMP="$HOME/tmp"` (mkdir it) so
   Homebrew's large temp writes stay off DSM's ~2.4 GB system partition.
9. **Persist shell env** (idempotent, per detected login shell — §5).
10. **Verify:** `brew --version`, `brew config`, `brew doctor` (doctor is
    non-fatal), then print a summary + next steps (including the Task Scheduler
    reminder if not yet done).

`set -euo pipefail` is on. Every mutating action is a small named function that
honors `--dry-run`.

## 5. Component: `restore.sh` (idempotent shims + mount)

Runs from `install.sh` and from the boot task (as root at boot). Each operation
is guarded so re-running is a no-op when already correct. Backs up any
pre-existing target to `<path>.syno-brew.bak-<epoch>` before overwriting.

1. **Bind mount `/home`:**

   ```sh
   if ! grep -qs ' /home ' /proc/mounts; then
     mkdir -p /home
     mount -o bind "$(readlink -f /var/services/homes)" /home
   fi
   chown root:root /home
   chmod 775 /home
   ```

   Rationale: Homebrew bottles are built for the fixed prefix
   `/home/linuxbrew/.linuxbrew`; DSM has no `/home`. Bind mounts are
   runtime-only and DSM regenerates `/etc/fstab` each boot, so this must be
   re-run at boot.
2. **`/usr/bin/ldd` shim (REQUIRED):** a tiny script that parses the glibc
   version from `/usr/lib/libc.so.6` and prints `ldd <version>` (fallback a sane
   value ≥ 2.13). Rationale: Homebrew's `install.sh` runs `ldd --version` to
   detect glibc (because DSM has no system Ruby ≥ 3.4); DSM has no `ldd`, so the
   empty output is misread as "glibc too old" and the install aborts. `chmod 755`.
3. **`/etc/os-release` (COSMETIC — nice-to-have):** a small file/script deriving
   `PRETTY_NAME` from `/etc.defaults/VERSION`. Rationale: only silences a
   per-command `os-release: No such file` warning and fixes the `brew config` OS
   field. **Not** a gate for install; created for cleanliness.
4. **Pre-create `/home/linuxbrew`** owned appropriately so the installer can
   populate the prefix.

`restore.sh` also accepts `--dry-run`.

## 6. Persistence architecture (Task Scheduler)

- **Bind mount:** never survives reboot → recreated every boot by the task.
- **`ldd` shim / `os-release`:** survive plain reboots but are wiped by DSM
  updates (system partition is re-flashed; `/etc` can regenerate from
  `/etc.defaults`). The boot task re-runs `restore.sh`, which re-applies all of
  them, so the setup self-heals across most updates.
- **`restore.sh` itself** lives at `$HOME/.tools/syno-brew/restore.sh` on the
  homes share (data volume) and survives DSM updates. It shares fate with the
  brew prefix, which also lives on the homes share
  (`/home/linuxbrew/.linuxbrew` → `/volumeX/homes/linuxbrew/...`): if the homes
  share is an *encrypted* shared folder and unmounted at boot, both the prefix
  and `restore.sh` are unavailable until it is unlocked — an acceptable,
  documented edge case since brew is unusable then regardless.

**Boot task (manual, one time, README-documented):** Control Panel → Task
Scheduler → Create → Triggered Task → User-defined script; **User = root**,
**Event = Boot-up**; command: the absolute path baked in at install time, e.g.
`/volume1/homes/<user>/.tools/syno-brew/restore.sh`. Must be root (`mount`/`chown`
need it; `sudo` does not work inside DSM tasks).

**Why Task Scheduler over systemd:** verified research found Task Scheduler
entries (stored in DSM's config DB) survive DSM major updates better than
`/etc/systemd/system` units, which can be wiped. Task Scheduler is also the
Synology-native norm (used by cdalvaro and MrCee).

**README must state:** the boot task restores everything after a *reboot*; after
a DSM *update* that also removed the boot task or `restore.sh`, re-run the
idempotent `install.sh`.

## 7. Shell environment setup (idempotent, per shell)

Detect the login shell (from `$SHELL` / `getent passwd`) and append only if not
already present (guarded with a `grep -qxF`):

- **bash** → `~/.profile` (DSM default) and/or `~/.bashrc`:
  `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"`
- **zsh** → `~/.zshrc` (or `~/.zprofile`): same `eval` line.
- **fish** → `~/.config/fish/config.fish`:
  `/home/linuxbrew/.linuxbrew/bin/brew shellenv fish | source`

Also print the line so the user can add it elsewhere if desired.

## 8. Safety practices

- `set -euo pipefail` on by default (MrCee ships it *off* — do not copy that).
- Never run as root; escalate per-command with ordinary `sudo`. **No temporary
  `NOPASSWD` sudoers fragment** (a kill mid-run could orphan an
  `ALL=NOPASSWD:ALL` rule).
- Idempotent everywhere (`/proc/mounts`, `grep -qxF`, "already installed" checks).
- `--dry-run` prints every mutating action; `--yes` for non-interactive.
- Back up any pre-existing system file before overwrite (`.syno-brew.bak-<epoch>`).
- Tee a logfile for diagnosability.
- README supply-chain hygiene: pin/review a specific commit before running, keep
  the NAS off the public internet, snapshot/back up first, prefer
  **clone → read → run** over blind `curl | bash`.

## 9. README outline

Prerequisites (enable User Home service, SSH as admin user, arch/DSM support
table, git via SynoCommunity) · What it changes (explicit list) · Install
(clone-read-run + one-liner) · **Register the boot task** (Task Scheduler steps)
· After reboots vs after DSM updates · Manual uninstall (conservative: run
Homebrew's `uninstall.sh`, remove shims/restore `.bak`, `umount` + `rmdir`
`/home` **only if empty and we created it**, strip the shellenv line, delete the
boot task, remove `$HOME/.tools/syno-brew/`) · Compatibility & caveats
(unofficial, aarch64 source builds) · Safety notes.

## 10. Testing

- `lib/common.sh` holds pure helpers (arg parsing, `uname -m` classification,
  DSM version compare, glibc-version parse, idempotency-guard predicates).
- `tests/*.bats` unit-test those without a NAS.
- `.github/workflows/ci.yml`: run `shellcheck` on all scripts + `bats` tests.
- Manual: documented `--dry-run` walkthrough + a real run on DSM 7.2 x86_64.

## 11. Deliberately omitted (vs MrCee)

Powerlevel10k theme (96 KB), the Neovim IDE bootstrap, Oh-My-Zsh + zsh
plugins/completion hardening, the `config.yaml` package manager (+`yq`), baseline
formulae (`ruby python3 zsh gcc binutils`) as *requirements*, the temporary
passwordless sudoers fragment, and the `exec zsh` / `ln -sf .../zsh /bin/zsh`
handoff. **Kept:** the four DSM gap-fixes (minimized), the arch/DSM gate, the
"not persistent across reboot" boot task, refuse-as-root, and idempotency guards.

## 12. Verified corrections (from research + adversarial verification)

1. `/etc/os-release` is **cosmetic**, not required — demoted to nice-to-have.
2. The **`ldd` shim is the truly required one** (glibc detection proxy).
3. **Passwordless sudo is not required** — interactive `sudo` prompts suffice.
4. **Task Scheduler > systemd** for update resilience (drove the §6 decision).
5. Arch gate must use `uname -m`, never model name; aarch64 = allow-with-warning,
   32-bit = hard-block.
6. glibc version is informational, not a hard blocker.

## 13. Open questions

None outstanding. Scope, persistence mechanism, shell handling, uninstall
approach, testing, license, and repo location are all decided.
