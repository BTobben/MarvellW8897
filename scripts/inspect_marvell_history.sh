#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$PWD}"
STRICT_USERS=0
STRICT_KM_FAIL=0
MAX_LINES=5
STALE_DEV_KEXT_PATH="${STALE_DEV_KEXT_PATH:-/Users/<account>/src/MarvellW8897/out/Debug/MarvellW8897Kext.kext}"

MARVELL_RE='brainworks\.driver\.MarvellW8897|brainworks\.MarvellW8897|MarvellW8897Kext'
USERS_RE='/Users/.*/MarvellW8897[^[:space:]<"]*\.kext'

usage() {
  cat <<'USAGE'
Gebruik:
  inspect_marvell_history.sh [--repo-root <path>] [--strict-users] [--strict-km-fail] [--max-lines <n>]

- Marvell-only inspector for KEM/KC/Preboot/Staged paths
- exits non-zero with --strict-users when current serialized /Users/.../MarvellW8897...kext refs are found
- exits non-zero with --strict-km-fail when D log-history Marvell kernelmanager ownership/validation failures are found
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root) REPO_ROOT="$2"; shift 2 ;;
    --strict-users) STRICT_USERS=1; shift ;;
    --strict-km-fail) STRICT_KM_FAIL=1; shift ;;
    --max-lines) MAX_LINES="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Onbekend argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "FOUT: Commando niet gevonden: $1" >&2; exit 1; }; }
need_cmd find
need_cmd grep
need_cmd awk
need_cmd sed
need_cmd strings
need_cmd stat

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/marvell-inspect.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

A_PATHS="$TMP_DIR/a_paths.txt"   # Marvell identity hits
B_PATHS="$TMP_DIR/b_paths.txt"   # Marvell + 0.0.1
C_LINES="$TMP_DIR/c_lines.txt"   # current serialized Marvell + /Users path refs
KEXT_PATHS="$TMP_DIR/kext_paths.txt"
EXACT_STALE_LINES="$TMP_DIR/exact_stale_lines.txt" # exact recurring stale dev path refs
D_LINES="$TMP_DIR/d_lines.txt"   # log-history kernelmanager ownership/validation failures
D_LOG_WINDOW="unavailable"
D_LOG_INCONCLUSIVE=1

scan_roots=(
  "/private/var/db/KernelExtensionManagement"
  "/private/var/db/KernelCollections"
  "/System/Volumes/Preboot"
  "/Library/StagedExtensions"
  "/Library/Extensions"
  "/System/Library/Extensions"
)

echo "=== Marvell history/user-path inspector ==="
echo "repo root: $REPO_ROOT"
echo "D log window: reported in D section after log availability check"
echo "exact stale dev path probe: $STALE_DEV_KEXT_PATH"

grep_marvell_in_file() {
  local f="$1"
  grep -n -I -E "$MARVELL_RE" "$f" 2>/dev/null || true
}

for r in "${scan_roots[@]}"; do
  [[ -d "$r" ]] || continue

  # direct Marvell filenames
  find "$r" -iname '*MarvellW8897*' -print 2>/dev/null >>"$A_PATHS" || true

  # text-like files first
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    exact_hits="$(grep -n -I -F "$STALE_DEV_KEXT_PATH" "$f" 2>/dev/null || true)"
    if [[ -n "$exact_hits" ]]; then
      echo "$exact_hits" | head -n "$MAX_LINES" | sed "s#^#$f:#" >>"$EXACT_STALE_LINES"
    fi

    local_hits="$(grep_marvell_in_file "$f")"
    if [[ -n "$local_hits" ]]; then
      echo "$f" >>"$A_PATHS"
      echo "$local_hits" | head -n "$MAX_LINES" | sed "s#^#$f:#" >>"$TMP_DIR/a_snips.txt"

      if grep -n -I '0\.0\.1' "$f" >/dev/null 2>&1; then
        echo "$f" >>"$B_PATHS"
      fi

      users_hits="$(grep -n -I -E "$USERS_RE" "$f" 2>/dev/null || true)"
      if [[ -n "$users_hits" ]]; then
        echo "$users_hits" | head -n "$MAX_LINES" | sed "s#^#$f:#" >>"$C_LINES"
      fi

      grep -o -E '/[^[:space:]<"]*MarvellW8897[^[:space:]<"]*\.kext[^[:space:]<"]*' "$f" 2>/dev/null >>"$KEXT_PATHS" || true
    fi
  done < <(find "$r" -type f \( -name '*.plist' -o -name '*.txt' -o -name '*.log' -o -name '*.db' -o -name '*.json' -o -name '*.kc' -o -name '*.cache' \) -print 2>/dev/null)

  # binary strings fallback for marvell ids (compact)
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if strings "$f" 2>/dev/null | grep -F "$STALE_DEV_KEXT_PATH" >/dev/null 2>&1; then
      strings "$f" 2>/dev/null | grep -F "$STALE_DEV_KEXT_PATH" | head -n "$MAX_LINES" | sed "s#^#$f:STR:#" >>"$EXACT_STALE_LINES" || true
    fi

    if strings "$f" 2>/dev/null | grep -E "$MARVELL_RE" >/dev/null 2>&1; then
      echo "$f" >>"$A_PATHS"
      if strings "$f" 2>/dev/null | grep '0\.0\.1' >/dev/null 2>&1; then
        echo "$f" >>"$B_PATHS"
      fi
      strings "$f" 2>/dev/null | grep -E "$USERS_RE" | head -n "$MAX_LINES" | sed "s#^#$f:STR:#" >>"$C_LINES" || true
    fi
  done < <(find "$r" -type f \( -name '*.kc' -o -name '*.img4' -o -name '*.cache' \) -print 2>/dev/null)
done

if command -v log >/dev/null 2>&1; then
  D_LOG_WINDOW="last boot"
  D_LOG_INCONCLUSIVE=0
  log show --last boot --style compact --predicate 'eventMessage CONTAINS "kernelmanager_helper" OR eventMessage CONTAINS "brainworks.driver.MarvellW8897"' 2>/dev/null | \
    grep -E 'MarvellW8897|Invalid ownership|failed to realize extension|stashed instructions|from history' | \
    tail -n 120 >"$D_LINES" || true
fi

sort -u "$A_PATHS" -o "$A_PATHS" 2>/dev/null || true
sort -u "$B_PATHS" -o "$B_PATHS" 2>/dev/null || true
sort -u "$KEXT_PATHS" -o "$KEXT_PATHS" 2>/dev/null || true
sort -u "$EXACT_STALE_LINES" -o "$EXACT_STALE_LINES" 2>/dev/null || true

echo "A) Marvell identity hits (compact paths)"
if [[ -s "$A_PATHS" ]]; then
  sed 's/^/  /' "$A_PATHS"
else
  echo "  none"
fi

echo "B) Marvell identity + 0.0.1 hits"
if [[ -s "$B_PATHS" ]]; then
  sed 's/^/  /' "$B_PATHS"
else
  echo "  none"
fi

echo "C) current serialized Marvell identity + /Users/... references"
if [[ -s "$C_LINES" ]]; then
  sed 's/^/  /' "$C_LINES"
else
  echo "  none"
fi

echo "E) exact recurring stale dev path references (dry-run discovery only)"
if [[ -s "$EXACT_STALE_LINES" ]]; then
  sed 's/^/  /' "$EXACT_STALE_LINES"
else
  echo "  none"
fi

echo "D) log-history kernelmanager_helper Marvell ownership/validation failures ($D_LOG_WINDOW)"
if [[ "$D_LOG_INCONCLUSIVE" -eq 1 ]]; then
  echo "  inconclusive (macOS log command unavailable or log query not run)"
elif [[ -s "$D_LINES" ]]; then
  sed 's/^/  /' "$D_LINES"
  echo "  note: D is log-history evidence from $D_LOG_WINDOW; it is not by itself proof that the active loaded kext is wrong."
  echo "  triage hints: check C/E serialized refs first, then KEM/AuxKC kcgen instructions, prior manual kmutil load attempts, kernelmanager history, and stale validation records."
else
  echo "  none"
fi

echo "Ownership for Marvell kext paths outside repo build dir"
if [[ -s "$KEXT_PATHS" ]]; then
  while IFS= read -r kp; do
    [[ -e "$kp" ]] || continue
    if [[ "$kp" == "$REPO_ROOT/out/"* ]]; then
      continue
    fi
    owner="$(stat -f '%u:%g %Sp' "$kp" 2>/dev/null || true)"
    mtime="$(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S %z' "$kp" 2>/dev/null || true)"
    echo "  $kp"
    echo "    owner/mode: $owner"
    echo "    mtime: $mtime"
  done <"$KEXT_PATHS"
else
  echo "  none"
fi

if [[ "$STRICT_USERS" -eq 1 && -s "$C_LINES" ]]; then
  echo "RESULT: FAIL (current serialized Marvell /Users path reference present)" >&2
  exit 3
fi

if [[ "$STRICT_KM_FAIL" -eq 1 ]]; then
  if [[ "$D_LOG_INCONCLUSIVE" -eq 1 ]]; then
    echo "RESULT: FAIL (D log-history check inconclusive in strict mode)" >&2
    exit 4
  fi
  if [[ -s "$D_LINES" ]]; then
    echo "RESULT: FAIL (log-history D signal present in $D_LOG_WINDOW; active loaded artifact must be assessed separately)" >&2
    exit 4
  fi
fi

if [[ -s "$C_LINES" ]]; then
  echo "RESULT: WARN (current serialized Marvell /Users path references present; higher-priority active-state signal than D log-history)"
elif [[ -s "$EXACT_STALE_LINES" ]]; then
  echo "RESULT: WARN (exact stale dev path found in current scanned metadata; inspect E before treating D as log-only)"
elif [[ -s "$D_LINES" ]]; then
  echo "RESULT: WARN (log-history D signal present in $D_LOG_WINDOW; no current serialized /Users refs found by this inspector)"
else
  echo "RESULT: OK (no current serialized user-path refs; D log-history not observed or inconclusive as reported above)"
fi
