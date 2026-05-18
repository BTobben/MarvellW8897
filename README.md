# MarvellW8897

Experimental macOS/OpenCore kernel-extension and diagnostic tooling for Marvell 88W8897 / AVASTAR PCIe Wi-Fi research.

**Current state: this is not a working Wi-Fi driver.** The current branch is a passive/manual diagnostic-tooling state only. Firmware upload, reset, interrupt enablement, DMA/ring setup, command/event processing, ready transition, and network-interface activation are not implemented here.

## Safety warning

Experimental kernel and PCIe bring-up work can freeze, crash, or otherwise destabilize the test system. Treat this repository as research code, not end-user driver software.

Safety boundaries for the current state:

- Do **not** run scripted BAR sweeps.
- Do **not** loop across BARs or offsets on unstable hardware.
- Do **not** perform MMIO writes unless deliberately implementing and reviewing a future milestone with rollback.
- Do **not** add reset / PCI FLR / D3cold, firmware upload, interrupt enablement, DMA/ring work, command/event handling, or network bring-up as an incidental cleanup.
- Keep diagnostic collection passive unless an operator intentionally chooses a single manual read.

## Current safe state

The current repository state is intentionally conservative:

- Kernel runtime code under `Contents/` has no intended delta from the validated baseline for this cleanup path.
- Default `local-test/marvell_probe` mode prints PCI identity, BAR metadata, bring-up result, and transport state without performing explicit BAR MMIO reads.
- Explicit BAR reads are manual, one-at-a-time operations through `local-test/marvell_probe --read-bar-reg <bar> <offset>`.
- `scripts/surface_passive_bar_snapshot.sh` is passive-only and does not deploy, reboot, shut down, mount EFI, use `sudo`, or invoke `--read-bar-reg`.
- Current bring-up remains conservative: `unsupported`, `no-grounded-reset-semantic`, `resetAttempted=0`, and `readyObserved=0`.

## What is implemented

Implemented repository pieces are limited to scaffolding and diagnostics:

- PCI identity reporting for the Marvell device path.
- Passive BAR metadata reporting.
- Bring-up result ABI reporting.
- Transport state reporting.
- `local-test/marvell_probe` as a diagnostics client.
- Manual, one-register BAR reads through `--read-bar-reg <bar> <offset>`.
- A passive Surface/OpenCore snapshot helper at `scripts/surface_passive_bar_snapshot.sh`.
- Linux mwifiex PCIe source-inspection notes in `docs/MWIFIEX_PCIE_BRINGUP_SOURCE_NOTES.md`.

## What is not implemented

The following are not implemented in the current safe state:

- Firmware loading or firmware upload.
- PCI FLR / D3cold reset.
- MMIO write sequencing for bring-up.
- Interrupt enablement.
- DMA/ring allocation.
- Command/event handling.
- Network interface registration or activation.
- Runtime hardware bring-up beyond conservative reporting.
- Default or scripted BAR register sweeps.

## How to collect passive diagnostics

Use passive/default tools first:

```sh
scripts/surface_passive_bar_snapshot.sh
```

The snapshot helper writes a timestamped report under `out/diagnostics/` and gathers passive/default metadata. It does not invoke `--read-bar-reg`, does not perform explicit BAR MMIO reads, and does not deploy, reboot, shut down, mount EFI, or use `sudo`.

You can also run the probe in default mode:

```sh
local-test/marvell_probe
```

Default probe mode reports PCI/BAR/bring-up/transport diagnostics only. The separate option below is intentionally manual and should not be scripted into sweeps:

```sh
local-test/marvell_probe --read-bar-reg <bar> <offset>
```

Use `--read-bar-reg` only for a deliberate, one-register, read-only check after reviewing passive metadata and stability risk.

## Known current findings

Current Surface/OpenCore observations remain inconclusive:

- Passive metadata showed BAR0 mapped as resource0 with physical base `0x7f91400000` and length `0x100000`.
- Passive metadata showed BAR2 mapped as resource1 with physical base `0x7f91500000` and length `0x100000`.
- BAR2/resource1 is structurally interesting because Linux mwifiex maps PCI region/resource 2 to `pci_mmap1` for register access.
- Manual BAR2 sampled values of zero or `0xffffffff` at sampled mwifiex offsets do not prove BAR2 is the semantic mwifiex register window on this macOS/OpenCore path.
- BAR0 sampled values are readable but high-entropy-looking and do not prove semantic mwifiex register state.
- No readiness, firmware state, ring state, interrupt state, reset safety, or write safety should be inferred from either BAR today.

## Repository layout

- `Contents/` — kext runtime source. Public-readiness documentation/tooling cleanup must not modify this tree.
- `local-test/` — local helper utilities such as `marvell_probe`.
- `scripts/` — diagnostics and development scripts, including the passive Surface snapshot helper.
- `docs/` — source-inspection notes, validation notes, implementation summaries, and PR helper text.
- `MarvellW8897.xcodeproj/` and `MarvellW8897Kext/` — Xcode and bundle resources for the kext target.

## Documentation map

- `docs/NEXT_ENGINEERING_PLAN.md` — source-inspection map and future milestone plan.
- `docs/MWIFIEX_PCIE_BRINGUP_SOURCE_NOTES.md` — Linux mwifiex PCIe comparison, BAR/resource notes, and safety boundaries.
- `docs/VALIDATION_AND_TEST_SETUP.md` — macOS/OpenCore validation and test setup notes.
- `docs/IMPLEMENTATION_SUMMARY.md` — summary of the current scaffolding and diagnostics.
- `scripts/MARVELL_DIAGNOSTICS.md` — boot-path diagnostics runbook and stale-state triage model.

## Contributing / research notes

Contributions should preserve the safety boundaries above:

- Keep documentation/tooling-only changes separate from runtime driver changes.
- Isolate runtime changes into small, reviewed milestones with explicit rollback and validation plans.
- Do not reintroduce boot-time or normal-bring-up BAR snapshot sweeps.
- Do not commit firmware binaries.
- Do not commit generated diagnostic reports, build products, local machine logs, or other artifacts.
- Do not copy Linux kernel source into this repository; use source notes and links instead.

Future work should proceed milestone-by-milestone: first prove the register-window identity, then define safe reset policy, then firmware upload, interrupts, DMA/rings, command/event handling, and only finally network interface activation.
