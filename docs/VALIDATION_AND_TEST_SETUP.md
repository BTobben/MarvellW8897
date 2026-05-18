# Validation and Test Setup

## Purpose

The current validation flow is intended to prove build, deployment, and boot-path correctness, not full driver functionality.

At the current repository stage, the goal is to prove that:

- the correct Marvell kext is built
- the correct kext is copied into the active EFI/OpenCore location
- OpenCore references the intended bundle
- the runtime-loaded kext matches the built artifact
- stale kernelmanager/kcgen/history references do not reintroduce the earlier mixed-state problem

## Context

Validation in this repository is macOS/OpenCore-oriented and focused on two layers:

1. **Build/deploy correctness**  
   Correct kext identity, correct copy into the intended EFI/OpenCore path, and parseable OpenCore config state.

2. **Boot/runtime evidence**  
   Loaded identity, UUID match, IORegistry presence, and absence of stale history, user-path, or ownership/validation failures.

Important environmental assumptions:

- the repository is built locally on the macOS test machine
- the Xcode project targets the current kext bundle identity/version used by the repo
- deployment happens through the repo scripts, not by ad-hoc manual copying
- the EFI partition used for OpenCore must be conclusively mounted before interpreting absence-based checks
- some machines may expose multiple EFI-like partitions, so the active EFI mount must be verified rather than assumed

For detailed script behavior and output categories, treat `scripts/MARVELL_DIAGNOSTICS.md` as the detailed runbook and source-of-truth for diagnostics semantics.

## Clean Validation Result Currently Recorded

The latest clean macOS validation met all of these acceptance criteria:

- loaded kext is `brainworks.driver.MarvellW8897 (1.0.0)`
- loaded UUID matches built UUID
- IORegistry shows `MarvellW8897Controller` active
- no Marvell user-path refs under `/Users/.../MarvellW8897...kext`
- no `kernelmanager_helper` Marvell ownership/validation failures
- EFI mounted, OpenCore parse success, copied EFI kext verification available

This is why the previously suspected kcgen/kernelmanager/history mixed-state is currently considered cleared in the documented clean validation context.

## Practical Build/Deploy/Test Flow

### 1. Build and deploy

From the repository root:

```bash
scripts/deploy_oc_test.sh
```

What this does at a high level:

* prepares a clean build output directory
* builds the kext target
* builds the local probe helper
* mounts the EFI partition
* copies the built kext into OpenCore's kext directory
* updates or verifies the Marvell `Kernel/Add` entry in `config.plist`
* runs compact history inspection and deep tracing as part of the deploy flow

### 2. Reboot into the OpenCore/macOS test boot

After deploy, reboot into the intended OpenCore boot path.

### 3. Collect post-boot runtime evidence

```bash
sudo bash scripts/trace_marvell_boot_runtime.sh
```

This is the primary runtime collector. It reports:

* git head
* built kext identity
* loaded `kmutil showloaded` line
* IORegistry hits for Marvell
* boot-log ownership/validation failures
* Marvell user-path references
* EFI/OpenCore conclusiveness state
* compact history inspection output
* deep source trace delegation

### 4. Enforce strict history checks

```bash
sudo bash scripts/inspect_marvell_history.sh --repo-root "$PWD" --strict-users --strict-km-fail --max-lines 3
```

Use this when you want the run to fail loudly if either of these regressions reappears:

* Marvell `/Users/...` history references
* `kernelmanager_helper` ownership/validation failures

## Key Scripts and Their Roles

### `scripts/deploy_oc_test.sh`

Use for the normal build + deploy + verify path.

### `scripts/trace_marvell_boot_runtime.sh`

Use immediately after boot for a one-shot runtime and boot-log capture.

### `scripts/inspect_marvell_history.sh`

Use for compact, Marvell-specific history inspection. Best for quick pass/fail triage.

### `scripts/trace_marvell_sources.sh`

Use for deeper boot-path tracing when the compact runtime collector is not enough.

### `scripts/stage_marvell_root_owned.sh`

Optional helper for staging a root-owned copy of the built kext for validation purposes.

Important:

* dry-run by default
* `--apply` required for actual changes
* does not mutate EFI/OpenCore config

### `scripts/cleanup_marvell_auxkc.sh`

Optional cleanup helper.

Important:

* dry-run by default
* only safe removable artifacts are auto-removable
* risky/system metadata paths remain manual-action-only

## Key Acceptance Criteria

A run is considered clean when all of the following are true:

* built identity is correct
* loaded identity is correct
* loaded UUID matches built UUID
* IORegistry shows the controller active
* EFI/OpenCore verification is conclusive
* no Marvell `/Users/...` refs remain
* no Marvell ownership/validation failures remain in `kernelmanager_helper`

## Common Pitfalls

### EFI not actually mounted

If EFI is not mounted, absence-based conclusions are inconclusive.

Typical symptom:

* runtime trace says EFI/OpenCore verification is inconclusive

Corrective action:

```bash
sudo diskutil mount disk0s1
```

Then rerun the runtime trace.

### Multiple EFI-like partitions exist

Do not assume the first EFI-looking partition is the active OpenCore one.

Always check:

* actual mount point
* active `config.plist`
* copied kext path used by the deploy script

### Stale history/cache records

Old kernelmanager or kcgen records can continue to emit warnings even when the currently loaded kext is otherwise correct.

### User-owned build-path coupling

`/Users/...` references can survive beyond a build and confuse later validation.

### Skipping strict checks

A non-strict run may look acceptable while still missing signals that should block confidence.

### Mixed-state regression reappears

Earlier in the project, the main problem was a kcgen/kernelmanager/history mixed-state where Marvell still pointed to a user-owned build path such as `/Users/.../out/Debug/MarvellW8897Kext.kext`.

If this reappears, use the fallback order below.

## Fallback Triage Order

1. `scripts/trace_marvell_boot_runtime.sh`
2. `scripts/inspect_marvell_history.sh --strict-users --strict-km-fail`
3. `scripts/stage_marvell_root_owned.sh`
4. `scripts/cleanup_marvell_auxkc.sh`
5. rerun `scripts/deploy_oc_test.sh` and capture output
6. reboot and collect runtime evidence again

Only use the staging and cleanup helpers when the runtime evidence actually points to a regression.