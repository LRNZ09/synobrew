# Design rationale — why synobrew is small

synobrew is a deliberately minimal, **auditable** installer: because it runs
privileged code on a data-bearing, often internet-exposed NAS, the whole point
is that a cautious user can read `install.sh` / `restore.sh` top-to-bottom
before running them. This note records what synobrew improves on and what it
deliberately leaves out. The authoritative design is
[`docs/superpowers/specs/2026-07-05-synobrew-design.md`](superpowers/specs/2026-07-05-synobrew-design.md).

## vs. a naive root-based approach

An early, naive approach — run as root, bind-mount the whole homes share onto
`/home`, pipe `curl` into `bash` — works in the happy path but makes several
choices synobrew rejects:

| First draft | synobrew |
|-------------|----------|
| **Runs as root** (`sudo bash …`, aborts if `EUID != 0`). | **Never runs as root** — Homebrew refuses root anyway; escalate per-command with ordinary `sudo` + a keep-alive, **no `NOPASSWD` sudoers fragment**. |
| **Bind-mounts the whole homes share** (`mount --bind /volume1/homes /home`), exposing every user's home under `/home`. | Bind-mounts **only `/home/linuxbrew`** from a dedicated `~/.tools/synobrew/prefix` store — `linuxbrew` never sits beside real user folders. |
| `ldd` wrapper just `exec`s `libc.so.6`; `/etc/os-release` written with no sense of which matters. | The **`ldd` shim is the one truly-required fix** (Homebrew's glibc probe); it parses a version and preserves any real/existing `ldd`. `/etc/os-release` is **cosmetic** and treated as such. |
| No hardware/OS gate. | Preflight gates: arch from **`uname -m`** (x86_64 ok, aarch64 warn, 32-bit hard-block), DSM tier, homes-service, git, glibc (informational). |
| Pipes `curl` straight into `bash` (blind); no `set -e`, no dry-run, no backups, not idempotent, no reboot persistence. | `set -euo pipefail`; **`--dry-run`** previews every privileged action; backs up any file it overwrites (`*.synobrew.bak-<epoch>`); **idempotent install-or-repair** with prefix migration; survives reboots via a DSM **Task Scheduler** boot task. |
| No tests. | Pure logic in `lib/common.sh`, `bats` unit/sandbox tests, `shellcheck` + `bats` in CI — all runnable without a NAS. |

## vs. `MrCee/Synology-Homebrew` (~2,600+ lines)

synobrew keeps only the parts that affect whether `brew` works, and omits the
rest so the script stays reviewable:

**Deliberately omitted:** the Powerlevel10k theme, the Neovim IDE bootstrap,
Oh-My-Zsh + zsh plugins/completion hardening, the `config.yaml` package manager
(and its `yq` dependency), baseline formulae (`ruby python3 zsh gcc binutils`)
as *requirements*, the temporary passwordless-sudoers fragment, and the
`exec zsh` / `ln -sf …/zsh /bin/zsh` shell handoff.

**Kept (minimized):** the DSM gap-fixes (`ldd` shim + `/home/linuxbrew` mount,
plus a cosmetic `os-release`), the arch/DSM preflight gate, an inline DSM
Task Scheduler boot command that re-creates the runtime-only bind mount (DSM
regenerates `/etc/fstab` each boot, so fstab won't persist it; no root-run
script lives under the user's home), refuse-as-root, and idempotency guards.

## Verified corrections (from research + adversarial review)

These drove the design and were each independently checked:

1. The **`ldd` shim is the truly-required fix** — it is Homebrew's glibc-detection proxy on a DSM that has no `ldd`.
2. `/etc/os-release` is **cosmetic**, not a gate — it only silences a per-command warning and fixes `brew config`.
3. **Passwordless sudo is not required** — ordinary interactive `sudo` plus a background keep-alive suffices; no `NOPASSWD` rule is ever written.
4. **Task Scheduler beats systemd** for update resilience — its entries survive DSM major updates better than `/etc/systemd/system` units, and it is the Synology-native norm.
5. The arch gate must read **`uname -m`**, never the model name; `aarch64` is allow-with-warning (thin Linux bottles → source builds that can OOM on low-RAM units), 32-bit is a hard block.
6. The **glibc version is informational**, never a hard blocker — DSM ships well above Homebrew's 2.13 floor, and Homebrew builds its own if needed.
