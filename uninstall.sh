#!/usr/bin/env bash
# Remove the rebuilt camera modules and restore the stock NVIDIA tegra-camera
# module and the boot configuration that existed before install.sh ran.
set -Eeuo pipefail

STATE_DIR=/var/lib/jetson-ecam-gmsl
DEPMOD_CONF=/etc/depmod.d/ecam-gmsl.conf

if ((EUID != 0)); then
  exec sudo -E -- "$0" "$@"
fi
[[ -f $STATE_DIR/installed ]] || { echo 'jetson-ecam-gmsl is not installed'; exit 0; }
# shellcheck disable=SC1091
source "$STATE_DIR/installed"

rm -f "$DEPMOD_CONF"
rm -rf "/lib/modules/$KVER/extra/ecam-gmsl"
depmod -a "$KVER"
printf 'tegra_camera now resolves to %s\n' "$(modinfo -n -k "$KVER" tegra_camera)"

if [[ -f $STATE_DIR/extlinux.conf.orig ]]; then
  cp -a /boot/extlinux/extlinux.conf "$STATE_DIR/extlinux.conf.uninstalled"
  cp -a "$STATE_DIR/extlinux.conf.orig" /boot/extlinux/extlinux.conf
  printf 'Restored /boot/extlinux/extlinux.conf from before installation.\n'
fi
rm -f "/boot/$OVERLAY.dtbo" "/lib/firmware/$FIRMWARE"
rm -f "$STATE_DIR/installed" "$STATE_DIR/extlinux.conf.orig"
printf 'Uninstalled. Reboot to return to the stock camera stack.\n'
