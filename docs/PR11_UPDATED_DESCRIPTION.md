# Updated PR #11 title and description

## Title

Clarify passive/manual Marvell 88W8897 PCIe diagnostics

## Body

### Motivation

This PR is now a public-readiness and safety-clarity pass for the Marvell 88W8897 / AVASTAR PCIe research branch. The earlier boot-time / normal-bring-up multi-BAR snapshot logging path correlated with Surface/OpenCore freezes and has been removed. The current branch state is passive/manual diagnostic tooling only.

### Current safe state

- The current branch is passive/manual diagnostic tooling only.
- No runtime code under `Contents/` should be changed by this cleanup.
- Default `local-test/marvell_probe` performs no explicit BAR MMIO read.
- Explicit BAR reads remain manual-only through `local-test/marvell_probe --read-bar-reg <bar> <offset>`.
- `scripts/surface_passive_bar_snapshot.sh` remains passive-only and does not invoke `--read-bar-reg`.
- Surface passive snapshot validation succeeded after replacing a stale/root-owned probe binary.
- Bring-up remains conservative: `unsupported`, `no-grounded-reset-semantic`, `resetAttempted=0`, and `readyObserved=0`.

### BAR/register interpretation

Manual BAR reads remain inconclusive:

- BAR0 sampled values are readable but high-entropy-looking.
- BAR2 sampled values are zero or `0xffffffff` for sampled mwifiex offsets.
- Neither BAR0 nor BAR2 is proven to be the semantic mwifiex register window.
- BAR2/resource1 remains structurally interesting because Linux mwifiex maps PCI region/resource 2 to `pci_mmap1`, but current Surface/macOS observations do not prove semantic equivalence.

### What changed in this cleanup

- Updated the README for possible public visibility with a clear experimental/non-working-driver status.
- Documented safety boundaries for passive diagnostics and future milestone work.
- Added/verified license handling for publication readiness.
- Added this copyable PR title/body helper for PR #11.
- Reviewed bring-up source notes so the final current state is unambiguous: passive/manual tooling only, no default runtime BAR snapshot path, and no proven register-window identity.

### Explicit non-goals / not added

This PR does not add MMIO writes, reset / PCI FLR / D3cold, firmware upload, interrupt enablement, DMA/rings, command/event handling, ready transition, or network bring-up. It also does not deploy, mount EFI, reboot, shut down, merge, rebase, add firmware binaries, copy Linux kernel source, or commit generated diagnostics.

### Testing / checks to report

- `git status --short --branch`
- `git diff --check`
- `bash -n scripts/surface_passive_bar_snapshot.sh`
- `git diff 4f74f92...HEAD -- Contents`
- `grep -RInE 'logReadOnlyRegisterWindowCandidates|mwifiex window candidate|ReadOnlyWindowRegister' Contents || true`
- `grep -RInE 'sudo|diskutil mount|shutdown|reboot|deploy_oc_test' scripts/surface_passive_bar_snapshot.sh || true`
- `git diff --name-only HEAD~1..HEAD`
