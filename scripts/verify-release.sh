#!/usr/bin/env bash
# Reproduce the installer's build and verification gates for one L4T release
# without a Jetson: fetch NVIDIA's packaged kernel headers, OOT symbol table,
# stock OOT modules and board DTBs plus the matching public sources, then
#   1. build the patched tegra-camera.ko and ecam_yuv_gmsl.ko,
#   2. prove every imported symbol CRC matches the shipped kernel and modules,
#   3. compile every camera overlay and apply it to every supported board DTB.
#
# Must run on aarch64 Ubuntu matching the release (24.04 for L4T r39).
# Usage: scripts/verify-release.sh r39.2.1 [work-dir]
set -Eeuo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RELEASE=${1:?usage: verify-release.sh r39.2.1 [work-dir]}
WORK=${2:-$REPO_ROOT/.verify/$RELEASE}
REPO=https://repo.download.nvidia.com/jetson/som

l4t=${RELEASE#r}
major=${l4t%%.*}
rest=${l4t#*.}
minor=${rest%%.*}
[[ -d $REPO_ROOT/releases/$RELEASE ]] || { echo "no releases/$RELEASE" >&2; exit 1; }
mkdir -p "$WORK"
cd "$WORK"

echo "== Fetching NVIDIA L4T $l4t kernel packages"
curl -fsSL "$REPO/dists/r$major.$minor/main/binary-arm64/Packages.gz" | gunzip >Packages
for package in nvidia-l4t-kernel nvidia-l4t-kernel-headers nvidia-l4t-kernel-oot-headers \
  nvidia-l4t-kernel-oot-modules nvidia-l4t-kernel-dtbs; do
  file=$(awk -v p="$package" -v v="-tegra-$l4t-" '
    /^Package: / {name = $2} /^Filename: / && name == p && index($2, v) {print $2}' Packages | tail -n1)
  [[ -n $file ]] || { echo "no $package for L4T $l4t" >&2; exit 1; }
  [[ -f $package.deb ]] || curl -fsSL -o "$package.deb" "$REPO/$file"
  rm -rf "root-$package"; mkdir "root-$package"
  dpkg-deb -x "$package.deb" "root-$package"
done

kernel_headers=$(dirname "$(find root-nvidia-l4t-kernel-headers -name Module.symvers -path '*linux*' | head -n1)")
oot_symvers=root-nvidia-l4t-kernel-oot-headers/usr/src/nvidia/nvidia-public/Module.symvers
stock_modules=$(find root-nvidia-l4t-kernel-oot-modules -type d -name updates | head -n1)
dtbs=root-nvidia-l4t-kernel-dtbs/boot

# The headers' build symlinks are absolute; expose them where they point.
headers_pkg_dir=$(find root-nvidia-l4t-kernel-headers/usr/src -mindepth 1 -maxdepth 1 -type d | head -n1)
if [[ ! -e /usr/src/$(basename "$headers_pkg_dir") ]]; then
  sudo ln -s "$PWD/$headers_pkg_dir" "/usr/src/$(basename "$headers_pkg_dir")"
fi

echo "== Fetching NVIDIA L4T $l4t public sources"
if [[ ! -f oot/.complete ]]; then
  [[ -f public_sources.tbz2 ]] || curl -fsSL -o public_sources.tbz2 \
    "https://developer.download.nvidia.com/embedded/L4T/r${major}_Release_v${rest}/sources/public_sources.tbz2"
  tar -xjf public_sources.tbz2 Linux_for_Tegra/source/kernel_oot_modules_src.tbz2 \
    Linux_for_Tegra/source/kernel_oot_modules_src.tbz2.sha1sum
  # NVIDIA's .sha1sum names a path on their build host, so compare the hash itself.
  [[ $(cut -d' ' -f1 Linux_for_Tegra/source/kernel_oot_modules_src.tbz2.sha1sum) \
     == $(sha1sum Linux_for_Tegra/source/kernel_oot_modules_src.tbz2 | cut -d' ' -f1) ]] \
    || { echo 'NVIDIA OOT source checksum mismatch' >&2; exit 1; }
  rm -rf oot; mkdir oot
  tar -xjf Linux_for_Tegra/source/kernel_oot_modules_src.tbz2 -C oot nvidia-oot hardware
  touch oot/.complete
fi

echo "== Building modules"
"$REPO_ROOT/scripts/build-modules.sh" --release "$RELEASE" --oot-src oot --out build \
  --kernel-headers "$PWD/$kernel_headers" --oot-symvers "$PWD/$oot_symvers"

echo "== Verifying symbol versions"
python3 "$REPO_ROOT/scripts/check-modversions.py" \
  --kernel-symvers "$kernel_headers/Module.symvers" \
  --oot-symvers "$oot_symvers" \
  --camera-symvers build/work/nvidia-oot/drivers/media/platform/tegra/camera/Module.symvers \
  --stock-modules "$stock_modules" \
  --stock-camera "$stock_modules/drivers/media/platform/tegra/camera/tegra-camera.ko" \
  build/tegra-camera.ko build/ecam_yuv_gmsl.ko

echo "== Checking the patched VI keeps its capture timeout control"
# Without it capture_timeout_ms stays 0 and every capture times out at once.
grep -aq "Override capture timeout ms" build/tegra-camera.ko \
  || { echo "tegra-camera.ko lost the VI capture timeout control" >&2; exit 1; }
echo "  capture timeout control present"

echo "== Checking depmod prefers the rebuilt modules"
kver=$(basename "$(dirname "$stock_modules")")
fake=$PWD/depmod-root
rm -rf "$fake"
mkdir -p "$fake/lib/modules/$kver" "$fake/etc/depmod.d"
cp -a "$stock_modules" "$fake/lib/modules/$kver/"
install -D -m 0644 build/tegra-camera.ko "$fake/lib/modules/$kver/extra/ecam-gmsl/tegra-camera.ko"
install -D -m 0644 build/ecam_yuv_gmsl.ko "$fake/lib/modules/$kver/extra/ecam-gmsl/ecam_yuv_gmsl.ko"
echo 'search updates ubuntu built-in' >"$fake/etc/depmod.d/ubuntu.conf"
# Same override text install.sh writes.
sed -n '/^override /p' "$REPO_ROOT/install.sh" \
  | sed "s/\$KVER/$kver/; s#\$MODULE_SUBDIR#extra/ecam-gmsl#" >"$fake/etc/depmod.d/ecam-gmsl.conf"
depmod -b "$fake" -C "$fake/etc/depmod.d" "$kver" 2>/dev/null
for module in tegra_camera ecam_yuv_gmsl; do
  resolved=$(modinfo -b "$fake" -k "$kver" -n "$module")
  printf '  %-15s -> %s\n' "$module" "${resolved#"$fake"}"
  [[ $resolved == */extra/ecam-gmsl/* ]] || { echo "depmod does not prefer the rebuilt $module" >&2; exit 1; }
done

echo "== Compiling and applying overlays"
failures=0
for dts in "$REPO_ROOT"/dts/tegra234-p3737-camera-overlay_*.dts; do
  overlay=$(basename "$dts" .dts)
  "$REPO_ROOT/scripts/build-overlay.sh" --hardware oot/hardware/nvidia --overlay "$overlay" --out build >/dev/null
  for module in 0000 0004 0005; do
    base=$dtbs/tegra234-p3737-0000+p3701-$module-nv.dtb
    if fdtoverlay -i "$base" -o build/merged.dtb "build/$overlay.dtbo"; then
      printf '  %-45s applies to p3701-%s\n' "$overlay" "$module"
    else
      printf '  %-45s FAILS on p3701-%s\n' "$overlay" "$module"; failures=$((failures + 1))
    fi
  done
done
((failures == 0)) || exit 1
echo "== L4T $l4t verified"
