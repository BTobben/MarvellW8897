#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$PWD}"
BUILD_DIR="${BUILD_DIR:-$REPO/out}"
OBJ_DIR="${OBJ_DIR:-$BUILD_DIR/obj}"
BUILT_KEXT="${BUILT_KEXT:-$BUILD_DIR/Debug/MarvellW8897Kext.kext}"
EFI_MOUNT="${EFI_MOUNT:-/Volumes/EFI}"
CONFIG_PLIST="${CONFIG_PLIST:-$EFI_MOUNT/EFI/OC/config.plist}"
COPIED_KEXT="${COPIED_KEXT:-$EFI_MOUNT/EFI/OC/Kexts/MarvellW8897Kext.kext}"
TRACE_SCRIPT="${TRACE_SCRIPT:-$REPO/scripts/trace_marvell_sources.sh}"
INSPECT_SCRIPT="${INSPECT_SCRIPT:-$REPO/scripts/inspect_marvell_history.sh}"

EFI_CONCLUSIVE=0
OC_PARSE_CONCLUSIVE=0
COPIED_CONCLUSIVE=0
HAS_D_FAILS=0
LOG_USER_PATH_HITS=0
SERIALIZED_USER_PATH_HITS=0
LOADED_UUID_MATCH="unknown"
STALE_DEV_KEXT_PATH="${STALE_DEV_KEXT_PATH:-/Users/<account>/src/MarvellW8897/out/Debug/MarvellW8897Kext.kext}"
VERBOSE_IOREG=0
LOADED_KEXT_PRESENT="unknown"
CONTROLLER_PRESENT="unknown"
D_SIGNAL="inconclusive"
EXACT_STALE_HITS=0

usage() {
  cat <<'USAGE'
Gebruik:
  trace_marvell_boot_runtime.sh [--verbose-ioreg]

Default output is compact. Use --verbose-ioreg to include the older broad IORegistry Marvell grep.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --verbose-ioreg) VERBOSE_IOREG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekend argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "FOUT: Commando niet gevonden: $1" >&2; exit 1; }; }
need_cmd git
need_cmd shasum
need_cmd plutil

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
exe_uuid() {
  if command -v dwarfdump >/dev/null 2>&1 && [[ -f "$1" ]]; then
    dwarfdump --uuid "$1" 2>/dev/null | awk 'NR==1{print $2}'
  fi
  return 0
}
file_sha() { [[ -f "$1" ]] && shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' || true; }

printf '=== Marvell boot runtime trace ===\n'
if [[ -d "$REPO/.git" ]]; then
  echo "git head: $(git -C "$REPO" rev-parse --short HEAD)"
else
  echo "git head: repo niet gevonden onder $REPO"
fi

BUILT_PLIST="$BUILT_KEXT/Contents/Info.plist"
BUILT_EXE="$BUILT_KEXT/Contents/MacOS/MarvellW8897Kext"

BUILT_SHA="$(file_sha "$BUILT_EXE")"
BUILT_UUID="$(exe_uuid "$BUILT_EXE")"

echo "Built kext"
echo "  path: $BUILT_KEXT"
echo "  CFBundleIdentifier: $(plist_get "$BUILT_PLIST" CFBundleIdentifier)"
echo "  CFBundleVersion: $(plist_get "$BUILT_PLIST" CFBundleVersion)"
echo "  OSBundleCompatibleVersion: $(plist_get "$BUILT_PLIST" OSBundleCompatibleVersion)"
echo "  executable sha256: $BUILT_SHA"
echo "  executable uuid: $BUILT_UUID"

echo "Loaded kext (kmutil showloaded)"
if command -v kmutil >/dev/null 2>&1; then
  KMUTIL_LINE="$(kmutil showloaded 2>/dev/null | grep -E 'brainworks\.driver\.MarvellW8897|brainworks\.MarvellW8897' | head -n 1 || true)"
  if [[ -n "$KMUTIL_LINE" ]]; then
    LOADED_KEXT_PRESENT="yes"
    echo "  $KMUTIL_LINE"
    if [[ -n "$BUILT_UUID" && "$KMUTIL_LINE" == *"$BUILT_UUID"* ]]; then
      LOADED_UUID_MATCH="yes"
    elif [[ -n "$BUILT_UUID" ]]; then
      LOADED_UUID_MATCH="no-or-not-shown"
    fi
  else
    LOADED_KEXT_PRESENT="no"
    echo "  geen Marvell-regel"
  fi
else
  echo "  kmutil niet beschikbaar"
fi

echo "IORegistry Marvell controller (compact)"
if command -v ioreg >/dev/null 2>&1; then
  IOREG_CONTROLLER="$(ioreg -r -c MarvellW8897Controller -l -w0 2>/dev/null || true)"
  if [[ -n "$IOREG_CONTROLLER" ]]; then
    CONTROLLER_PRESENT="yes"
    echo "  present: yes"
    echo "$IOREG_CONTROLLER" | awk '
      /\+-o / { print "  node: " $0 }
      /"IOClass" =/ || /"CFBundleIdentifier" =/ || /"CFBundleIdentifierKernel" =/ || /"IOUserClientClass" =/ || /"driver-child-bundle" =/ { print "  " $0 }
    ' | head -n 80
  else
    CONTROLLER_PRESENT="no"
    echo "  present: no"
  fi

  if [[ "$VERBOSE_IOREG" -eq 1 ]]; then
    echo "IORegistry Marvell verbose grep (--verbose-ioreg)"
    ioreg -l 2>/dev/null | grep -E 'Marvell|brainworks\.driver\.MarvellW8897' | head -n 120 || echo "  geen verbose ioreg hits"
  else
    echo "  verbose ioreg: skipped (use --verbose-ioreg for broad IORegistry grep)"
  fi
else
  echo "  ioreg niet beschikbaar"
fi

echo "Boot log Marvell ownership/validation failures (D log-history, last boot, compact)"
if command -v log >/dev/null 2>&1; then
  FAIL_LINES="$(log show --last boot --style compact --predicate 'eventMessage CONTAINS "kernelmanager_helper" OR eventMessage CONTAINS "brainworks.driver.MarvellW8897"' 2>/dev/null | \
    grep -E 'MarvellW8897|Invalid ownership|failed to realize extension|stashed instructions|from history|OSBundleCompatibleVersion' | \
    tail -n 80 || true)"
  if [[ -n "$FAIL_LINES" ]]; then
    HAS_D_FAILS=1
    D_SIGNAL="yes"
    echo "$FAIL_LINES"
  else
    D_SIGNAL="no"
    echo "  none"
  fi
else
  D_SIGNAL="inconclusive"
  echo "  log niet beschikbaar"
fi

echo "Marvell log-history user-path references (/Users/.../MarvellW8897...kext, last boot)"
if command -v log >/dev/null 2>&1; then
  LOG_USER_HITS="$(log show --last boot --style compact --predicate 'eventMessage CONTAINS "MarvellW8897"' 2>/dev/null | grep -E '/Users/.*/MarvellW8897[^[:space:]]*\.kext' | tail -n 20 || true)"
  if [[ -n "$LOG_USER_HITS" ]]; then
    LOG_USER_PATH_HITS=1
    echo "$LOG_USER_HITS" | sed 's/^/  /'
  else
    echo "  none"
  fi
else
  echo "  inconclusive (log command unavailable)"
fi

echo "Marvell current serialized user-path references (/Users/.../MarvellW8897...kext)"
echo "  priority: C current serialized refs are higher-priority active-state evidence than D log-history."
while IFS= read -r ip; do
  [[ -f "$ip" ]] || continue
  HITS="$(plutil -convert xml1 -o - "$ip" 2>/dev/null | grep -E '/Users/.*/MarvellW8897[^[:space:]<"]*\.kext' | head -n 10 || true)"
  if [[ -n "$HITS" ]]; then
    SERIALIZED_USER_PATH_HITS=1
    echo "  $ip"
    echo "$HITS" | sed 's/^/    /'
  fi
done < <(find /private/var/db/KernelExtensionManagement -type f -name 'com.apple.kcgen.instructions.plist' -print 2>/dev/null)
if [[ "$SERIALIZED_USER_PATH_HITS" -eq 0 ]]; then
  echo "  none"
fi

echo "EFI/OpenCore conclusiveness"
if mount | grep -E " on $EFI_MOUNT " >/dev/null 2>&1; then
  EFI_CONCLUSIVE=1
  echo "  EFI mounted: yes ($EFI_MOUNT)"
else
  EFI_CONCLUSIVE=0
  echo "  EFI mounted: no (inconclusive)"
fi

if [[ -f "$CONFIG_PLIST" ]] && plutil -lint "$CONFIG_PLIST" >/dev/null 2>&1; then
  OC_PARSE_CONCLUSIVE=1
  echo "  OpenCore config parse: success"
  plutil -convert xml1 -o - "$CONFIG_PLIST" 2>/dev/null | grep -nE 'MarvellW8897Kext|brainworks\.driver\.MarvellW8897' || echo "  OpenCore Marvell entry: none"
else
  OC_PARSE_CONCLUSIVE=0
  echo "  OpenCore config parse: inconclusive"
fi

if [[ -f "$COPIED_KEXT/Contents/Info.plist" && -f "$COPIED_KEXT/Contents/MacOS/MarvellW8897Kext" ]]; then
  COPIED_CONCLUSIVE=1
  echo "  copied EFI kext verification: available"
else
  COPIED_CONCLUSIVE=0
  echo "  copied EFI kext verification: inconclusive"
fi

if [[ "$EFI_CONCLUSIVE" -eq 0 || "$OC_PARSE_CONCLUSIVE" -eq 0 || "$COPIED_CONCLUSIVE" -eq 0 ]]; then
  echo "  RESULT: inconclusive; absence findings must not be treated as definitive."
else
  echo "  RESULT: conclusive checks available (EFI mount + OpenCore parse + copied kext)."
fi

echo "Exact recurring stale dev path discovery (current serialized metadata, dry-run only)"
while IFS= read -r ip; do
  [[ -f "$ip" ]] || continue
  HITS="$(plutil -convert xml1 -o - "$ip" 2>/dev/null | grep -F "$STALE_DEV_KEXT_PATH" | head -n 10 || true)"
  if [[ -n "$HITS" ]]; then
    EXACT_STALE_HITS=1
    echo "  $ip"
    echo "$HITS" | sed 's/^/    /'
  fi
done < <(find /private/var/db/KernelExtensionManagement -type f -name 'com.apple.kcgen.instructions.plist' -print 2>/dev/null)
if [[ "$EXACT_STALE_HITS" -eq 0 ]]; then
  echo "  none for $STALE_DEV_KEXT_PATH"
fi

echo "Selector-8 bring-up result evidence (local probe, if available)"
PROBE_BIN="$REPO/local-test/marvell_probe"
if [[ -x "$PROBE_BIN" ]]; then
  PROBE_OUTPUT="$($PROBE_BIN 2>/dev/null || true)"
  if [[ -n "$PROBE_OUTPUT" ]]; then
    echo "$PROBE_OUTPUT" | grep -E 'getDebugAbiInfo|getBringupResult|abi\[[0-9]+\]|bringup\[[0-9]+\]' | sed 's/^/  /' || echo "  no selector-8/debug ABI lines in probe output"
  else
    echo "  probe produced no output"
  fi
else
  echo "  local probe not executable: $PROBE_BIN"
fi

echo "Loaded artifact summary"
echo "  built-vs-loaded UUID match: $LOADED_UUID_MATCH"
if [[ "$EFI_CONCLUSIVE" -eq 1 && "$OC_PARSE_CONCLUSIVE" -eq 1 && "$COPIED_CONCLUSIVE" -eq 1 ]]; then
  echo "  EFI/OpenCore copied-kext checks: conclusive"
else
  echo "  EFI/OpenCore copied-kext checks: inconclusive"
fi

echo "Signal priority summary"
if [[ "$SERIALIZED_USER_PATH_HITS" -eq 1 ]]; then
  echo "  TOP PRIORITY: C current serialized user-path reference present."
elif [[ "$HAS_D_FAILS" -eq 1 || "$LOG_USER_PATH_HITS" -eq 1 ]]; then
  echo "  TOP PRIORITY: D/log-history signal present; active loaded artifact result is reported separately above."
  echo "  NOTE: do not treat runtime state as dirty solely from log-history D when loaded UUID matches built UUID and C serialized refs are absent."
  echo "  TRIAGE HINTS: inspect C/exact serialized refs, KEM/AuxKC kcgen instructions, prior manual kmutil load attempts, kernelmanager history, and stale validation records."
else
  echo "  TOP PRIORITY: C current serialized refs and D log-history signals not observed in this capture."
fi

RESULT="INCONCLUSIVE"
if [[ "$LOADED_KEXT_PRESENT" == "no" || "$CONTROLLER_PRESENT" == "no" || "$LOADED_UUID_MATCH" == "no-or-not-shown" || "$SERIALIZED_USER_PATH_HITS" -eq 1 || "$EXACT_STALE_HITS" -eq 1 ]]; then
  RESULT="FAIL"
elif [[ "$LOADED_KEXT_PRESENT" == "yes" && "$LOADED_UUID_MATCH" == "yes" && "$CONTROLLER_PRESENT" == "yes" && "$SERIALIZED_USER_PATH_HITS" -eq 0 && "$EXACT_STALE_HITS" -eq 0 && "$D_SIGNAL" == "no" && "$EFI_CONCLUSIVE" -eq 1 && "$OC_PARSE_CONCLUSIVE" -eq 1 && "$COPIED_CONCLUSIVE" -eq 1 ]]; then
  RESULT="OK"
elif [[ "$LOADED_KEXT_PRESENT" == "yes" && "$LOADED_UUID_MATCH" == "yes" && "$CONTROLLER_PRESENT" == "yes" && "$SERIALIZED_USER_PATH_HITS" -eq 0 && "$EXACT_STALE_HITS" -eq 0 && "$D_SIGNAL" == "yes" ]]; then
  RESULT="WARN"
fi

echo "Runtime validation summary:"
echo "  loaded kext: $LOADED_KEXT_PRESENT"
echo "  built-vs-loaded UUID match: $LOADED_UUID_MATCH"
echo "  controller present: $CONTROLLER_PRESENT"
echo "  current serialized C refs: $([[ "$SERIALIZED_USER_PATH_HITS" -eq 1 ]] && echo yes || echo no)"
echo "  exact stale E refs: $([[ "$EXACT_STALE_HITS" -eq 1 ]] && echo yes || echo no)"
echo "  D log-history signal: $D_SIGNAL"
echo "  EFI/OpenCore copied-kext checks: $([[ "$EFI_CONCLUSIVE" -eq 1 && "$OC_PARSE_CONCLUSIVE" -eq 1 && "$COPIED_CONCLUSIVE" -eq 1 ]] && echo conclusive || echo inconclusive)"
echo "  result: $RESULT"

if [[ -x "$INSPECT_SCRIPT" ]]; then
  echo
  "$INSPECT_SCRIPT" --repo-root "$REPO"
else
  echo "WAARSCHUWING: inspector script niet uitvoerbaar: $INSPECT_SCRIPT"
fi

if [[ -x "$TRACE_SCRIPT" ]]; then
  echo
  echo "Delegating to deep source tracer: $TRACE_SCRIPT"
  if ! "$TRACE_SCRIPT" --efi-mount "$EFI_MOUNT" --config "$CONFIG_PLIST" --built-kext "$BUILT_KEXT" --copied-kext "$COPIED_KEXT" --obj-dir "$OBJ_DIR"; then
    echo "WAARSCHUWING: deep source tracer failed or is unavailable in this environment"
  fi
else
  echo "WAARSCHUWING: trace script niet uitvoerbaar: $TRACE_SCRIPT"
fi
