# Next Engineering Plan

## Purpose and scope

This document is a source-inspection map of the current repository state and a practical plan for the next engineering phase. It is intentionally documentation-only: it does not propose enabling active reset, firmware upload, speculative register writes, or network-interface behavior until lower-level evidence is reproducible.

The current known-good baseline is identity/deploy/boot-path validation, not Wi-Fi operation. The next phase should convert controller presence into grounded 88W8897 functional bring-up evidence, with a strong preference for read-only observation before any new hardware-mutating behavior.

## 1. Current codebase map

### Controller lifecycle

Files: `Contents/MacOS/MarvellW8897Controller.cpp`, `Contents/MacOS/MarvellW8897Controller.hpp`

The controller is the `IOService` entry point. It:

- logs `probe()` matches;
- opens and retains the `IOPCIDevice` provider in `start()`;
- captures PCI identity, class, command/status, and interrupt-line/pin fields;
- enables PCI memory and bus mastering;
- maps BAR/resource state through `MarvellW8897PciBars`;
- resets and configures transport state;
- invokes the conservative bring-up scaffold;
- registers the service after bring-up returns success;
- exposes PCI identity, BAR info, transport state, debug ABI info, and register access helpers to the user client;
- tears down mapped BARs, PCI enables, provider open state, and internal state in `stop()`.

Source-derived note: `start()` treats the current conservative bring-up `Unsupported` outcome as a non-fatal condition when `MarvellW8897Bringup::run()` returns `true`. That keeps IORegistry/service visibility available for inspection even though functional initialization is not complete.

### PCI BAR mapping helpers

Files: `Contents/MacOS/MarvellW8897PciBars.cpp`, `Contents/MacOS/MarvellW8897PciBars.hpp`

The BAR helper layer owns PCI resource discovery and MMIO access validation. It:

- reads raw BAR config slots, including 64-bit continuation handling;
- maps IOKit memory resources with `mapDeviceMemoryWithIndex()`;
- associates BAR slots with mapped resources by exact physical-base match first, then fallback resource assignment;
- logs BAR/resource evidence;
- rejects MMIO access when a BAR is absent, non-memory, a 64-bit continuation slot, unmapped, unaligned, or out of bounds;
- exports legacy and v2 BAR info arrays for userspace diagnostics.

Unknown: the fallback BAR-to-resource association may be necessary on some macOS/IOKit paths, but future hardware validation should capture enough evidence to prove whether BAR0 and the expected register window are always the correct grounded access target for this device.

### Transport profile and state helpers

Files: `Contents/MacOS/MarvellW8897Transport.cpp`, `Contents/MacOS/MarvellW8897Transport.hpp`

The transport layer currently provides:

- a device-gated PCIe profile for vendor `0x11ab`, device `0x2b38`;
- register offsets for firmware status, driver-ready, TX/RX data pointers, and event pointers;
- ring masks/wrap masks and quirk flags derived from mwifiex-style 8897 PCIe knowledge;
- little-endian 32-bit MMIO read/write helpers with BAR validation;
- a write-with-readback helper that currently records `txRingWritePtr`;
- an exported 8-field transport state array for diagnostics.

Grounded fact: this layer names a default firmware file (`mrvl/pcie8897_uapsta.bin`) but does not load, upload, request, parse, or authenticate firmware.

### Conservative bring-up scaffold

Files: `Contents/MacOS/MarvellW8897Bringup.cpp`, `Contents/MacOS/MarvellW8897Bringup.hpp`

The bring-up scaffold is intentionally conservative. It:

- validates access to profile-defined sanity registers;
- reads and records firmware-status and driver-ready register values;
- records profile quirk flags and observed register values;
- sets `transportState.firmwareReady` to `0`;
- explicitly sets `resetAttempted = false` and `readyObserved = false`;
- marks the result as `Unsupported` with `NoGroundedResetSemantic`;
- logs that active reset is disabled.

Important: helper functions exist for polling and write-then-verify, but current `run()` does not use them for reset, firmware upload, or ready transition. Active reset remains intentionally disabled unless future source evidence and hardware traces justify a specific sequence.

### User client ABI

Files: `Contents/MacOS/MarvellW8897UserClient.cpp`, `Contents/MacOS/MarvellW8897UserClient.hpp`

The user client exposes scalar methods for local diagnostics:

| Selector | Method | Behavior |
| --- | --- | --- |
| 0 | `getPciInfo` | returns 10 PCI identity/status fields |
| 1 | `getBarInfoLegacy` | returns 8 legacy BAR fields |
| 2 | `readReg32FromBar` | reads one 32-bit BAR register |
| 3 | `writeReg32ToBar` | writes one 32-bit BAR register |
| 4 | `getBarInfoV2` | returns 11 BAR/resource fields |
| 5 | `getTransportState` | returns 8 transport-state fields |
| 6 | `writeReg32ToBarWithFlush` | writes then reads back one 32-bit BAR register |
| 7 | `getDebugAbiInfo` | returns ABI/version/count metadata |
| 8 | `getBringupResult` | returns read-only conservative bring-up result fields |

Caution: selectors 3 and 6 can mutate device registers. The next observability milestone should not depend on those mutating selectors unless there is a separate, explicit hardware-safety review.

### Debug ABI helpers

Files: `Contents/MacOS/MarvellW8897Debug.cpp`, `Contents/MacOS/MarvellW8897Debug.hpp`, `Contents/MacOS/MarvellW8897Regs.hpp`

The debug ABI reports a compact capability/count contract:

- ABI major/minor style fields currently `1` and `0`;
- selector bitmap advertising selectors 0 through 8;
- expected output counts for legacy BAR info, v2 BAR info, and transport state.

`MarvellW8897Regs.hpp` centralizes the maximum BAR/resource counts, invalid resource sentinel, scalar output counts, and debug selector bitmap.

### Local userspace probe

File: `local-test/marvell_probe.cpp`

The probe helper opens `MarvellW8897Controller` and prints:

- PCI identity fields;
- debug ABI info when available;
- default/passive probe output without default BAR MMIO reads;
- optional explicit one-register reads only when invoked with `--read-bar-reg <bar> <offset>`;
- BAR info for BAR slots 0 through 5, preferring v2 when advertised;
- transport state, with fallback behavior for older selector layout.

The local probe is currently best understood as a diagnostics client, not as a functional network test. Default mode should remain passive and should not perform default BAR MMIO reads. Explicit register reads must stay opt-in, one BAR and one offset at a time. It does not exercise firmware upload, interrupts, rings, mailbox semantics, or interface registration.

### Deploy and diagnostics scripts

Files: `scripts/deploy_oc_test.sh`, `scripts/trace_marvell_boot_runtime.sh`, `scripts/inspect_marvell_history.sh`, `scripts/trace_marvell_sources.sh`, `scripts/stage_marvell_root_owned.sh`, `scripts/cleanup_marvell_auxkc.sh`, `scripts/MARVELL_DIAGNOSTICS.md`

The scripts support the completed identity/deploy/boot-path validation phase:

- `deploy_oc_test.sh`: build/deploy/verify path for OpenCore staging;
- `trace_marvell_boot_runtime.sh`: post-boot collector for loaded identity, UUID, IORegistry, logs, EFI/OpenCore conclusiveness, and delegated deep tracing;
- `inspect_marvell_history.sh`: compact Marvell-specific history and stale-reference triage, with strict failure modes;
- `trace_marvell_sources.sh`: deeper KEM/KC/Preboot/EFI/source tracing;
- `stage_marvell_root_owned.sh`: optional root-owned staging helper to reduce user-path coupling;
- `cleanup_marvell_auxkc.sh`: dry-run-by-default cleanup helper for safe Marvell-specific staged artifacts;
- `scripts/MARVELL_DIAGNOSTICS.md`: runbook and signal model for the historical mixed-state investigation.

## 2. Current grounded facts vs assumptions

### Grounded facts represented in current code/docs

- The active project identity documented by the repo is `brainworks.driver.MarvellW8897 (1.0.0)`.
- The documented clean validation context says the loaded executable UUID matched the built executable UUID.
- The documented clean validation context says `MarvellW8897Controller` appeared in IORegistry.
- The previous kcgen/kernelmanager/history mixed-state issue is considered cleared only in that documented clean validation context.
- Controller startup currently enables PCI memory and bus mastering before mapping BARs and running conservative bring-up.
- The transport profile is only configured for vendor `0x11ab`, device `0x2b38`.
- Current bring-up reads selected profile registers but intentionally does not attempt reset or firmware-ready transition.
- Active reset remains intentionally disabled in current bring-up unless future grounded evidence supports a specific sequence.
- Firmware upload is not implemented.
- Interrupt handling is not implemented.
- Network-interface registration is not implemented.

### Assumptions or unproven interpretations

- The profile register offsets and ring masks are plausible mwifiex-style 8897 PCIe values, but the repository has not yet proven the full sequence on this macOS/OpenCore hardware path.
- The BAR/resource identity remains unresolved. Current passive/manual evidence makes BAR2/resource1 structurally interesting from Linux source inspection, but neither BAR0 nor BAR2 is proven to be the semantic mwifiex register window on the macOS/OpenCore target.
- A default firmware filename is known to the transport profile, but the repository does not prove firmware availability, loading mechanism, device download protocol, or firmware-ready semantics.
- Ring pointer register naming exists, but the repository has not proven ownership direction, wrap behavior, event semantics, DMA descriptor layout, or synchronization rules.
- The current user client can perform direct register writes, but safe production semantics for any write path are not yet established.

## 3. Current limitations

The following are not yet implemented or proven:

- firmware upload and a firmware-ready transition;
- real startup sequencing from PCI enablement through stable device initialization;
- interrupt registration, enabling, masking/unmasking, acknowledgment, and dispatch;
- ring allocation, DMA mapping, descriptor format, ownership bits, and ring pointer semantics;
- mailbox, command, event, and response semantics;
- network interface registration and integration with macOS networking stacks;
- suspend/resume ordering, power-state transitions, and recovery after errors;
- robust timeout/retry policy for firmware/bootstrap/ring/interrupt failures;
- concurrency locking around future interrupt/DMA/user-client interactions;
- a non-mutating ABI surface that captures all bring-up observations without relying on unsafe register writes.

## 4. Source-derived gap analysis

### Gaps between controller presence and functional initialization

1. **Bring-up result reporting is present but conservative.**
   `MarvellW8897BringupResult` captures firmware-status, driver-ready, stage, failure reason, and quirk evidence. Selector 8 exports those observations through a read-only ABI without changing hardware behavior. The reported result remains `Unsupported` / `NoGroundedResetSemantic`.

2. **Firmware handling is absent.**
   The code contains a firmware filename in the profile, but no `OSKext`/filesystem firmware retrieval path, no download protocol, no block transfer loop, no completion polling, and no ready-state validation.

3. **Ready detection is deliberately unresolved.**
   `run()` reads firmware-status and driver-ready registers, then sets `firmwareReady = 0`, `readyObserved = false`, and `NoGroundedResetSemantic`. This is honest and safe, but it means the driver does not yet know how to distinguish cold hardware, ROM/bootloader state, firmware-running state, or failure state.

4. **Interrupt path is missing.**
   PCI config interrupt line/pin are logged, but there is no event source, work loop, interrupt filter/action, interrupt status register read, mask/ack register model, or passive interrupt counter.

5. **Ring and mailbox model is only a profile skeleton.**
   Register offsets and masks exist, but there is no allocation of TX/RX/event rings, no descriptor memory, no DMA command setup, no doorbell/ownership protocol, and no event parsing.

6. **User-client write selectors exist before production safety policy.**
   Direct BAR writes can be useful during controlled bring-up, but a future engineer should avoid making follow-up tasks depend on writes until register semantics are grounded and guarded.

7. **Transport state is mostly not updated by runtime events.**
   Fields such as IRQ status, firmware-ready, last event ID, RX/TX read pointers, and ignored BT coexistence events are exported, but the current code has no interrupt or event path to keep most of them live.

8. **No network interface lifecycle exists.**
   There is no `IO80211Controller`/network-interface registration, no media state, no scan/join path, no packet transmit/receive path, and no link state reporting.

9. **Power management is absent.**
   The driver does not yet model sleep, wake, quiesce, teardown/reinitialize ordering, or firmware/ring recovery.

10. **Validation remains mostly boot-path focused.**
    Existing docs and scripts are strong for identity/deploy/loaded-artifact validation. Future milestone validation needs additional captures for read-only register snapshots, interrupt counters, ring/mailbox snapshots, and eventually interface state.

### Documentation consistency notes

- `README.md` and `docs/IMPLEMENTATION_SUMMARY.md` should continue to describe the current state as passive/manual diagnostics only.
- The active bring-up path remains intentionally conservative and reports `Unsupported` with `NoGroundedResetSemantic`; documentation should not imply reset, firmware-ready transition, upload, interrupts, DMA/rings, command/event handling, or network-interface registration.
- Future documentation changes should keep default probe behavior distinct from explicit one-register `--read-bar-reg <bar> <offset>` checks.

## 5. Proposed next milestones

### Milestone 1: improve observability of current bring-up state without changing hardware behavior

Goal: expose and collect what the driver already observes.

Suggested work:

- The first observability step now exposes `MarvellW8897BringupResult` through read-only selector 8 (`getBringupResult`).
- The local probe now prints bring-up stage/failure reason, firmware-status value, driver-ready value, profile quirks, last BAR/offset/read/write, and poll count when selector 8 is advertised.
- Keep all collection read-only; do not add reset, firmware upload, interrupt enable, or speculative writes.

Expected evidence:

- post-boot `ioreg` still shows `MarvellW8897Controller`;
- local probe prints PCI/BAR/transport state plus bring-up result;
- kernel log contains the existing conservative bring-up log line;
- no new register writes beyond current baseline.

### Milestone 2: add read-only firmware/bootstrap state capture

Goal: characterize cold/current hardware state across boots without trying to change it.

Suggested work:

- Define a small, explicitly read-only register snapshot set from currently profiled firmware/bootstrap-related registers.
- Keep default collection passive; use explicit `--read-bar-reg <bar> <offset>` only for deliberate one-register checks.
- Capture firmware-status, driver-ready, event pointer, and ring pointer values only when the operator explicitly chooses a single candidate BAR/offset read.
- Record repeated snapshots across warm/cold boots to identify stable patterns.

Expected evidence:

- snapshot values are reproducible or differences are explained;
- no active reset or firmware download is attempted;
- BAR mapping and access validation remain clean.

### Milestone 3: add grounded firmware-ready detection if source evidence supports it

Goal: recognize firmware-ready state only when the evidence is strong enough.

Prerequisites:

- source-backed ready-bit/ready-value semantics;
- observed hardware traces that match the expected condition;
- clear timeout behavior that does not mutate device state.

Suggested work:

- Add read-only ready detection first.
- Keep any polling bounded and documented.
- Do not add firmware upload or reset as part of this milestone unless a separate plan grounds every write.

Expected evidence:

- ready/not-ready outcomes are printed by local probe and logs;
- false positives are avoided;
- timeout/failure states are explicit.

### Milestone 4: add interrupt observation path

Goal: observe interrupts safely before enabling a full data path.

Suggested work:

- Add a work loop and interrupt event source if the provider supports it.
- Initially count and log interrupts with minimal register reads needed to identify source state.
- Do not enable unknown interrupt masks or acknowledge unknown status bits until semantics are grounded.

Expected evidence:

- interrupt line/pin/provider capability are captured;
- passive counters can be collected after boot or controlled stimuli;
- no interrupt storm or boot instability occurs.

### Milestone 5: add ring/mailbox diagnostics

Goal: map ring and mailbox semantics before data transfer.

Suggested work:

- Add read-only ring pointer snapshots with mask/wrap decoding.
- Identify command/event/mailbox registers from source evidence.
- Add diagnostics that compare raw pointer values, masked indices, wrap state, and observed event IDs.
- Defer ring memory allocation and doorbells until ownership semantics are understood.

Expected evidence:

- ring pointer snapshots are repeatable;
- mailbox/event state is decoded conservatively;
- any unknown bitfields remain labeled unknown.

### Milestone 6: begin minimal interface bring-up only after lower-level evidence is reproducible

Goal: start network-interface work only after firmware/bootstrap/interrupt/ring evidence is stable.

Suggested prerequisites:

- firmware-ready detection is grounded;
- interrupt observation is stable;
- ring/mailbox command-response semantics are understood;
- at least one reproducible local validation artifact proves lower-level initialization state.

Expected evidence:

- interface registration does not race firmware/bootstrap;
- link/media state is honest;
- packet paths are not enabled before rings and firmware commands are validated.

## 6. Recommended next Codex task

Recommended follow-up task:

> Use selector 8 (`getBringupResult`) in local macOS/OpenCore validation to capture the existing conservative bring-up result across cold/warm boots, without adding hardware writes, reset behavior, firmware upload, interrupt enablement, or deploy-script behavior changes.

Why this remains safe and useful:

- the selector exports data the driver already records in kernel memory;
- it improves post-boot evidence before changing hardware behavior;
- it creates acceptance artifacts for later firmware/bootstrap tasks.

Suggested constraints for that task:

- collect repeated local probe output with selector 8 advertised;
- compare raw values against kernel log bring-up lines;
- do not call mutating user-client selectors;
- do not change Info.plist identity, build settings, deploy behavior, or diagnostic script behavior.

## 7. Acceptance criteria for future functional work

For every future milestone, local macOS/OpenCore validation should capture the following baseline artifacts:

- git commit hash and local diff state;
- build/deploy command output from `scripts/deploy_oc_test.sh` when deployment is part of the milestone;
- post-boot output from `scripts/trace_marvell_boot_runtime.sh`;
- strict history check output from `scripts/inspect_marvell_history.sh --strict-users --strict-km-fail`;
- loaded kext identity/version and built-vs-loaded UUID comparison;
- IORegistry evidence for `MarvellW8897Controller`;
- local probe output relevant to the milestone;
- kernel logs containing Marvell bring-up/diagnostic lines;
- explicit statement of whether EFI/OpenCore checks were conclusive or inconclusive;
- explicit statement of whether the test was run on real macOS hardware with the target device.

Additional milestone-specific acceptance criteria:

| Milestone | Required validation capture |
| --- | --- |
| 1: bring-up observability | New read-only bring-up fields from local probe; no new hardware writes; unchanged service presence. |
| 2: firmware/bootstrap snapshot | Repeated read-only snapshots across at least one reboot; raw values and decoded interpretations labeled separately. |
| 3: firmware-ready detection | Source-backed ready condition, bounded polling evidence, timeout/failure examples, and no reset/upload side effects. |
| 4: interrupt observation | Interrupt event-source setup evidence, passive counters, no interrupt storm, and clear note of any status reads or acknowledgments. |
| 5: ring/mailbox diagnostics | Raw and decoded ring/mailbox snapshots, mask/wrap interpretation, and unknown bitfields explicitly labeled. |
| 6: minimal interface bring-up | Proof that firmware/bootstrap/interrupt/ring prerequisites are reproducible before interface registration, plus honest media/link state reporting. |

A future change should not be considered accepted merely because the kext loads. It should be accepted only when the relevant low-level evidence is captured, reproducible, and clearly separated from assumptions.
