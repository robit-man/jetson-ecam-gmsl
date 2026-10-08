#!/usr/bin/env bash
# Compile one e-con camera overlay with NVIDIA's device-tree binding headers.
#
# Usage: build-overlay.sh --hardware <oot>/hardware/nvidia --overlay NAME --out DIR
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HARDWARE=""
OVERLAY=""
OUT=""

while (($#)); do
  case $1 in
    --hardware) HARDWARE=$2; shift ;;
    --overlay) OVERLAY=$2; shift ;;
    --out) OUT=$2; shift ;;
    *) printf 'build-overlay: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done
[[ -d $HARDWARE && -n $OVERLAY && -n $OUT ]] || {
  printf 'build-overlay: need --hardware, --overlay and --out\n' >&2
  exit 2
}

mkdir -p "$OUT"
cpp -nostdinc -undef -x assembler-with-cpp -D__DTS__ \
  -I "$REPO_ROOT/dts" \
  -I "$HARDWARE/t23x/nv-public/include/platforms" \
  -I "$HARDWARE/t23x/nv-public/include/kernel" \
  -I "$HARDWARE/tegra/nv-public/include/kernel" \
  "$REPO_ROOT/dts/$OVERLAY.dts" -o "$OUT/$OVERLAY.pre.dts"
dtc -q -@ -I dts -O dtb -o "$OUT/$OVERLAY.dtbo" "$OUT/$OVERLAY.pre.dts"
printf 'Built %s/%s.dtbo\n' "$OUT" "$OVERLAY"
