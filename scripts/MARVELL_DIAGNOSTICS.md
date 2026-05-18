# MarvellW8897 boot-path diagnostics

This repo contains focused helpers for Marvell boot-path diagnostics and fallback triage.

## Scripts

- `scripts/deploy_oc_test.sh`
  - builds + deploys
  - verifies built vs copied plist/executable
  - now fails loudly if deployed EFI kext plist is missing or if OpenCore `Kernel/Add` has no Marvell entry
  - runs deep source tracing at the end

- `scripts/trace_marvell_sources.sh`
  - deep source tracer for boot/caches/staging
  - checks EFI mount reality (`/Volumes/EFI`, mount status, diskutil info, EFI-like mounts)
  - scans these roots by Marvell identity/path evidence:
    - `/private/var/db/KernelExtensionManagement`
    - `/private/var/db/KernelCollections`
    - `/System/Volumes/Preboot`
    - `/Library/Extensions`
    - `/System/Library/Extensions`
    - `/Library/StagedExtensions`
  - dynamically discovers `com.apple.kcgen.instructions.plist` files under KEM (including AuxKC trees)
  - reports exact paths, ownership, mtimes, hashes, UUIDs, and plist versions where available
  - splits evidence into:
    - B) Marvell-specific hits
    - C) Marvell-specific hits that also contain `0.0.1` (strongest stale-metadata signal)
    - generic `0.0.1` noise is intentionally de-emphasized and excluded from main candidate count
  - marks EFI/OpenCore results as **inconclusive** when mount/config verification is unavailable
  - prints a mixed-state warning if loaded UUID matches built UUID while kcgen/history still points at user build path and/or C hits remain

- `scripts/inspect_marvell_history.sh`
  - compact Marvell-only inspector (chat-paste friendly)
  - reports only:
    - A) Marvell identity hits
    - B) Marvell identity + `0.0.1` hits
    - C) current serialized Marvell identity + `/Users/.../MarvellW8897...kext` refs
    - E) exact recurring stale dev path references, by default `/Users/<account>/src/MarvellW8897/out/Debug/MarvellW8897Kext.kext`
    - D) log-history `kernelmanager_helper` Marvell ownership/validation failures, labeled with the searched log window
  - excludes generic unrelated `1.0.0`/`0.0.1` system noise from primary candidate counting
  - keeps strict mode, but distinguishes current serialized C/E failures from log-history D failures

- `scripts/trace_marvell_boot_runtime.sh`
  - one-shot post-boot collector
  - compact by default: reports git head, built identity/hash/UUID, loaded kmutil line, a filtered `MarvellW8897Controller` IORegistry view, C/E/D signals, EFI/OpenCore conclusiveness, and a final runtime summary
  - does **not** print the full global `IOKitDiagnostics`/Classes dictionary unless `--verbose-ioreg` is requested
  - use `--verbose-ioreg` only when a broad low-level IORegistry grep is needed for deeper triage
  - explicitly reports whether EFI/copied-kext/OpenCore checks were conclusive or inconclusive
  - splits active loaded-artifact status from C/E serialized references and D log-history failures
  - selector-8 bring-up result output from `local-test/marvell_probe` is part of the runtime evidence set when available
  - then runs `trace_marvell_sources.sh`, which repeats dry-run discovery across the same safe inspection roots

- `scripts/cleanup_marvell_auxkc.sh`
  - optional cleanup helper
  - **dry-run by default**
  - with `--apply`, backs up first and removes only safe Marvell-specific staged artifacts
  - risky system metadata paths are reported as **manual-action-only** and not auto-removed
  - never called automatically by deploy script

- `scripts/stage_marvell_root_owned.sh`
  - stages the built kext into a canonical root-owned location (`/private/var/root/MarvellW8897Staging` by default)
  - sets `root:wheel` ownership + sane permissions when `--apply` is used
  - dry-run output separates current source bundle identity/hash/UUID from any existing destination bundle
  - warns when an existing destination differs from the current source and states that `--apply` would replace it
  - intended to eliminate future `/Users/...` path coupling in checks/workflows

## Historical signal model (used during investigation)

- Generic `0.0.1` lines in unrelated Apple files are treated as noise and not part of the primary candidate signal.
- During the investigation, the top-priority mixed-state signals were C and D, but they are not equivalent:
  - active loaded UUID match = the loaded executable matches the built executable observed for this run
  - C = current serialized Marvell identity + `/Users/.../MarvellW8897...kext` references in scanned metadata
  - E = exact recurring stale dev path references, defaulting to `/Users/<account>/src/MarvellW8897/out/Debug/MarvellW8897Kext.kext`
  - D = log-history `kernelmanager_helper` ownership/validation failures for Marvell in the searched log window
- A D-only finding should remain visible and tracked, but should not by itself imply that the active loaded kext is wrong when the loaded UUID matches built UUID and C/E serialized refs are absent.
- Recurring D-only history commonly points to kernelmanager history, kcgen instructions, KEM/AuxKC metadata, prior manual `kmutil` load attempts, or stale validation records; cleanup should remain manual/optional unless a script proves the target is safe and Marvell-scoped.
- B was treated as secondary stale-metadata evidence:
  - B = Marvell identity + `0.0.1`
- If EFI is unmounted or OpenCore config is unavailable, absence findings are **inconclusive**, not definitive.
- Selector-8 bring-up result validation is now part of the runtime evidence set: the debug ABI advertises bitmap `0x1ff`, `getBringupResult` returns 12 fields, and the observed conservative state is `unsupported` / `no-grounded-reset-semantic` with `resetAttempted=0` and `readyObserved=0`.
- This model is retained here for regression triage, even though the latest clean validation cleared the mixed-state condition.

## Validation / retest workflow on macOS

a) Build and deploy:

```bash
scripts/deploy_oc_test.sh
```

`deploy_oc_test.sh` now includes deep source tracing in normal flow by default (pre-retest should not silently skip it).

b) Inspect Marvell history/user-path references and exact stale dev-path refs (compact):

```bash
scripts/inspect_marvell_history.sh --repo-root "$PWD"
```

c) Optional root-owned staging (dry-run must distinguish current source from any existing destination):

```bash
scripts/stage_marvell_root_owned.sh
```

d) Optional dry-run cleanup:

```bash
scripts/cleanup_marvell_auxkc.sh
```

e) Optional apply cleanup:

```bash
scripts/cleanup_marvell_auxkc.sh --apply
```

f) Reboot

g) Compact post-boot runtime collection:

```bash
scripts/trace_marvell_boot_runtime.sh
```

For a broader low-level IORegistry grep, opt in explicitly:

```bash
scripts/trace_marvell_boot_runtime.sh --verbose-ioreg
```

Optional deep tracing rerun (manual):

```bash
scripts/trace_marvell_sources.sh \
  --efi-mount /Volumes/EFI \
  --config /Volumes/EFI/EFI/OC/config.plist \
  --built-kext "$PWD/out/Debug/MarvellW8897Kext.kext" \
  --copied-kext /Volumes/EFI/EFI/OC/Kexts/MarvellW8897Kext.kext \
  --obj-dir "$PWD/out/obj"
```

## Goal

These scripts provide pre-retest deploy/runtime diagnostics and fallback cleanup/staging helpers for Marvell-specific boot-path issues.

## Resolved state (latest clean macOS validation)

The previously suspected kernelmanager/kcgen/history mixed-state involving user-owned `/Users/.../MarvellW8897Kext.kext` references is now considered **cleared** in the latest clean validation run.

Final acceptance criteria met:

- loaded kext is `brainworks.driver.MarvellW8897 (1.0.0)`
- loaded UUID matches built UUID
- IORegistry shows `MarvellW8897Controller` active
- no Marvell user-path references under `/Users/.../MarvellW8897...kext`
- no `kernelmanager_helper` Marvell ownership/validation failures
- EFI mounted, OpenCore parse success, copied EFI kext verification available

## If issue reappears

Use this compact triage order:

1. `scripts/trace_marvell_boot_runtime.sh`
2. `scripts/inspect_marvell_history.sh --strict-users --strict-km-fail`
3. Review C/E serialized refs before treating D as active-state dirtiness
4. `scripts/stage_marvell_root_owned.sh`
5. `scripts/cleanup_marvell_auxkc.sh`
