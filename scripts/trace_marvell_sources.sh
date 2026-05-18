#!/usr/bin/env bash
set -euo pipefail

PLIST_BUDDY="/usr/libexec/PlistBuddy"
MARVELL_ID_REGEX='brainworks\.driver\.MarvellW8897|brainworks\.MarvellW8897|MarvellW8897Kext'
STALE_DEV_KEXT_PATH="${STALE_DEV_KEXT_PATH:-/Users/<account>/src/MarvellW8897/out/Debug/MarvellW8897Kext.kext}"
D_LOG_WINDOW="last boot"

EFI_MOUNT=""
CONFIG_PLIST=""
BUILT_KEXT=""
COPIED_KEXT=""
OBJ_DIR=""

EFI_CONCLUSIVE=0
OC_PARSE_STATUS="inconclusive"
LOADED_UUID=""
BUILT_UUID=""
HAS_USER_DEV_REF=0
HAS_MARVELL_ZERO=0

usage() {
  cat <<'USAGE'
Gebruik:
  trace_marvell_sources.sh --efi-mount <pad> --config <config.plist> \
    --built-kext <pad/naar/MarvellW8897Kext.kext> \
    --copied-kext <pad/naar/EFI/OC/Kexts/MarvellW8897Kext.kext> \
    --obj-dir <xcode objroot>
USAGE
}

warn() { echo "WAARSCHUWING: $*" >&2; }
die() { echo "FOUT: $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Commando niet gevonden: $1"; }
print_limited_file() {
  local label="$1"
  local file="$2"
  local max="${3:-40}"
  echo "$label"
  if [[ -s "$file" ]]; then
    head -n "$max" "$file" | sed 's/^/  /'
    local total
    total="$(wc -l <"$file" | awk '{print $1}')"
    if [[ "$total" -gt "$max" ]]; then
      echo "  ... truncated ($((total-max)) extra lines)"
    fi
  else
    echo "  none"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --efi-mount) EFI_MOUNT="$2"; shift 2 ;;
    --config) CONFIG_PLIST="$2"; shift 2 ;;
    --built-kext) BUILT_KEXT="$2"; shift 2 ;;
    --copied-kext) COPIED_KEXT="$2"; shift 2 ;;
    --obj-dir) OBJ_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Onbekend argument: $1" ;;
  esac
done

[[ -n "$EFI_MOUNT" ]] || die "--efi-mount ontbreekt"
[[ -n "$CONFIG_PLIST" ]] || die "--config ontbreekt"
[[ -n "$BUILT_KEXT" ]] || die "--built-kext ontbreekt"
[[ -n "$COPIED_KEXT" ]] || die "--copied-kext ontbreekt"
[[ -n "$OBJ_DIR" ]] || die "--obj-dir ontbreekt"

need_cmd find
need_cmd grep
need_cmd sed
need_cmd awk
need_cmd stat
need_cmd plutil
need_cmd shasum
need_cmd strings
[[ -x "$PLIST_BUDDY" ]] || die "PlistBuddy niet gevonden: $PLIST_BUDDY"

plist_get() { "$PLIST_BUDDY" -c "Print :$2" "$1" 2>/dev/null || true; }
file_sha() { [[ -f "$1" ]] && shasum -a 256 "$1" | awk '{print $1}'; }
file_mtime() { [[ -e "$1" ]] && stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %z' "$1" 2>/dev/null; }
file_owner() { [[ -e "$1" ]] && stat -f '%u:%g %Sp' "$1" 2>/dev/null; }
file_uuid() { [[ -f "$1" ]] && command -v dwarfdump >/dev/null 2>&1 && dwarfdump --uuid "$1" 2>/dev/null | awk 'NR==1{print $2}'; }

print_path_meta() {
  local p="$1"
  echo "  path: $p"
  echo "  owner/mode: $(file_owner "$p")"
  echo "  mtime: $(file_mtime "$p")"
  [[ -f "$p" ]] && echo "  sha256: $(file_sha "$p")"
}

report_efi_state() {
  echo "EFI mount/status"
  echo "  requested mount: $EFI_MOUNT"
  if mount | grep -E " on $EFI_MOUNT " >/dev/null 2>&1; then
    EFI_CONCLUSIVE=1
    echo "  mounted: ja"
    mount | grep -E " on $EFI_MOUNT " | sed 's/^/  mount: /'
  else
    EFI_CONCLUSIVE=0
    echo "  mounted: nee (inconclusive voor EFI-gebaseerde afwezigheidsclaims)"
  fi

  if command -v diskutil >/dev/null 2>&1; then
    echo "  EFI-achtige volumes (diskutil list):"
    diskutil list 2>/dev/null | grep -i 'efi' | sed 's/^/    /' || true
  fi
}

report_generated_kmod() {
  echo "Generated KMOD source"
  local info_src
  info_src="$(find "$OBJ_DIR" -type f -name 'MarvellW8897Kext_info.c' -print 2>/dev/null | head -n 1 || true)"
  if [[ -z "$info_src" ]]; then
    echo "  niet gevonden onder $OBJ_DIR"
    return 0
  fi
  echo "  path: $info_src"
  grep -nE 'KMOD_EXPLICIT_DECL|KMOD_DECL' "$info_src" | sed 's/^/  /' || true
}

report_identity_pair() {
  local label="$1"
  local kext="$2"
  local plist="$kext/Contents/Info.plist"
  local exe="$kext/Contents/MacOS/MarvellW8897Kext"
  echo "$label"
  if [[ ! -d "$kext" ]]; then
    echo "  ontbreekt: $kext"
    return 0
  fi
  print_path_meta "$kext"
  if [[ -f "$plist" ]]; then
    echo "  CFBundleIdentifier: $(plist_get "$plist" CFBundleIdentifier)"
    echo "  CFBundleVersion: $(plist_get "$plist" CFBundleVersion)"
    echo "  OSBundleCompatibleVersion: $(plist_get "$plist" OSBundleCompatibleVersion)"
  else
    echo "  plist ontbreekt: $plist"
  fi
  if [[ -f "$exe" ]]; then
    echo "  exe_uuid: $(file_uuid "$exe")"
    echo "  exe_sha256: $(file_sha "$exe")"
  else
    echo "  executable ontbreekt: $exe"
  fi
}

count_oc_entries() {
  local cfg="$1"
  [[ -f "$cfg" ]] || return 2
  python3 - "$cfg" <<'PY'
import plistlib, sys
p = sys.argv[1]
with open(p, 'rb') as f:
    pl = plistlib.load(f)
adds = (((pl or {}).get('Kernel') or {}).get('Add') or [])
count = 0
for e in adds:
    if not isinstance(e, dict):
        continue
    joined = ' '.join(str(e.get(k,'')) for k in ('BundlePath','ExecutablePath','PlistPath','Comment'))
    if ('MarvellW8897Kext' in joined or 'brainworks.driver.MarvellW8897' in joined or 'brainworks.MarvellW8897' in joined):
        count += 1
print(count)
PY
}

report_loaded_kext() {
  echo "Loaded kext info"
  if command -v kmutil >/dev/null 2>&1; then
    local line
    line="$(kmutil showloaded 2>/dev/null | grep -E 'brainworks\.driver\.MarvellW8897|brainworks\.MarvellW8897' | head -n 1 || true)"
    if [[ -n "$line" ]]; then
      echo "  $line"
      LOADED_UUID="$(echo "$line" | grep -Eo '[0-9A-Fa-f-]{36}' | head -n 1 || true)"
      [[ -n "$LOADED_UUID" ]] && echo "  loaded_uuid: $LOADED_UUID"
    else
      echo "  geen Marvell regel in kmutil showloaded"
    fi
  else
    echo "  kmutil niet beschikbaar"
  fi
}

report_kcgen_refs() {
  local out="$1"
  local out_user="$2"
  echo "kcgen/history Marvell references"
  local found=0
  while IFS= read -r p; do
    found=1
    print_path_meta "$p"
    plutil -convert xml1 -o - "$p" 2>/dev/null | grep -nE "$MARVELL_ID_REGEX" | sed 's/^/    /' || true
    while IFS= read -r devpath; do
      [[ -n "$devpath" ]] || continue
      echo "    referenced_path: $devpath"
      echo "$devpath" >>"$out"
      if [[ "$devpath" == /Users/* ]]; then
        HAS_USER_DEV_REF=1
        echo "$devpath" >>"$out_user"
      fi
    done < <(plutil -convert xml1 -o - "$p" 2>/dev/null | grep -Eo '/[^<"]*MarvellW8897[^<"]*\.kext[^<"]*' || true)
  done < <(find /private/var/db/KernelExtensionManagement -type f -name 'com.apple.kcgen.instructions.plist' -print 2>/dev/null)

  if [[ "$found" -eq 0 ]]; then
    echo "  geen kcgen instructions gevonden"
  fi
}

collect_kernelmanager_marvell_failures() {
  local out="$1"
  if ! command -v log >/dev/null 2>&1; then
    return 0
  fi
  log show --last boot --style compact --predicate 'eventMessage CONTAINS "kernelmanager_helper" OR eventMessage CONTAINS "brainworks.driver.MarvellW8897"' 2>/dev/null | \
    grep -E 'MarvellW8897|Invalid ownership|failed to realize extension|stashed instructions|from history' | \
    tail -n 80 >"$out" || true
}

collect_exact_stale_dev_path_refs() {
  local out="$1"
  local roots=(
    "/private/var/db/KernelExtensionManagement"
    "/private/var/db/KernelCollections"
    "/System/Volumes/Preboot"
    "/Library/Extensions"
    "/System/Library/Extensions"
    "/Library/StagedExtensions"
  )

  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      grep -n -I -F "$STALE_DEV_KEXT_PATH" "$f" 2>/dev/null | sed "s#^#$f:#" >>"$out" || true
    done < <(find "$r" -type f \( -name '*.plist' -o -name '*.txt' -o -name '*.log' -o -name '*.db' -o -name '*.json' -o -name '*.kc' -o -name '*.cache' \) -print 2>/dev/null)

    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      strings "$f" 2>/dev/null | grep -F "$STALE_DEV_KEXT_PATH" | sed "s#^#$f:STR:#" >>"$out" || true
    done < <(find "$r" -type f \( -name '*.kc' -o -name '*.img4' -o -name '*.cache' \) -print 2>/dev/null)
  done
}


scan_marvell_candidates() {
  local out_marvell="$1"
  local out_marvell_zero="$2"

  local roots=(
    "/private/var/db/KernelExtensionManagement"
    "/private/var/db/KernelCollections"
    "/System/Volumes/Preboot"
    "/Library/Extensions"
    "/System/Library/Extensions"
    "/Library/StagedExtensions"
  )

  echo "Marvell candidate paths"
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      echo "$p" >>"$out_marvell"

      local zero_here=0
      if [[ -d "$p" ]]; then
        if grep -R -n -I -E "$MARVELL_ID_REGEX" "$p" >/dev/null 2>&1; then :; fi
        if grep -R -n -I '0\.0\.1' "$p" >/dev/null 2>&1; then
          zero_here=1
        fi
      elif [[ -f "$p" ]]; then
        if strings "$p" 2>/dev/null | grep -E "$MARVELL_ID_REGEX" >/dev/null 2>&1; then :; fi
        if strings "$p" 2>/dev/null | grep '0\.0\.1' >/dev/null 2>&1; then
          zero_here=1
        fi
      fi

      if [[ "$zero_here" -eq 1 ]]; then
        HAS_MARVELL_ZERO=1
        echo "$p" >>"$out_marvell_zero"
      fi
    done < <(
      {
        find "$r" -iname '*MarvellW8897*' -print 2>/dev/null || true
        grep -R -l -I -E "$MARVELL_ID_REGEX" "$r" 2>/dev/null || true
      } | awk '!seen[$0]++'
    )
  done
}

echo
echo "=== Marvell boot-path diagnostic report ==="
echo "EFI mount: $EFI_MOUNT"
echo "OpenCore config: $CONFIG_PLIST"
echo "Built kext: $BUILT_KEXT"
echo "Copied kext: $COPIED_KEXT"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/marvell-trace.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
MARVELL_PATHS="$TMP_DIR/marvell_paths.txt"
MARVELL_ZERO_PATHS="$TMP_DIR/marvell_zero_paths.txt"
KCGEN_REFERENCED_PATHS="$TMP_DIR/kcgen_refs.txt"
C_USER_PATHS="$TMP_DIR/c_users_refs.txt"
D_KM_FAILS="$TMP_DIR/d_kernelmanager_fails.txt"
EXACT_STALE_REFS="$TMP_DIR/exact_stale_dev_refs.txt"

report_efi_state
report_generated_kmod
report_identity_pair "Built kext identity" "$BUILT_KEXT"
report_identity_pair "Copied EFI kext identity" "$COPIED_KEXT"
report_loaded_kext
report_kcgen_refs "$KCGEN_REFERENCED_PATHS" "$C_USER_PATHS"
collect_kernelmanager_marvell_failures "$D_KM_FAILS"
collect_exact_stale_dev_path_refs "$EXACT_STALE_REFS"

if count_oc_entries "$CONFIG_PLIST" >/dev/null 2>&1; then
  OC_PARSE_STATUS="ok"
  OC_COUNT="$(count_oc_entries "$CONFIG_PLIST")"
  echo "OpenCore parse: ok"
  echo "OpenCore Marvell entries: $OC_COUNT"
else
  OC_PARSE_STATUS="inconclusive"
  echo "OpenCore parse: inconclusive (config ontbreekt of parse faalde)"
fi

scan_marvell_candidates "$MARVELL_PATHS" "$MARVELL_ZERO_PATHS"
sort -u "$MARVELL_PATHS" -o "$MARVELL_PATHS" 2>/dev/null || true
sort -u "$MARVELL_ZERO_PATHS" -o "$MARVELL_ZERO_PATHS" 2>/dev/null || true
sort -u "$C_USER_PATHS" -o "$C_USER_PATHS" 2>/dev/null || true
sort -u "$EXACT_STALE_REFS" -o "$EXACT_STALE_REFS" 2>/dev/null || true

print_limited_file "A) Marvell identity hits" "$MARVELL_PATHS"
print_limited_file "B) Marvell identity + 0.0.1 hits" "$MARVELL_ZERO_PATHS"
print_limited_file "C) HIGH PRIORITY ACTIVE-STATE - current serialized Marvell + /Users/... references" "$C_USER_PATHS"
print_limited_file "E) exact recurring stale dev path refs (dry-run discovery only): $STALE_DEV_KEXT_PATH" "$EXACT_STALE_REFS"
print_limited_file "D) LOG-HISTORY - kernelmanager_helper ownership/validation failures (Marvell, $D_LOG_WINDOW)" "$D_KM_FAILS"
if [[ -s "$D_KM_FAILS" ]]; then
  echo "  D note: log-history evidence should be tracked, but loaded UUID and C/E serialized refs decide whether active state is currently dirty."
  echo "  D triage hints: kernelmanager history, kcgen instructions, KEM/AuxKC metadata, prior manual kmutil load attempts, or stale validation records."
fi

echo "A) Generic 0.0.1 noise"
echo "  niet opgenomen in hoofdkandidaat telling; C/E current serialized refs zijn higher-priority active-state signalen."

BUILT_UUID="$(file_uuid "$BUILT_KEXT/Contents/MacOS/MarvellW8897Kext")"
if [[ -n "$LOADED_UUID" && -n "$BUILT_UUID" && "$LOADED_UUID" == "$BUILT_UUID" && ( "$HAS_USER_DEV_REF" -eq 1 || "$HAS_MARVELL_ZERO" -eq 1 ) ]]; then
  warn "MIXED STATE: loaded UUID == built UUID, maar kernelmanager/kcgen refereert user-dev path en/of Marvell+0.0.1 stale metadata."
fi

if [[ "$HAS_USER_DEV_REF" -eq 1 ]]; then
  warn "kcgen/history bevat verwijzing naar user-owned dev build pad onder /Users/..."
fi

if [[ "$EFI_CONCLUSIVE" -eq 0 || "$OC_PARSE_STATUS" != "ok" ]]; then
  warn "Resultaat deels inconclusive: EFI mount en/of OpenCore parse niet betrouwbaar beschikbaar."
fi

echo "Summary conclusie"
if [[ -s "$C_USER_PATHS" ]]; then
  echo "  TOP PRIORITY SIGNAL: C current serialized /Users refs aanwezig (active-state evidence)."
elif [[ -s "$EXACT_STALE_REFS" ]]; then
  echo "  TOP PRIORITY SIGNAL: exact stale dev path found in current serialized scan."
elif [[ -s "$D_KM_FAILS" ]]; then
  echo "  LOG-HISTORY SIGNAL: D aanwezig in $D_LOG_WINDOW; active loaded artifact must be assessed separately."
else
  echo "  TOP PRIORITY SIGNAL: C/E current serialized refs and D log-history not observed."
fi
if [[ "$HAS_MARVELL_ZERO" -eq 1 ]]; then
  echo "  SECONDARY SIGNAL: B aanwezig (Marvell + 0.0.1 stale metadata)."
else
  echo "  SECONDARY SIGNAL: B niet aangetroffen in huidige scan."
fi
