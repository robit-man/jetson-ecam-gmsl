# jetson-ecam-gmsl

e-con Systems YUV GMSL2 cameras (NileCAM/STURDeCAM **20, 21, 25, 81**) on
Jetson AGX Orin with **JetPack 7.2.1 (L4T 39.2.1)**, installed without
reflashing, without replacing the kernel `Image`, and without a full kernel or
`nvidia-oot` build.

```bash
git clone https://github.com/robit-man/jetson-ecam-gmsl.git && cd jetson-ecam-gmsl && sudo ./install.sh --camera 81
```

Copy e-con's release tarball
(`e-CAM_YUV-GMSL-PRODUCTS_JETSON_AGX_ORIN_*.tar.xz`) to `~/Desktop`,
`~/Downloads` or `~` first, or pass `--vendor-package PATH`. The MCU firmware
inside it is e-con's and is not redistributed here. Reboot when the installer
finishes, then check `v4l2-ctl --list-devices`.

## Why no kernel rebuild is needed on JetPack 7.2.1

e-con's JetPack 6.0 package replaces the kernel `Image`, the full board DTB,
and NVIDIA's camera modules. Ported to L4T 39.2.1, almost all of that is
already upstream:

| e-con JP6.0 change | L4T 39.2.1 status |
| --- | --- |
| Kernel `of_dma_is_coherent` `dma-noncoherent` support (the only `Image` change) | In Linux 6.8 already |
| Base DTB: `dma-noncoherent` on VI0/VI1 and their THI nodes | Already in NVIDIA's 39.2.1 DTBs |
| `capture-ivc` channel-ID semaphore | Merged by NVIDIA |
| VI `s_parm`/`g_parm` frame-rate ioctls | Merged by NVIDIA |
| VI stream-error hooks exported to the sensor driver | Patch, `releases/r39.2.1` |
| VI stride alignment, UYVY mapping, tegracam control power gate | Patch, `releases/r39.2.1` |
| Sensor driver `ecam_yuv_gmsl` | Ported to Linux 6.8 in `driver/` |
| Camera overlays | `dts/`, applied with jetson-io |

So the install rebuilds exactly two modules against the packaged kernel
headers: NVIDIA's `tegra-camera.ko` with a 65-line patch, and e-con's sensor
driver.

## What `install.sh` does

1. Detects the L4T release, kernel, and board (AGX Orin devkit
   p3737 + p3701-0000/0004/0005). Finds the e-con MCU firmware.
2. Installs `nvidia-l4t-kernel-headers` and `nvidia-l4t-kernel-oot-headers`
   pinned to the running kernel package version, plus a compiler and `dtc`.
3. Downloads NVIDIA's public sources for exactly that release (cached in
   `/var/cache/jetson-ecam-gmsl`) and checks their SHA-1.
4. Builds `tegra-camera.ko` and `ecam_yuv_gmsl.ko`
   (`scripts/build-modules.sh`).
5. **Gate:** proves every imported symbol and CRC matches the running kernel
   and NVIDIA's module symbol table, and that the 15 stock NVIDIA modules
   importing `tegra-camera` symbols still match (`scripts/check-modversions.py`).
6. **Gate:** compiles the camera overlay and applies it to this board's DTB
   with `fdtoverlay`.
7. Installs the modules under `/lib/modules/$(uname -r)/extra/ecam-gmsl` with
   a `depmod.d` override. NVIDIA's packaged files are never overwritten, so
   apt upgrades stay clean. Also installs the firmware to `/lib/firmware` and
   the overlay to `/boot`.
8. Enables the overlay with jetson-io on the "Jetson AGX CSI Connector" header,
   passing back any overlay the current boot entry already uses (for example a
   ReSpeaker HAT on the 40-pin header) so it is not dropped. If jetson-io is
   unavailable, it adds an `extlinux` entry instead. The original
   `extlinux.conf` is saved in `/var/lib/jetson-ecam-gmsl`.

Nothing is installed unless both gates pass. `--build-only` stops after them.

`--if-needed` exits immediately when this kernel, camera and source are
already installed; deploy tools call it on every run. Without `--camera`, the
previously installed camera is reused. The installer also enables
`jetson-ecam-gmsl.service`, which checks at boot whether the running kernel
still matches the installed modules. After a kernel update it rebuilds them
for the new kernel and reboots once to load them.

### Other L4T releases

The installer selects `releases/r<L4T>/` for the running release. For a newer
release in the same major line with no validated patch, it tries the newest
validated one. The patch must apply with zero fuzz and both gates must pass,
so a mismatch fails before anything changes. To validate a release properly:

```bash
scripts/verify-release.sh r39.2.1     # on any aarch64 Ubuntu 24.04 host
```

This downloads that release's NVIDIA kernel packages and sources, builds both
modules, runs the symbol gate against the stock modules, and applies all four
overlays to all three AGX Orin DTBs. CI runs it on every push.

JetPack 6.0 (L4T 36.3.0) predates the upstream fixes above and genuinely needs
e-con's kernel `Image`. Use e-con's own installer there.

## Uninstall

```bash
sudo ./uninstall.sh   # removes the modules, restores stock tegra-camera and extlinux.conf
```

## Verified, and still to be proven on hardware

`scripts/verify-release.sh r39.2.1` passes against NVIDIA's published L4T
39.2.1 artifacts:
- Both modules build with the device's toolchain (GCC 13, kernel built with 13.2).
- 252 and 95 imports resolve with matching CRCs, none of the 159 stock
  `tegra-camera` exports changed, and all 15 dependent NVIDIA modules match.
- Every overlay applies to p3701-0000, -0004 and -0005.

Streaming from a physical camera on a 39.2.1 board is the remaining runtime
check. After rebooting:

```bash
dmesg | grep -iE 'ecam|ar0821|tegra-camera'
v4l2-ctl --list-devices
gst-launch-1.0 v4l2src device=/dev/video0 ! 'video/x-raw,format=UYVY' ! fakesink -v
```

## License

`driver/`, `dts/` and the NVIDIA camera patches are GPL-2.0, as published by
e-con Systems and NVIDIA. The scripts are GPL-2.0 as well. e-con's MCU
firmware and applications are not included.
