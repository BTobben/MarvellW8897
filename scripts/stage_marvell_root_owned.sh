#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
SRC_KEXT="${SRC_KEXT:-$REPO_ROOT/out/Debug/MarvellW8897Kext.kext}"
STAGE_BASE="${STAGE_BASE:-/private/var/root/MarvellW8897Staging}"
DEST_KEXT="${DEST_KEXT:-$STAGE_BASE/MarvellW8897Kext.kext}"
DO_APPLY=0

usage() {
  cat <<'USAGE'
Gebruik:
  stage_marvell_root_owned.sh [--src-kext <path>] [--dest-kext <path>] [--stage-base <path>] [--apply]

Standaard is DRY-RUN (geen wijzigingen).
Gebruik --apply om daadwerkelijk te kopiëren/chown/chmod.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src-kext) SRC_KEXT="$2"; shift 2 ;;
    --dest-kext) DEST_KEXT="$2"; shift 2 ;;
    --stage-base) STAGE_BASE="$2"; DEST_KEXT="$2/MarvellW8897Kext.kext"; shift 2 ;;
    --apply) DO_APPLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekend argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "FOUT: Commando niet gevonden: $1" >&2; exit 1; }; }
need_cmd stat
need_cmd shasum
need_cmd sudo
need_cmd rsync

plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }
exe_uuid() {
  if command -v dwarfdump >/dev/null 2>&1 && [[ -f "$1" ]]; then
    dwarfdump --uuid "$1" 2>/dev/null | awk 'NR==1{print $2}'
  fi
  return 0
}

exe_sha() {
  if [[ -f "$1" ]]; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  fi
  return 0
}

owner_mode() {
  if [[ -e "$1" ]]; then
    if stat --version >/dev/null 2>&1; then
      stat -c '%u:%g %A' "$1" 2>/dev/null || true
    else
      stat -f '%u:%g %Sp' "$1" 2>/dev/null || true
    fi
  fi
  return 0
}

report_bundle() {
  local label="$1"
  local kext="$2"
  local plist="$kext/Contents/Info.plist"
  local exe="$kext/Contents/MacOS/MarvellW8897Kext"

  echo "$label"
  echo "  path: $kext"
  if [[ ! -d "$kext" ]]; then
    echo "  status: missing"
    return
  fi

  echo "  owner/group + perms (bundle): $(owner_mode "$kext")"
  echo "  owner/group + perms (executable): $(owner_mode "$exe")"
  echo "  CFBundleIdentifier: $(plist_get "$plist" CFBundleIdentifier)"
  echo "  CFBundleVersion: $(plist_get "$plist" CFBundleVersion)"
  echo "  OSBundleCompatibleVersion: $(plist_get "$plist" OSBundleCompatibleVersion)"
  echo "  executable sha256: $(exe_sha "$exe")"
  echo "  executable uuid: $(exe_uuid "$exe")"
}

bundle_sha() {
  local exe="$1/Contents/MacOS/MarvellW8897Kext"
  exe_sha "$exe"
}

bundle_uuid() {
  local exe="$1/Contents/MacOS/MarvellW8897Kext"
  exe_uuid "$exe"
}

[[ -d "$SRC_KEXT" ]] || { echo "FOUT: bron kext niet gevonden: $SRC_KEXT" >&2; exit 2; }

PLIST_SRC="$SRC_KEXT/Contents/Info.plist"
EXE_SRC="$SRC_KEXT/Contents/MacOS/MarvellW8897Kext"
[[ -f "$PLIST_SRC" ]] || { echo "FOUT: bron Info.plist ontbreekt: $PLIST_SRC" >&2; exit 2; }
[[ -f "$EXE_SRC" ]] || { echo "FOUT: bron executable ontbreekt: $EXE_SRC" >&2; exit 2; }

SOURCE_SHA="$(bundle_sha "$SRC_KEXT")"
SOURCE_UUID="$(bundle_uuid "$SRC_KEXT")"
DEST_BEFORE_SHA=""
DEST_BEFORE_UUID=""
DEST_EXISTS_BEFORE=0
if [[ -d "$DEST_KEXT" ]]; then
  DEST_EXISTS_BEFORE=1
  DEST_BEFORE_SHA="$(bundle_sha "$DEST_KEXT")"
  DEST_BEFORE_UUID="$(bundle_uuid "$DEST_KEXT")"
fi

echo "=== stage_marvell_root_owned.sh ==="
echo "mode: $([[ "$DO_APPLY" -eq 1 ]] && echo APPLY || echo DRY-RUN)"
echo "source kext: $SRC_KEXT"
echo "dest kext  : $DEST_KEXT"
echo "note       : validation-only staging; raakt EFI/OpenCore config niet aan."

report_bundle "Current source bundle intended for staging" "$SRC_KEXT"

if [[ "$DEST_EXISTS_BEFORE" -eq 1 ]]; then
  report_bundle "Existing destination bundle before staging" "$DEST_KEXT"
  if [[ "$SOURCE_SHA" != "$DEST_BEFORE_SHA" || "$SOURCE_UUID" != "$DEST_BEFORE_UUID" ]]; then
    echo "WARNING: existing destination differs from current source; --apply would replace it."
  else
    echo "Existing destination matches current source by executable sha256/UUID."
  fi
else
  echo "Existing destination bundle before staging"
  echo "  path: $DEST_KEXT"
  echo "  status: missing; --apply would create it."
fi

if [[ "$DO_APPLY" -eq 1 ]]; then
  sudo mkdir -p "$(dirname "$DEST_KEXT")"
  sudo rm -rf "$DEST_KEXT"
  sudo rsync -a "$SRC_KEXT/" "$DEST_KEXT/"
  sudo chown -R root:wheel "$DEST_KEXT"
  sudo find "$DEST_KEXT" -type d -exec chmod 755 {} \;
  sudo find "$DEST_KEXT" -type f -exec chmod 644 {} \;
  if [[ -f "$DEST_KEXT/Contents/MacOS/MarvellW8897Kext" ]]; then
    sudo chmod 755 "$DEST_KEXT/Contents/MacOS/MarvellW8897Kext"
  fi

  report_bundle "Post-apply destination bundle" "$DEST_KEXT"
else
  echo "DRY-RUN: destination files are not modified."
  echo "DRY-RUN: no post-apply destination exists; values above are the current source and any pre-existing destination only."
fi
