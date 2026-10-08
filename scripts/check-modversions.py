#!/usr/bin/env python3
"""Prove that rebuilt camera modules will load on this exact L4T kernel.

Ubuntu's 6.8 Tegra kernels store module symbol versions in a compact,
variable-length ``__versions`` layout that the distribution's depmod/modprobe
cannot parse (they print "disagrees about version" even for stock modules).
This reads the layout directly and checks, before anything is installed:

* every symbol each rebuilt module imports exists in vmlinux, NVIDIA's OOT
  symbol table, or a sibling rebuilt module, with an identical CRC;
* every symbol the stock tegra-camera.ko exported is still exported by the
  patched build with the same CRC, so NVIDIA modules that depend on it
  (VI, ISP, CoE, sensor drivers) keep loading.

Exit status is non-zero on any mismatch.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


def _sections(data: bytes) -> dict[str, tuple[int, int]]:
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("expected a little-endian ELF64 module")
    shoff = struct.unpack_from("<Q", data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    headers = [struct.unpack_from("<IIQQQQIIQQ", data, shoff + i * shentsize) for i in range(shnum)]
    names_offset = headers[shstrndx][4]

    def name(offset: int) -> str:
        start = names_offset + offset
        return data[start : data.index(b"\0", start)].decode()

    return {name(h[0]): (h[4], h[5]) for h in headers}


def module_imports(path: Path) -> dict[str, int]:
    """Return {symbol: crc} from a module's __versions section."""

    data = path.read_bytes()
    sections = _sections(data)
    if "__versions" not in sections:
        return {}
    offset, size = sections["__versions"]
    imports: dict[str, int] = {}
    cursor = 0
    while cursor < size:
        if size - cursor < 8:
            break
        entry_size, crc = struct.unpack_from("<II", data, offset + cursor)
        if entry_size == 0:  # trailing section padding
            break
        if entry_size < 9 or cursor + entry_size > size:
            raise ValueError(f"{path}: unsupported __versions layout")
        raw = data[offset + cursor + 8 : offset + cursor + entry_size]
        imports[raw.split(b"\0", 1)[0].decode()] = crc
        cursor += entry_size
    return imports


def read_symvers(path: Path) -> dict[str, tuple[int, str]]:
    table: dict[str, tuple[int, str]] = {}
    for line in path.read_text().splitlines():
        fields = line.split("\t")
        if len(fields) >= 3:
            table[fields[1]] = (int(fields[0], 16), fields[2])
    return table


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--kernel-symvers", type=Path, required=True)
    parser.add_argument("--oot-symvers", type=Path, required=True)
    parser.add_argument("--camera-symvers", type=Path, required=True,
                        help="Module.symvers produced by the patched tegra-camera build")
    parser.add_argument("--stock-modules", type=Path,
                        help="installed module tree to check stock dependants against")
    parser.add_argument("modules", type=Path, nargs="+")
    args = parser.parse_args()

    kernel = read_symvers(args.kernel_symvers)
    oot = read_symvers(args.oot_symvers)
    camera = read_symvers(args.camera_symvers)
    available = {**kernel, **oot, **camera}
    failures = 0

    for module in args.modules:
        imports = module_imports(module)
        unresolved = sorted(name for name in imports if name not in available)
        mismatched = sorted(name for name, crc in imports.items()
                            if name in available and available[name][0] != crc)
        status = "ok" if not unresolved and not mismatched else "FAIL"
        print(f"{module.name}: {len(imports)} imports, {len(unresolved)} unresolved, "
              f"{len(mismatched)} CRC mismatches [{status}]")
        for name in unresolved[:10]:
            print(f"  unresolved: {name}")
        for name in mismatched[:10]:
            print(f"  CRC mismatch: {name}")
        failures += bool(unresolved or mismatched)

    stock_camera = {name: value for name, value in oot.items()
                    if value[1].endswith("camera/tegra-camera")}
    dropped = sorted(name for name in stock_camera if name not in camera)
    changed = sorted(name for name, value in stock_camera.items()
                     if name in camera and camera[name][0] != value[0])
    added = sorted(set(camera) - set(stock_camera))
    print(f"tegra-camera exports: {len(stock_camera)} stock, {len(dropped)} dropped, "
          f"{len(changed)} changed, added {added}")
    failures += bool(dropped or changed)

    if args.stock_modules:
        dependants = broken = 0
        for module in sorted(args.stock_modules.rglob("*.ko")):
            if module.name == "tegra-camera.ko":
                continue
            imports = module_imports(module)
            uses = [name for name in imports if name in stock_camera]
            if not uses:
                continue
            dependants += 1
            bad = [name for name in uses if name not in camera or camera[name][0] != imports[name]]
            if bad:
                broken += 1
                print(f"  stock dependant broken: {module.name}: {bad[:5]}")
        print(f"stock modules importing tegra-camera: {dependants}, broken: {broken}")
        failures += bool(broken)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
