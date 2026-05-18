#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# MarvellW8897 OpenCore deploy helper
# ------------------------------------------------------------

EFI_DISK="${1:-}"
REPO="${REPO:-$HOME/src/MarvellW8897}"
SYNC_REF="${SYNC_REF:-}"

KEXT_NAME="MarvellW8897Kext.kext"
KEXT_EXEC="MarvellW8897Kext"

BUILD_DIR="$REPO/out"
OBJ_DIR="$BUILD_DIR/obj"
KEXT_SRC="$BUILD_DIR/Debug/$KEXT_NAME"
PROBE_SRC="$REPO/local-test/marvell_probe.cpp"
PROBE_BIN="$REPO/local-test/marvell_probe"

ENABLE_TEST_SIP="${ENABLE_TEST_SIP:-0}"
DO_BLESS="${DO_BLESS:-0}"
AUTO_REPAIR_EFI="${AUTO_REPAIR_EFI:-1}"
QUIET_BUILD="${QUIET_BUILD:-1}"
UNMOUNT_AFTER="${UNMOUNT_AFTER:-0}"
RUN_DEEP_TRACE="${RUN_DEEP_TRACE:-1}"
FAIL_ON_D="${FAIL_ON_D:-0}"

BUILD_LOG="$BUILD_DIR/xcodebuild.log"
PROBE_LOG="$BUILD_DIR/probe-build.log"
FSCK_LOG="$BUILD_DIR/efi-fsck.log"
TRACE_SCRIPT="$REPO/scripts/trace_marvell_sources.sh"
INSPECT_SCRIPT="$REPO/scripts/inspect_marvell_history.sh"

die() {
  echo "FOUT: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Commando niet gevonden: $1"
}

step() {
  echo
  echo "[$1] $2"
}

count_marvell_kernel_add_entries() {
  local cfg="$1"
  python3 - "$cfg" <<'PY'
import plistlib, sys

cfg = sys.argv[1]
try:
    with open(cfg, "rb") as f:
        pl = plistlib.load(f)
except Exception:
    print("INCONCLUSIVE_PARSE")
    sys.exit(3)

adds = (((pl or {}).get("Kernel") or {}).get("Add") or [])
count = 0
for e in adds:
    if not isinstance(e, dict):
        continue
    bp = str(e.get("BundlePath", ""))
    ep = str(e.get("ExecutablePath", ""))
    pp = str(e.get("PlistPath", ""))
    cm = str(e.get("Comment", ""))
    joined = " ".join([bp, ep, pp, cm]).lower()
    if "marvellw8897" in joined or "brainworks.driver.marvellw8897" in joined or "brainworks.marvellw8897" in joined:
        count += 1
print(count)
PY
}

need_cmd git
need_cmd diskutil
need_cmd mount_msdos
need_cmd xcodebuild
need_cmd clang++
need_cmd python3
need_cmd plutil
need_cmd fsck_msdos
need_cmd shasum

plist_read() {
  local plist_path="$1"
  local key="$2"

  python3 - "$plist_path" "$key" <<'PY'
import plistlib, sys

plist_path, key = sys.argv[1], sys.argv[2]
with open(plist_path, "rb") as f:
    pl = plistlib.load(f)

value = pl
for part in key.split(":"):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break

if value is None:
    sys.exit(2)

if isinstance(value, bytes):
    sys.stdout.buffer.write(value)
else:
    print(value)
PY
}

sha256_file() {
  local file_path="$1"
  shasum -a 256 "$file_path" | awk '{print $1}'
}

maybe_print_uuid() {
  local file_path="$1"

  if command -v dwarfdump >/dev/null 2>&1; then
    dwarfdump --uuid "$file_path" 2>/dev/null || true
  else
    echo "UUID check overgeslagen (dwarfdump niet beschikbaar)"
  fi
}

report_generated_info_identity() {
  local info_src

  info_src="$(find "$OBJ_DIR" -type f -name 'MarvellW8897Kext_info.c' -print | head -n 1 || true)"
  if [[ -z "$info_src" ]]; then
    echo "Geen gegenereerde MarvellW8897Kext_info.c gevonden onder $OBJ_DIR"
    return 0
  fi

  echo "Gegenereerde info source: $info_src"
  grep -nE 'KMOD_EXPLICIT_DECL|KMOD_DECL' "$info_src" || true
}

report_marvell_paths() {
  local tree_root="$1"
  local target_path="$2"

  echo "Marvell-paden onder $tree_root:"
  find "$tree_root" -iname '*Marvell*' -print | sed "s#^#$tree_root:#" || true
  echo "Actieve kopie-doelmap: $target_path"
}

verify_deploy_copy() {
  local src_kext="$1"
  local dst_kext="$2"

  local src_plist="$src_kext/Contents/Info.plist"
  local dst_plist="$dst_kext/Contents/Info.plist"
  local src_exec="$src_kext/Contents/MacOS/$KEXT_EXEC"
  local dst_exec="$dst_kext/Contents/MacOS/$KEXT_EXEC"

  [[ -f "$src_plist" ]] || die "Bron Info.plist ontbreekt: $src_plist"
  [[ -f "$dst_plist" ]] || die "Doel Info.plist ontbreekt: $dst_plist"
  [[ -x "$src_exec" ]] || die "Bron executable ontbreekt: $src_exec"
  [[ -x "$dst_exec" ]] || die "Doel executable ontbreekt: $dst_exec"

  local keys=(
    "CFBundleIdentifier"
    "CFBundleExecutable"
    "CFBundleVersion"
    "OSBundleCompatibleVersion"
  )

  echo "Vergelijk plist-waarden (bron vs doel):"
  local key src_value dst_value
  for key in "${keys[@]}"; do
    src_value="$(plist_read "$src_plist" "$key")" || die "Kon bron sleutel niet lezen: $key"
    dst_value="$(plist_read "$dst_plist" "$key")" || die "Kon doel sleutel niet lezen: $key"
    echo "  $key: bron=$src_value doel=$dst_value"
    [[ "$src_value" == "$dst_value" ]] || die "Plist mismatch voor $key"
  done

  local src_hash dst_hash
  src_hash="$(sha256_file "$src_exec")"
  dst_hash="$(sha256_file "$dst_exec")"
  echo "Executable SHA256:"
  echo "  bron=$src_hash"
  echo "  doel=$dst_hash"
  [[ "$src_hash" == "$dst_hash" ]] || die "Executable hash mismatch tussen build en EFI-kopie"

  echo "Executable UUIDs (indien beschikbaar):"
  echo "  bron:"
  maybe_print_uuid "$src_exec" | sed 's/^/    /'
  echo "  doel:"
  maybe_print_uuid "$dst_exec" | sed 's/^/    /'
}

resolve_efi_disk() {
  local requested="${1:-}"

  if [[ -n "$requested" ]]; then
    echo "$requested"
    return 0
  fi

  python3 <<'PY'
import subprocess, plistlib, sys

try:
    raw = subprocess.check_output(["diskutil", "list", "-plist"])
    pl = plistlib.loads(raw)
except Exception as e:
    print(f"Kon diskutil list -plist niet lezen: {e}", file=sys.stderr)
    sys.exit(1)

for disk in pl.get("AllDisksAndPartitions", []):
    for part in disk.get("Partitions", []):
        if part.get("Content") == "EFI" and part.get("DeviceIdentifier"):
            print(part["DeviceIdentifier"])
            sys.exit(0)

print("Geen EFI-partitie automatisch gevonden", file=sys.stderr)
sys.exit(1)
PY
}

resolve_mountpoint() {
  local disk="$1"

  python3 - "$disk" <<'PY'
import subprocess, plistlib, sys

disk = sys.argv[1]
try:
    raw = subprocess.check_output(["diskutil", "info", "-plist", disk])
    pl = plistlib.loads(raw)
except Exception as e:
    print(f"Kon diskutil info -plist {disk} niet lezen: {e}", file=sys.stderr)
    sys.exit(1)

mp = pl.get("MountPoint")
if not mp:
    sys.exit(2)

print(mp)
PY
}

run_build() {
  mkdir -p "$BUILD_DIR"

  if [[ "$QUIET_BUILD" == "1" ]]; then
    xcodebuild \
      -project "$REPO/MarvellW8897.xcodeproj" \
      -target MarvellW8897Kext \
      -configuration Debug \
      SYMROOT="$BUILD_DIR" \
      OBJROOT="$OBJ_DIR" \
      build >"$BUILD_LOG" 2>&1 || {
        echo
        echo "xcodebuild mislukt. Laatste regels uit $BUILD_LOG:" >&2
        tail -n 120 "$BUILD_LOG" >&2 || true
        die "Build mislukt"
      }
    echo "Build log: $BUILD_LOG"
  else
    xcodebuild \
      -project "$REPO/MarvellW8897.xcodeproj" \
      -target MarvellW8897Kext \
      -configuration Debug \
      SYMROOT="$BUILD_DIR" \
      OBJROOT="$OBJ_DIR" \
      build
  fi
}

build_probe() {
  [[ -f "$PROBE_SRC" ]] || die "Probe bron niet gevonden: $PROBE_SRC"

  if [[ "$QUIET_BUILD" == "1" ]]; then
    clang++ -std=c++17 -Wall -Wextra \
      -o "$PROBE_BIN" \
      "$PROBE_SRC" \
      -framework IOKit -framework CoreFoundation >"$PROBE_LOG" 2>&1 || {
        echo
        echo "Probe build mislukt. Laatste regels uit $PROBE_LOG:" >&2
        tail -n 120 "$PROBE_LOG" >&2 || true
        die "Probe build mislukt"
      }
    echo "Probe log: $PROBE_LOG"
  else
    clang++ -std=c++17 -Wall -Wextra \
      -o "$PROBE_BIN" \
      "$PROBE_SRC" \
      -framework IOKit -framework CoreFoundation
  fi
}

mount_efi() {
  local disk="$1"
  local mount_point="/Volumes/EFI"
  local resolved=""
  local raw_dev="/dev/r${disk}"

  [[ -e "$raw_dev" ]] || raw_dev="/dev/${disk}"

  if resolved="$(resolve_mountpoint "$disk" 2>/dev/null)"; then
    echo "$resolved"
    return 0
  fi

  if diskutil mount "$disk" >/dev/null 2>&1; then
    if resolved="$(resolve_mountpoint "$disk" 2>/dev/null)"; then
      echo "$resolved"
      return 0
    fi
  fi

  echo "diskutil mount faalde voor $disk, probeer fallback..." >&2

  sudo diskutil unmount force "$disk" >/dev/null 2>&1 || true

  if [[ "$AUTO_REPAIR_EFI" == "1" ]]; then
    set +e
    sudo fsck_msdos -fy "$raw_dev" >"$FSCK_LOG" 2>&1
    local fsck_rc=$?
    set -e

    echo "fsck_msdos exit: $fsck_rc" >&2
    echo "fsck log       : $FSCK_LOG" >&2
  fi

  sudo mkdir -p "$mount_point"
  sudo umount "$mount_point" >/dev/null 2>&1 || true

  sudo mount_msdos -u "$(id -u)" -g "$(id -g)" "/dev/${disk}" "$mount_point" \
    || die "EFI mount mislukt via diskutil én mount_msdos"

  [[ -d "$mount_point" ]] || die "Fallback mount leek te slagen maar mountpoint ontbreekt"

  echo "$mount_point"
}

update_config() {
  local cfg="$1"
  local kext_name="$2"
  local kext_exec="$3"
  local enable_test_sip="$4"

  python3 - "$cfg" "$kext_name" "$kext_exec" "$enable_test_sip" <<'PY'
import sys, plistlib, pathlib, shutil, datetime

cfg = pathlib.Path(sys.argv[1])
kext_name = sys.argv[2]
kext_exec = sys.argv[3]
enable_test_sip = sys.argv[4] == "1"

backup = cfg.with_name(f"config.plist.bak-{datetime.datetime.now().strftime('%Y%m%d-%H%M%S')}")
shutil.copy2(cfg, backup)

with cfg.open("rb") as f:
    pl = plistlib.load(f)

kernel = pl.setdefault("Kernel", {})
adds = kernel.setdefault("Add", [])

entry = {
    "Arch": "x86_64",
    "BundlePath": kext_name,
    "Comment": "Marvell W8897 bring-up",
    "Enabled": True,
    "ExecutablePath": f"Contents/MacOS/{kext_exec}",
    "MaxKernel": "",
    "MinKernel": "",
    "PlistPath": "Contents/Info.plist",
}

replaced = False
for i, e in enumerate(adds):
    if e.get("BundlePath") == kext_name:
        merged = dict(e)
        merged.update(entry)
        adds[i] = merged
        replaced = True
        break

if not replaced:
    adds.append(entry)

if enable_test_sip:
    nvram = pl.setdefault("NVRAM", {})
    add = nvram.setdefault("Add", {})
    delete = nvram.setdefault("Delete", {})
    guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"

    add_guid = add.setdefault(guid, {})
    add_guid["csr-active-config"] = bytes.fromhex("03000000")

    del_guid = delete.setdefault(guid, [])
    if "csr-active-config" not in del_guid:
        del_guid.append("csr-active-config")

with cfg.open("wb") as f:
    plistlib.dump(pl, f, sort_keys=False)

print(f"Backup : {backup}")
print(f"Updated: {cfg}")
PY
}

step "1/11" "Repo controleren"
[[ -d "$REPO/.git" ]] || die "Repo niet gevonden of geen git repo: $REPO"
cd "$REPO"
echo "Repo: $REPO"
[[ -x "$TRACE_SCRIPT" ]] || die "Diagnose script niet gevonden of niet uitvoerbaar: $TRACE_SCRIPT"
[[ -x "$INSPECT_SCRIPT" ]] || die "Inspector script niet gevonden of niet uitvoerbaar: $INSPECT_SCRIPT"

if [[ -n "$SYNC_REF" ]]; then
  step "2/11" "Repo syncen naar $SYNC_REF"
  git fetch origin --prune
  git reset --hard "$SYNC_REF"
else
  step "2/11" "Repo sync overslaan"
  echo "Huidige HEAD: $(git rev-parse --short HEAD)"
fi

step "3/11" "EFI partitie bepalen"
EFI_DISK="$(resolve_efi_disk "$EFI_DISK")"
[[ -n "$EFI_DISK" ]] || die "Geen EFI partitie bepaald"
echo "EFI disk: $EFI_DISK"

step "4/11" "Schone buildmap voorbereiden"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

step "5/11" "Kext builden"
run_build
[[ -d "$KEXT_SRC" ]] || die "Gebouwde kext niet gevonden: $KEXT_SRC"
echo "Gebouwde kext: $KEXT_SRC"
report_generated_info_identity

step "6/11" "Probe tool builden"
build_probe
[[ -x "$PROBE_BIN" ]] || die "Probe binary niet gevonden: $PROBE_BIN"
echo "Probe binary : $PROBE_BIN"

step "7/11" "EFI mounten"
EFI_MOUNT="$(mount_efi "$EFI_DISK")"
[[ -d "$EFI_MOUNT" ]] || die "Mountpoint niet gevonden: $EFI_MOUNT"

OC_DIR="$EFI_MOUNT/EFI/OC"
CFG="$OC_DIR/config.plist"
KEXT_DST="$OC_DIR/Kexts/$KEXT_NAME"

[[ -d "$OC_DIR" ]] || die "OpenCore map niet gevonden: $OC_DIR"
[[ -f "$CFG" ]] || die "config.plist niet gevonden: $CFG"

echo "EFI mountpoint: $EFI_MOUNT"
echo "OpenCore dir  : $OC_DIR"
report_marvell_paths "$EFI_MOUNT" "$KEXT_DST"

step "8/11" "Kext kopiëren"
mkdir -p "$OC_DIR/Kexts"
rm -rf "$KEXT_DST"
cp -R "$KEXT_SRC" "$KEXT_DST"
sync
verify_deploy_copy "$KEXT_SRC" "$KEXT_DST"
report_marvell_paths "$EFI_MOUNT" "$KEXT_DST"

step "9/11" "config.plist bijwerken"
update_config "$CFG" "$KEXT_NAME" "$KEXT_EXEC" "$ENABLE_TEST_SIP"
plutil -lint "$CFG" >/dev/null || die "config.plist validatie mislukt"

if [[ ! -f "$KEXT_DST/Contents/Info.plist" ]]; then
  die "Verwachte EFI kext plist ontbreekt na deploy: $KEXT_DST/Contents/Info.plist"
fi

MARVELL_OC_COUNT="$(count_marvell_kernel_add_entries "$CFG" || true)"
if [[ "${MARVELL_OC_COUNT:-}" == "INCONCLUSIVE_PARSE" || -z "${MARVELL_OC_COUNT:-}" ]]; then
  die "OpenCore Marvell entry kon niet conclusief worden geparsed uit $CFG"
fi
if [[ "$MARVELL_OC_COUNT" -le 0 ]]; then
  echo "WAARSCHUWING: EFI is gemount maar Kernel/Add bevat geen Marvell-entry in $CFG" >&2
  die "OpenCore config mist Marvell entry na deploy"
fi

echo
echo "Kernel/Add fragment:"
plutil -p "$CFG" | egrep 'BundlePath|ExecutablePath|PlistPath|csr-active-config' || true
echo "Marvell Kernel/Add entries: $MARVELL_OC_COUNT"

step "10/11" "Diagnostisch rapport"
if ! mount | grep -E " on $EFI_MOUNT " >/dev/null 2>&1; then
  echo "WAARSCHUWING: EFI mount is niet actief op $EFI_MOUNT; boot-source verificatie is onvolledig/inconclusive." >&2
  die "Post-deploy verificatie inconclusive: EFI mount ontbreekt"
fi

"$INSPECT_SCRIPT" --repo-root "$REPO" --strict-users

if [[ "$FAIL_ON_D" == "1" ]]; then
  "$INSPECT_SCRIPT" --repo-root "$REPO" --strict-km-fail
else
  echo "D-strict mode: uit (zet FAIL_ON_D=1 om te falen op D: kernelmanager ownership/validation failures)."
fi

if [[ "$RUN_DEEP_TRACE" != "1" ]]; then
  echo "WAARSCHUWING: RUN_DEEP_TRACE=$RUN_DEEP_TRACE, maar pre-retest default is deep trace ON."
  echo "Deep trace wordt alsnog uitgevoerd voor normale pre-retest flow."
fi
"$TRACE_SCRIPT" \
  --efi-mount "$EFI_MOUNT" \
  --config "$CFG" \
  --built-kext "$KEXT_SRC" \
  --copied-kext "$KEXT_DST" \
  --obj-dir "$OBJ_DIR"

step "11/11" "Afronden"
if [[ "$DO_BLESS" == "1" ]]; then
  sudo bless --mount "$EFI_MOUNT" --setBoot
  echo "Bless uitgevoerd."
else
  echo "Bless overgeslagen."
fi

if [[ "$UNMOUNT_AFTER" == "1" ]]; then
  diskutil unmount "$EFI_MOUNT" >/dev/null 2>&1 || true
  echo "EFI weer ge-unmount."
fi

echo
echo "Klaar."
echo "HEAD         : $(git rev-parse --short HEAD)"
echo "EFI disk     : $EFI_DISK"
echo "EFI mount    : $EFI_MOUNT"
echo "Kext bron    : $KEXT_SRC"
echo "Kext doel    : $KEXT_DST"
echo "Probe binary : $PROBE_BIN"
echo "Inspector    : $INSPECT_SCRIPT"
echo
echo "Volgende stap:"
echo "  1) scripts/trace_marvell_boot_runtime.sh"
echo "  2) scripts/inspect_marvell_history.sh --repo-root \"$REPO\" --strict-users"
echo "  3) (optioneel) FAIL_ON_D=1 scripts/inspect_marvell_history.sh --repo-root \"$REPO\" --strict-km-fail"
echo "  4) (optioneel) scripts/stage_marvell_root_owned.sh"
echo "  5) (optioneel) scripts/cleanup_marvell_auxkc.sh"
echo "  6) (optioneel) scripts/cleanup_marvell_auxkc.sh --apply"
