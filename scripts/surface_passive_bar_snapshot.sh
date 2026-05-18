#!/usr/bin/env bash
set -euo pipefail

# Passive Surface/OpenCore diagnostic capture for MarvellW8897 BAR metadata.
# This script intentionally runs default local-test/marvell_probe only.
# It never passes --read-bar-reg, never writes MMIO, never deploys, never mounts EFI,
# and never changes machine power state.

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BUILD_DIR="${BUILD_DIR:-$REPO/out}"
REPORT_DIR="${REPORT_DIR:-$BUILD_DIR/diagnostics}"
BUILT_KEXT="${BUILT_KEXT:-$BUILD_DIR/Debug/MarvellW8897Kext.kext}"
PROBE_BIN="${PROBE_BIN:-$REPO/local-test/marvell_probe}"
PROBE_SRC="${PROBE_SRC:-$REPO/local-test/marvell_probe.cpp}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_PATH="$REPORT_DIR/surface-passive-bar-snapshot-$TIMESTAMP.txt"

mkdir -p "$REPORT_DIR"

have_cmd() { command -v "$1" >/dev/null 2>&1; }

exe_uuid() {
  local exe="$1"
  if have_cmd dwarfdump && [[ -f "$exe" ]]; then
    dwarfdump --uuid "$exe" 2>/dev/null | awk 'NR==1{print $2}'
  fi
}


file_mtime_epoch() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return 1
  fi
  if stat -f %m "$path" >/dev/null 2>&1; then
    stat -f %m "$path"
  else
    stat -c %Y "$path" 2>/dev/null
  fi
}

file_mtime_text() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "missing"
    return 0
  fi
  if stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$path" >/dev/null 2>&1; then
    stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%SZ' "$path"
  else
    date -u -r "$(file_mtime_epoch "$path")" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown"
  fi
}

file_owner_group_mode() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    echo "missing"
    return 0
  fi
  if stat -f '%Su:%Sg %Sp' "$path" >/dev/null 2>&1; then
    stat -f '%Su:%Sg %Sp' "$path"
  else
    stat -c '%U:%G %A' "$path" 2>/dev/null || echo "unknown"
  fi
}

file_owner_user() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    return 1
  fi
  if stat -f '%Su' "$path" >/dev/null 2>&1; then
    stat -f '%Su' "$path"
  else
    stat -c '%U' "$path" 2>/dev/null
  fi
}

file_sha256() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  if have_cmd shasum; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
  elif have_cmd openssl; then
    openssl dgst -sha256 "$path" 2>/dev/null | awk '{print $NF}'
  fi
}

plist_get() {
  local plist="$1"
  local key="$2"
  if [[ -f "$plist" && -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
  fi
}

run_section() {
  local title="$1"
  shift
  {
    echo
    echo "## $title"
    "$@"
  } >>"$REPORT_PATH" 2>&1 || {
    local status=$?
    echo "  command exited with status $status" >>"$REPORT_PATH"
  }
}

write_header() {
  {
    echo "# Surface passive BAR snapshot"
    echo "timestamp_utc: $TIMESTAMP"
    echo "repo: $REPO"
    echo "report: $REPORT_PATH"
    echo
    echo "Safety policy:"
    echo "  - passive/default diagnostics only"
    echo "  - does not invoke local-test/marvell_probe --read-bar-reg"
    echo "  - does not perform explicit BAR MMIO reads"
    echo "  - does not write MMIO, reset, upload firmware, enable interrupts, deploy, mount EFI, or change power state"
    echo "  - passive BAR metadata is structural only, not proof of mwifiex register semantics"
    echo "  - explicit BAR reads remain manual one-at-a-time commands outside this script"
  } >"$REPORT_PATH"
}

write_git_info() {
  if [[ -d "$REPO/.git" ]] && have_cmd git; then
    echo "branch: $(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    echo "head: $(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)"
    echo "status_short:"
    git -C "$REPO" status --short || true
  else
    echo "git unavailable or repo not found"
  fi
}

write_built_kext_info() {
  local plist="$BUILT_KEXT/Contents/Info.plist"
  local exe="$BUILT_KEXT/Contents/MacOS/MarvellW8897Kext"
  echo "built_kext: $BUILT_KEXT"
  echo "bundle_id: $(plist_get "$plist" CFBundleIdentifier)"
  echo "bundle_version: $(plist_get "$plist" CFBundleVersion)"
  echo "executable_uuid: $(exe_uuid "$exe")"
}

write_loaded_kext_info() {
  if have_cmd kmutil; then
    kmutil showloaded 2>/dev/null | grep -E 'brainworks\.driver\.MarvellW8897|brainworks\.MarvellW8897' || \
      echo "no loaded MarvellW8897 line found"
  else
    echo "kmutil unavailable"
  fi
}


write_probe_file_metadata() {
  echo "probe_bin: $PROBE_BIN"
  echo "probe_src: $PROBE_SRC"
  echo "current_user: ${USER:-$(id -un 2>/dev/null || echo unknown)}"

  echo "probe_bin_owner_group_mode: $(file_owner_group_mode "$PROBE_BIN")"
  echo "probe_bin_mtime_utc: $(file_mtime_text "$PROBE_BIN")"
  echo "probe_src_mtime_utc: $(file_mtime_text "$PROBE_SRC")"
  echo "probe_bin_sha256: $(file_sha256 "$PROBE_BIN")"

  if [[ ! -e "$PROBE_BIN" ]]; then
    echo "WARNING: probe binary is missing"
  elif [[ ! -x "$PROBE_BIN" ]]; then
    echo "WARNING: probe binary is not executable"
  fi

  local owner=""
  owner="$(file_owner_user "$PROBE_BIN" 2>/dev/null || true)"
  local current="${USER:-$(id -un 2>/dev/null || true)}"
  if [[ -n "$owner" && -n "$current" && "$owner" != "$current" ]]; then
    echo "WARNING: probe binary is owned by $owner, not current user $current"
  fi

  if [[ -e "$PROBE_BIN" && -e "$PROBE_SRC" ]]; then
    local bin_mtime=""
    local src_mtime=""
    bin_mtime="$(file_mtime_epoch "$PROBE_BIN" 2>/dev/null || true)"
    src_mtime="$(file_mtime_epoch "$PROBE_SRC" 2>/dev/null || true)"
    if [[ -n "$bin_mtime" && -n "$src_mtime" && "$src_mtime" -gt "$bin_mtime" ]]; then
      echo "WARNING: probe source is newer than probe binary; rebuild may be stale"
    fi
  fi
}

write_probe_default() {
  echo "probe: $PROBE_BIN"
  echo "note: running default probe only; no --read-bar-reg argument is used"
  echo "note: passive BAR metadata is structural only and does not prove semantic register identity"
  if [[ -x "$PROBE_BIN" ]]; then
    "$PROBE_BIN"
  else
    echo "probe not executable or missing"
  fi
}

write_marvell_logs() {
  if have_cmd log; then
    log show --last boot --style compact --predicate 'eventMessage CONTAINS "MarvellW8897"' 2>/dev/null | tail -n 160 || true
  else
    echo "log unavailable"
  fi
}

write_ioreg_compact() {
  if have_cmd ioreg; then
    ioreg -r -c MarvellW8897Controller -l -w0 2>/dev/null | awk '
      /\+-o / { print $0 }
      /"IOClass" =/ || /"CFBundleIdentifier" =/ || /"IOUserClientClass" =/ { print $0 }
    ' | head -n 80 || true
  else
    echo "ioreg unavailable"
  fi
}

write_header
run_section "Git state" write_git_info
run_section "Built kext identity" write_built_kext_info
run_section "Loaded kext identity" write_loaded_kext_info
run_section "Probe binary freshness" write_probe_file_metadata
run_section "Default local-test probe output" write_probe_default
run_section "Marvell IORegistry compact view" write_ioreg_compact
run_section "Marvell logs from last boot" write_marvell_logs

{
  echo
  echo "# End of passive snapshot"
  echo "Manual explicit BAR reads, if needed, must be run separately and one at a time, for example:"
  echo "  ./local-test/marvell_probe --read-bar-reg <bar> <offset>"
  echo "Do not automate or loop explicit BAR reads on the Surface target."
} >>"$REPORT_PATH"

echo "Passive Surface BAR snapshot written to: $REPORT_PATH"
