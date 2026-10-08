#!/usr/bin/env bash
# Build the e-con YUV GMSL camera modules against an installed L4T kernel.
#
# Only two modules are rebuilt: NVIDIA's tegra-camera.ko (with the e-con VI
# patch for this L4T release) and e-con's ecam_yuv_gmsl.ko. Everything else
# links against the symbol table NVIDIA ships in nvidia-l4t-kernel-oot-headers,
# so no kernel Image, DTB, or full nvidia-oot build is involved.
#
# Usage: build-modules.sh --release r39.2.1 --oot-src DIR --out DIR
#        [--kernel-headers DIR] [--oot-symvers FILE]
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE=""
OOT_SRC=""
OUT=""
KERNEL_HEADERS=${KERNEL_HEADERS:-/lib/modules/$(uname -r)/build}
OOT_SYMVERS=${OOT_SYMVERS:-/usr/src/nvidia/nvidia-public/Module.symvers}
JOBS=${JOBS:-$(nproc)}

die() { printf 'build-modules: %s\n' "$*" >&2; exit 1; }

while (($#)); do
  case $1 in
    --release) RELEASE=$2; shift ;;
    --oot-src) OOT_SRC=$2; shift ;;
    --out) OUT=$2; shift ;;
    --kernel-headers) KERNEL_HEADERS=$2; shift ;;
    --oot-symvers) OOT_SYMVERS=$2; shift ;;
    *) die "unknown argument '$1'" ;;
  esac
  shift
done

[[ -n $RELEASE && -n $OOT_SRC && -n $OUT ]] || die 'need --release, --oot-src and --out'
PATCH=$REPO_ROOT/releases/$RELEASE/nvidia-oot-ecam.patch
[[ -f $PATCH ]] || die "no camera patch for L4T $RELEASE (see releases/)"
[[ -f $KERNEL_HEADERS/Makefile ]] || die "kernel headers not found at $KERNEL_HEADERS"
[[ -f $OOT_SYMVERS ]] || die "NVIDIA OOT Module.symvers not found at $OOT_SYMVERS"
[[ -d $OOT_SRC/nvidia-oot ]] || die "nvidia-oot sources not found under $OOT_SRC"

OOT_SRC=$(cd -- "$OOT_SRC" && pwd)
mkdir -p "$OUT"
OUT=$(cd -- "$OUT" && pwd)
WORK=$OUT/work
rm -rf "$WORK"
mkdir -p "$WORK"

# Patch a private copy of only the trees we build. --dry-run first so a
# release mismatch fails cleanly instead of leaving a half-patched tree.
cp -a "$OOT_SRC/nvidia-oot" "$WORK/nvidia-oot"
patch -d "$WORK" -p1 --dry-run --fuzz=0 -s <"$PATCH" \
  || die "camera patch does not apply cleanly to these $RELEASE sources"
patch -d "$WORK" -p1 --fuzz=0 -s <"$PATCH"

CAMERA=$WORK/nvidia-oot/drivers/media/platform/tegra/camera
CONFTEST=$WORK/conftest

printf 'Generating NVIDIA conftest headers...\n'
mkdir -p "$CONFTEST/nvidia"
cp -a "$WORK/nvidia-oot/scripts/conftest/." "$CONFTEST/nvidia/"
make -s -j"$JOBS" ARCH=arm64 \
  src="$CONFTEST/nvidia" obj="$CONFTEST/nvidia" \
  NV_KERNEL_SOURCES="$KERNEL_HEADERS" NV_KERNEL_OUTPUT="$KERNEL_HEADERS" \
  -f "$CONFTEST/nvidia/Makefile"

# Building one subdirectory directly skips the parent Makefiles, so supply
# every flag they apply on the way down to drivers/media/platform/tegra:
#   nvidia-oot/Makefile (+ configs/Makefile.config.noble): includes, C90 decls
#   drivers/Makefile: host1x/host/hwpm include paths
#   drivers/media/Makefile: -DCONFIG_* for media features the kernel builds
#     as modules (=m does not define the plain CONFIG_ symbol)
oot_flags="-I$WORK/nvidia-oot/include -I$CONFTEST -DCONFIG_VIDEO_ECAM"
oot_flags+=" -Werror=declaration-after-statement"
oot_flags+=" -I$WORK/nvidia-oot/drivers/gpu/host1x/hw/ -I$WORK/nvidia-oot/drivers/video/tegra/host/"
for option in V4L2_ASYNC V4L2_FWNODE VIDEOBUF2_DMA_CONTIG; do
  if grep -Eq "^CONFIG_${option}=(y|m)$" "$KERNEL_HEADERS/.config"; then
    oot_flags+=" -DCONFIG_${option}"
  fi
done
printf 'NVIDIA media flags: %s\n' "$oot_flags"

printf 'Building patched tegra-camera.ko...\n'
make -j"$JOBS" ARCH=arm64 -C "$KERNEL_HEADERS" M="$CAMERA" \
  CONFIG_TEGRA_OOT_MODULE=m NV_BUILD_SYSTEM_TYPE=l4t \
  srctree.nvidia-oot="$WORK/nvidia-oot" srctree.nvconftest="$CONFTEST" \
  KCFLAGS="$oot_flags" \
  KBUILD_EXTRA_SYMBOLS="$OOT_SYMVERS" \
  modules

printf 'Building ecam_yuv_gmsl.ko...\n'
cp -a "$REPO_ROOT/driver/ecam_yuv_gmsl" "$WORK/ecam_yuv_gmsl"
make -j"$JOBS" ARCH=arm64 -C "$KERNEL_HEADERS" M="$WORK/ecam_yuv_gmsl" \
  NVIDIA_OOT="$WORK/nvidia-oot" \
  KCFLAGS="$oot_flags" \
  KBUILD_EXTRA_SYMBOLS="$OOT_SYMVERS $CAMERA/Module.symvers" \
  modules

install -m 0644 "$CAMERA/tegra-camera.ko" "$OUT/tegra-camera.ko"
install -m 0644 "$WORK/ecam_yuv_gmsl/ecam_yuv_gmsl.ko" "$OUT/ecam_yuv_gmsl.ko"
printf 'Built %s/tegra-camera.ko and %s/ecam_yuv_gmsl.ko\n' "$OUT" "$OUT"
