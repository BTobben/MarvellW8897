#!/usr/bin/env bash
set -euo pipefail

DO_APPLY=0
BACKUP_ROOT="${BACKUP_ROOT:-$PWD/out/marvell_cleanup_backups}"
MARVELL_PAT='brainworks\.driver\.MarvellW8897|MarvellW8897Kext|brainworks\.MarvellW8897'

usage() {
  cat <<'USAGE'
Gebruik:
  cleanup_marvell_auxkc.sh [--apply] [--backup-root <dir>]

Standaard dry-run. Alleen met --apply wordt daadwerkelijk verwijderd.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) DO_APPLY=1; shift ;;
    --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekend argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

mkdir -p "$BACKUP_ROOT"

echo "=== cleanup_marvell_auxkc.sh ==="
echo "mode: $([[ "$DO_APPLY" -eq 1 ]] && echo APPLY || echo DRY-RUN)"
echo "backup root: $BACKUP_ROOT"

declare -a SAFE_REMOVE=()
declare -a MANUAL_ONLY=()

collect_candidates() {
  while IFS= read -r p; do [[ -n "$p" ]] && echo "$p"; done
}

while IFS= read -r p; do
  [[ -e "$p" ]] || continue
  case "$p" in
    */KernelExtensionManagement/AuxKC/*/StashedExtensions/*MarvellW8897*|*/Library/StagedExtensions/*MarvellW8897*)
      SAFE_REMOVE+=("$p")
      ;;
    *)
      MANUAL_ONLY+=("$p")
      ;;
  esac
done < <(
  {
    find /private/var/db/KernelExtensionManagement -iname '*MarvellW8897*' -print 2>/dev/null || true
    find /private/var/db/KernelCollections -iname '*MarvellW8897*' -print 2>/dev/null || true
    find /Library/StagedExtensions -iname '*MarvellW8897*' -print 2>/dev/null || true
    find /private/var/db/KernelExtensionManagement -type f -name 'com.apple.kcgen.instructions.plist' -print 2>/dev/null | while IFS= read -r ip; do
      if plutil -convert xml1 -o - "$ip" 2>/dev/null | grep -E "$MARVELL_PAT" >/dev/null 2>&1; then
        echo "$ip"
      fi
    done
  } | awk '!seen[$0]++'
)

echo "Safe removable Marvell artifacts:"
if [[ "${#SAFE_REMOVE[@]}" -eq 0 ]]; then
  echo "  none"
else
  printf '  %s\n' "${SAFE_REMOVE[@]}"
fi

echo "Manual-action-only Marvell references (risky/system metadata):"
if [[ "${#MANUAL_ONLY[@]}" -eq 0 ]]; then
  echo "  none"
else
  printf '  %s\n' "${MANUAL_ONLY[@]}"
fi

if [[ "$DO_APPLY" -ne 1 ]]; then
  echo "Dry-run complete. No removals performed."
  if [[ "${#MANUAL_ONLY[@]}" -gt 0 ]]; then
    echo "Manual plan suggested:"
    echo "  1) backup listed manual-action files"
    echo "  2) inspect for Marvell refs with: plutil -convert xml1 -o - <file> | grep -E '$MARVELL_PAT'"
    echo "  3) remove or regenerate only the Marvell-specific records"
  fi
  exit 0
fi

if [[ "${#SAFE_REMOVE[@]}" -eq 0 ]]; then
  echo "No safe removable Marvell artifacts found."
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S)"
RUN_BACKUP="$BACKUP_ROOT/$TS"
mkdir -p "$RUN_BACKUP"

echo "Applying safe removals (backup first):"
for p in "${SAFE_REMOVE[@]}"; do
  [[ -e "$p" ]] || continue
  rel="${p#/}"
  bkp="$RUN_BACKUP/$rel"
  mkdir -p "$(dirname "$bkp")"
  cp -R "$p" "$bkp"
  rm -rf "$p"
  echo "  removed: $p"
  echo "  backup : $bkp"
done

if [[ "${#MANUAL_ONLY[@]}" -gt 0 ]]; then
  echo "NOTE: manual-action-only paths were NOT removed automatically."
fi
