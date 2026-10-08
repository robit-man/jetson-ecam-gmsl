#!/usr/bin/env bash
# Install e-con Systems YUV GMSL2 cameras (NileCAM/STURDeCAM 20/21/25/81) on
# Jetson AGX Orin without reflashing or rebuilding the kernel.
#
# The installer detects the running L4T release, rebuilds only NVIDIA's
# tegra-camera.ko (with the e-con VI patch for that release) and e-con's
# ecam_yuv_gmsl.ko against the installed kernel headers, proves every symbol
# version matches the running kernel before installing anything, compiles the
# camera overlay and proves it applies to this board's device tree, then
# enables it through jetson-io while keeping any other configured overlays.
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR=/var/lib/jetson-ecam-gmsl
CACHE_DIR=/var/cache/jetson-ecam-gmsl
MODULE_SUBDIR=extra/ecam-gmsl
DEPMOD_CONF=/etc/depmod.d/ecam-gmsl.conf
CAMERA=""
VENDOR_PACKAGE=""
ASSUME_YES=0
REBOOT=0
BUILD_ONLY=0
IF_NEEDED=0
AFTER_KERNEL_CHANGE=0
INSTALL_ROOT=/usr/local/lib/jetson-ecam-gmsl
BOOT_UNIT=/etc/systemd/system/jetson-ecam-gmsl.service
ORIGINAL_ARGS=("$@")

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]

  --camera 20|21|25|81   e-con product (NileCAM/STURDeCAM number); defaults to
                         the previously installed camera, then $ECAM_CAMERA, then 81
  --vendor-package PATH  use MCU firmware from an e-con release tarball or
                         directory instead of the bundled firmware/
  --build-only           build and verify, but install nothing
  --if-needed            do nothing when this kernel, camera and source are
                         already installed (used by deploy tools and at boot)
  --yes                  do not ask before configuring the boot overlay
  --reboot               reboot when installation finishes
  -h, --help             show this help

Supported boards: Jetson AGX Orin developer kit (p3737 + p3701-0000/0004/0005).
Supported L4T releases are the directories under releases/.
EOF
}

log() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --camera) CAMERA=${2:-}; shift ;;
    --vendor-package) VENDOR_PACKAGE=${2:-}; shift ;;
    --build-only) BUILD_ONLY=1 ;;
    --if-needed) IF_NEEDED=1 ;;
    --after-kernel-change) IF_NEEDED=1; AFTER_KERNEL_CHANGE=1; ASSUME_YES=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --reboot) REBOOT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument '$1' (see --help)" ;;
  esac
  shift
done

if [[ -z $CAMERA && -r $STATE_DIR/installed ]]; then
  CAMERA=$(sed -n 's/^CAMERA=//p' "$STATE_DIR/installed")
fi
CAMERA=${CAMERA:-${ECAM_CAMERA:-81}}

case $CAMERA in
  20) SENSOR=ar0230 ;;
  21) SENSOR=ar0233 ;;
  25) SENSOR=ar0234 ;;
  81) SENSOR=ar0821 ;;
  *) die "unsupported --camera '$CAMERA' (expected 20, 21, 25 or 81)" ;;
esac
OVERLAY=tegra234-p3737-camera-overlay_${SENSOR}_two_lane
FIRMWARE=${SENSOR}_mcu_fw.bin

if ((EUID != 0)); then
  exec sudo -E -- "$0" "${ORIGINAL_ARGS[@]}"
fi
SUDO_HOME=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)

# --- platform detection ----------------------------------------------------

[[ $(uname -m) == aarch64 ]] || die 'this installer runs on the Jetson itself (aarch64)'
[[ -r /etc/nv_tegra_release ]] || die 'not an NVIDIA Jetson (no /etc/nv_tegra_release)'

l4t=$(sed -n 's/^# R\([0-9]*\) (release), REVISION: \([0-9.]*\).*/\1.\2/p' /etc/nv_tegra_release | head -n1)
[[ -n $l4t ]] || die 'could not read the L4T release from /etc/nv_tegra_release'
# Prefer the exact package version (REVISION may omit the patch level).
core=$(dpkg-query -W -f='${Version}' nvidia-l4t-core 2>/dev/null | cut -d- -f1)
[[ $core =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && l4t=$core
RELEASE=r$l4t
KVER=$(uname -r)
log "Detected L4T $l4t, kernel $KVER"

# Identity of what would be installed: the driver, patches, overlays and
# scripts in this checkout. A kernel, camera or source change forces a rebuild.
SOURCE_ID=$(cd "$REPO_ROOT" && find driver dts firmware releases scripts install.sh -type f \
  ! -name '*.pyc' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16)
previous_kver=""
if [[ -r $STATE_DIR/installed ]]; then
  previous_kver=$(sed -n 's/^KVER=//p' "$STATE_DIR/installed")
fi
if ((IF_NEEDED)) && [[ -r $STATE_DIR/installed ]] \
  && grep -qx "KVER=$KVER" "$STATE_DIR/installed" \
  && grep -qx "CAMERA=$CAMERA" "$STATE_DIR/installed" \
  && grep -qx "SOURCE_ID=$SOURCE_ID" "$STATE_DIR/installed" \
  && [[ $(modinfo -n -k "$KVER" tegra_camera 2>/dev/null) == */$MODULE_SUBDIR/tegra-camera.ko ]] \
  && grep -q "$OVERLAY.dtbo" /boot/extlinux/extlinux.conf; then
  log "Camera $CAMERA is already installed for $KVER; nothing to do"
  exit 0
fi

# Use the patch validated for this exact release; otherwise try the newest
# validated patch from the same major L4T line. The no-fuzz patch apply, the
# symbol-CRC gate, and the overlay-apply gate below decide whether it fits,
# and nothing is installed unless all three pass.
PATCH_RELEASE=$RELEASE
if [[ ! -d $REPO_ROOT/releases/$RELEASE ]]; then
  PATCH_RELEASE=$(ls "$REPO_ROOT/releases" | grep "^r${l4t%%.*}\." | sort -V | tail -n1 || true)
  [[ -n $PATCH_RELEASE ]] \
    || die "no camera patch for L4T ${l4t%%.*}.x; validated: $(ls "$REPO_ROOT/releases" | tr '\n' ' ')"
  log "L4T $l4t has no validated patch; trying the $PATCH_RELEASE patch behind the verification gates"
fi

model_compat=$(tr '\0' '\n' </proc/device-tree/compatible)
board_ok=0
for compatible in nvidia,p3737-0000+p3701-0000 nvidia,p3737-0000+p3701-0004 nvidia,p3737-0000+p3701-0005; do
  grep -qx "$compatible" <<<"$model_compat" && board_ok=1
done
((board_ok)) || die "board is not a supported AGX Orin devkit: $(head -n1 <<<"$model_compat")"

# --- vendor firmware -------------------------------------------------------

find_firmware() {
  local candidate
  local search=()
  [[ -n $VENDOR_PACKAGE ]] && search+=("$VENDOR_PACKAGE")
  search+=("$REPO_ROOT/firmware/$FIRMWARE")
  search+=("$REPO_ROOT" "$PWD" "$SUDO_HOME/Desktop" "$SUDO_HOME/Downloads" "$SUDO_HOME")
  [[ -f /lib/firmware/$FIRMWARE ]] && search+=("/lib/firmware/$FIRMWARE")
  for candidate in "${search[@]}"; do
    [[ -e $candidate ]] || continue
    if [[ -f $candidate && $candidate == *.bin ]]; then
      printf '%s\n' "$candidate"; return 0
    fi
    if [[ -d $candidate ]]; then
      local found
      found=$(find "$candidate" -maxdepth 4 -name "$FIRMWARE" -print -quit 2>/dev/null)
      [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
      found=$(find "$candidate" -maxdepth 3 -name 'e-CAM_YUV-GMSL*.tar*' -print -quit 2>/dev/null)
      [[ -n $found ]] && candidate=$found
    fi
    if [[ -f $candidate && $candidate == *.tar* ]]; then
      local extract=$CACHE_DIR/vendor
      rm -rf "$extract"; mkdir -p "$extract"
      tar -xf "$candidate" -C "$extract"
      # The release tarball nests a second tarball holding the binaries.
      find "$extract" -name '*.tar.gz' -exec tar -xzf {} -C "$extract" \;
      local found
      found=$(find "$extract" -name "$FIRMWARE" -print -quit)
      [[ -n $found ]] && { printf '%s\n' "$found"; return 0; }
    fi
  done
  return 1
}

mkdir -p "$CACHE_DIR" "$STATE_DIR"
firmware_src=$(find_firmware) \
  || die "e-con MCU firmware $FIRMWARE not found; pass --vendor-package <e-con release .tar.xz or directory>"
log "Using e-con MCU firmware $firmware_src"

# --- build prerequisites -----------------------------------------------------

kernel_pkg_version=$(dpkg-query -W -f='${Version}' nvidia-l4t-kernel 2>/dev/null) \
  || die 'nvidia-l4t-kernel is not installed; cannot match kernel headers'
packages=(build-essential bc bison flex libssl-dev libelf-dev device-tree-compiler kmod patch curl python3)
missing=()
for package in "${packages[@]}"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
done
for package in nvidia-l4t-kernel-headers nvidia-l4t-kernel-oot-headers; do
  installed=$(dpkg-query -W -f='${Version}' "$package" 2>/dev/null || true)
  [[ $installed == "$kernel_pkg_version" ]] || missing+=("$package=$kernel_pkg_version")
done
if ((${#missing[@]})); then
  log "Installing build prerequisites: ${missing[*]}"
  apt-get -o DPkg::Lock::Timeout=600 update
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y "${missing[@]}"
fi

KERNEL_HEADERS=/lib/modules/$KVER/build
OOT_SYMVERS=/usr/src/nvidia/nvidia-public/Module.symvers
[[ -f $KERNEL_HEADERS/Module.symvers ]] || die "kernel headers for $KVER are missing at $KERNEL_HEADERS"
[[ -f $OOT_SYMVERS ]] || die "NVIDIA OOT symbol table missing at $OOT_SYMVERS"

# --- NVIDIA OOT sources for exactly this release ------------------------------

src_dir=$CACHE_DIR/$RELEASE/oot
if [[ ! -f $src_dir/.complete ]]; then
  major=${l4t%%.*}
  rest=${l4t#*.}
  url=https://developer.download.nvidia.com/embedded/L4T/r${major}_Release_v${rest}/sources/public_sources.tbz2
  archive=$CACHE_DIR/$RELEASE/public_sources.tbz2
  mkdir -p "$CACHE_DIR/$RELEASE"
  if [[ ! -f $archive ]]; then
    log "Downloading NVIDIA L4T $l4t public sources (~300 MB, cached)..."
    curl -fL --retry 3 -o "$archive.part" "$url"
    mv "$archive.part" "$archive"
  fi
  log 'Extracting NVIDIA out-of-tree module sources...'
  tar -xjf "$archive" -C "$CACHE_DIR/$RELEASE" \
    Linux_for_Tegra/source/kernel_oot_modules_src.tbz2 \
    Linux_for_Tegra/source/kernel_oot_modules_src.tbz2.sha1sum
  # NVIDIA's .sha1sum names a path on their build host, so compare the hash itself.
  sources=$CACHE_DIR/$RELEASE/Linux_for_Tegra/source
  [[ $(cut -d' ' -f1 "$sources/kernel_oot_modules_src.tbz2.sha1sum") \
     == $(sha1sum "$sources/kernel_oot_modules_src.tbz2" | cut -d' ' -f1) ]] \
    || die 'NVIDIA OOT source checksum mismatch'
  rm -rf "$src_dir"; mkdir -p "$src_dir"
  tar -xjf "$CACHE_DIR/$RELEASE/Linux_for_Tegra/source/kernel_oot_modules_src.tbz2" -C "$src_dir" \
    nvidia-oot hardware
  touch "$src_dir/.complete"
fi

# --- build and verify --------------------------------------------------------

build_dir=$CACHE_DIR/$RELEASE/build
log 'Building camera modules against the running kernel...'
"$REPO_ROOT/scripts/build-modules.sh" --release "$PATCH_RELEASE" --oot-src "$src_dir" --out "$build_dir" \
  --kernel-headers "$KERNEL_HEADERS" --oot-symvers "$OOT_SYMVERS" >"$build_dir.log" 2>&1 \
  || { tail -n 40 "$build_dir.log" >&2; die "module build failed (full log: $build_dir.log)"; }

log 'Verifying symbol versions against this kernel and the stock NVIDIA modules...'
python3 "$REPO_ROOT/scripts/check-modversions.py" \
  --kernel-symvers "$KERNEL_HEADERS/Module.symvers" \
  --oot-symvers "$OOT_SYMVERS" \
  --camera-symvers "$build_dir/work/nvidia-oot/drivers/media/platform/tegra/camera/Module.symvers" \
  --stock-modules "/lib/modules/$KVER/updates" \
  --stock-camera "/lib/modules/$KVER/updates/drivers/media/platform/tegra/camera/tegra-camera.ko" \
  "$build_dir/tegra-camera.ko" "$build_dir/ecam_yuv_gmsl.ko" \
  || die 'symbol verification failed; nothing was installed'
# Without the VI capture timeout control, capture_timeout_ms stays 0 and every
# capture request times out immediately.
grep -aq "Override capture timeout ms" "$build_dir/tegra-camera.ko" \
  || die 'patched tegra-camera.ko lost the VI capture timeout control; nothing was installed'

log "Compiling and test-applying the $SENSOR overlay..."
"$REPO_ROOT/scripts/build-overlay.sh" --hardware "$src_dir/hardware/nvidia" \
  --overlay "$OVERLAY" --out "$build_dir"
base_dtb=$(find /boot/dtb -maxdepth 1 -name 'kernel_tegra234-p3737-0000+p3701-*.dtb' -print -quit)
[[ -n $base_dtb ]] || die 'could not find the board DTB under /boot/dtb'
fdtoverlay -i "$base_dtb" -o "$build_dir/merged.dtb" "$build_dir/$OVERLAY.dtbo" \
  || die "overlay does not apply to $base_dtb; nothing was installed"

if ((BUILD_ONLY)); then
  log "Build-only: modules and overlay verified in $build_dir"
  exit 0
fi

# --- install -----------------------------------------------------------------

log 'Installing modules, firmware and overlay...'
install -D -m 0644 "$build_dir/tegra-camera.ko" "/lib/modules/$KVER/$MODULE_SUBDIR/tegra-camera.ko"
install -D -m 0644 "$build_dir/ecam_yuv_gmsl.ko" "/lib/modules/$KVER/$MODULE_SUBDIR/ecam_yuv_gmsl.ko"
# Take precedence over NVIDIA's packaged tegra-camera.ko without overwriting
# it, so apt upgrades stay clean and uninstall restores the stock module.
cat >"$DEPMOD_CONF" <<EOF
# Installed by jetson-ecam-gmsl for kernel $KVER (L4T $l4t)
# kmod matches overrides against the module file name, so tegra-camera keeps its dash.
override tegra-camera $KVER $MODULE_SUBDIR
override ecam_yuv_gmsl $KVER $MODULE_SUBDIR
EOF
depmod -a "$KVER"
resolved=$(modinfo -n -k "$KVER" tegra_camera)
[[ $resolved == */$MODULE_SUBDIR/tegra-camera.ko ]] \
  || die "depmod still resolves tegra_camera to $resolved"

if [[ $(realpath "$firmware_src") != "/lib/firmware/$FIRMWARE" ]]; then
  install -D -m 0644 "$firmware_src" "/lib/firmware/$FIRMWARE"
fi
install -m 0644 "$build_dir/$OVERLAY.dtbo" "/boot/$OVERLAY.dtbo"

# --- boot overlay --------------------------------------------------------------

overlay_name=$(fdtget -t s "/boot/$OVERLAY.dtbo" / overlay-name)
extlinux=/boot/extlinux/extlinux.conf
[[ -f $STATE_DIR/extlinux.conf.orig ]] || cp -a "$extlinux" "$STATE_DIR/extlinux.conf.orig"

# Keep every overlay the current default entry already applies (for example a
# 40-pin audio HAT) by passing them back to jetson-io alongside the camera.
default_label=$(awk '/^DEFAULT/ {print $2; exit}' "$extlinux")
current_overlays=$(awk -v label="$default_label" '
  /^LABEL/ {active = ($2 == label)}
  active && $1 == "OVERLAYS" {for (i = 2; i <= NF; i++) print $i}' "$extlinux" | tr ',' '\n' | sed '/^$/d')

jetson_io=/opt/nvidia/jetson-io/config-by-hardware.py
header_list=$(python3 "$jetson_io" -l 2>/dev/null || true)
header_index() {
  awk -v want="$1" '/^Header [0-9]+/ {
      line = $0; sub(/^Header /, "", line); split(line, parts, ":")
      idx = parts[1]; sub(/ .*/, "", idx); name = substr(line, index(line, ":") + 2)
      if (name == want) print idx }' <<<"$header_list"
}

selections=()
csi_header=$(fdtget -t s "/boot/$OVERLAY.dtbo" / jetson-header-name)
camera_index=$(header_index "$csi_header")
for dtbo in $current_overlays; do
  [[ -f $dtbo && $dtbo != */tegra234-p3737-camera-* ]] || continue
  name=$(fdtget -t s "$dtbo" / overlay-name 2>/dev/null) || continue
  header=$(fdtget -t s "$dtbo" / jetson-header-name 2>/dev/null) || continue
  index=$(header_index "$header")
  [[ -n $index && $index != "$camera_index" ]] && selections+=("$index=$name")
done

if ((ASSUME_YES == 0)) && [[ -t 0 ]]; then
  printf 'Configure the next boot to load "%s"%s? [Y/n] ' "$overlay_name" \
    "$( ((${#selections[@]})) && printf ' (keeping: %s)' "${selections[*]}")"
  read -r answer
  [[ -z $answer || $answer =~ ^[Yy] ]] || die 'boot overlay not configured; modules are installed'
fi

configured=0
if [[ -x $jetson_io || -f $jetson_io ]] && [[ -n $camera_index ]] \
  && grep -qF "$overlay_name" <<<"$header_list"; then
  log "Configuring jetson-io: header $camera_index = $overlay_name"
  python3 "$jetson_io" -n "$camera_index=$overlay_name" "${selections[@]}" && configured=1
fi
if ((configured == 0)); then
  log 'jetson-io unavailable; adding an extlinux entry directly'
  fdt=$(awk -v label="$default_label" '/^LABEL/ {a = ($2 == label)} a && $1 == "FDT" {print $2; exit}' "$extlinux")
  python3 - "$extlinux" "$default_label" "/boot/$OVERLAY.dtbo" "$fdt" "$base_dtb" $current_overlays <<'PY'
import re, sys
path, default, camera, fdt, base, *keep = sys.argv[1:]
text = open(path).read()
blocks = re.split(r'(?m)^(?=LABEL )', text)
source = next(b for b in blocks if b.split()[1] == default)
body = [l for l in source.splitlines()[1:] if not re.match(r'\s*(MENU LABEL|OVERLAYS|FDT)\b', l)]
overlays = [o for o in keep if '/tegra234-p3737-camera-' not in o] + [camera]
entry = ['LABEL ecam-gmsl', '\tMENU LABEL e-con GMSL camera']
entry += body[:1] + [f'\tFDT {fdt or base}'] + body[1:] + [f'\tOVERLAYS {",".join(overlays)}']
blocks = [b for b in blocks if not b.startswith('LABEL ecam-gmsl')]
text = re.sub(r'(?m)^DEFAULT .*$', 'DEFAULT ecam-gmsl', ''.join(blocks))
open(path, 'w').write(text.rstrip('\n') + '\n\n' + '\n'.join(entry) + '\n')
PY
fi

grep -q "$OVERLAY.dtbo" "$extlinux" || die "boot configuration does not reference $OVERLAY.dtbo"

# Keep a stable copy of this installer and rebuild automatically at boot
# whenever the running kernel no longer matches the installed modules.
mkdir -p "$INSTALL_ROOT"
if [[ $(realpath "$REPO_ROOT") != "$INSTALL_ROOT" ]]; then
  tar -C "$REPO_ROOT" --exclude=.git --exclude=.verify -cf - . | tar -C "$INSTALL_ROOT" -xf -
fi
cat >"$BOOT_UNIT" <<UNIT
[Unit]
Description=Rebuild e-con GMSL camera modules after a kernel change
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_ROOT/install.sh --after-kernel-change
TimeoutStartSec=3600

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable jetson-ecam-gmsl.service >/dev/null 2>&1

cat >"$STATE_DIR/installed" <<EOF
SOURCE_ID=$SOURCE_ID
RELEASE=$RELEASE
PATCH_RELEASE=$PATCH_RELEASE
KVER=$KVER
CAMERA=$CAMERA
OVERLAY=$OVERLAY
FIRMWARE=$FIRMWARE
EOF

log "Installed for L4T $l4t / $KVER. Reboot to load the camera overlay."
# After a kernel update the camera cannot work until the rebuilt modules are
# loaded, so the boot-time rebuild finishes with exactly one reboot.
if ((AFTER_KERNEL_CHANGE)) && [[ -n $previous_kver && $previous_kver != "$KVER" ]]; then
  log "Kernel changed from $previous_kver; rebooting once to load the rebuilt modules"
  REBOOT=1
fi
log 'After reboot: ls /dev/video*; v4l2-ctl --list-devices; dmesg | grep -i ecam'
if ((REBOOT)); then
  systemctl reboot
fi
