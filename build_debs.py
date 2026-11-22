#!/usr/bin/env python3
"""
LiquidGlas v1.0.1 - build roothide (隐根) and rootless (无根) .deb packages.

Payload source: ref_liquidglass27/data (the only compiled binaries in the repo)
             + extra/ (optional, e.g. CI-built LGPercentageDisplay.dylib + plist)

  roothide : payload paths stay rootful-like (Library/...), Architecture iphoneos-arm64e
  rootless : payload paths gain /var/jb prefix, Architecture iphoneos-arm64

NOTE: the three original dylibs are roothide builds (they link
@loader_path/.jbroot/usr/lib/libroothide.dylib). The rootless package is a
structural conversion only; those binaries are NOT recompiled. The percentage
overlay in extra/ is compiled separately by .github/workflows/build-percentage.yml.

No external tools required: pure Python builds ar + tar + gzip/lzma deb members.
"""
import gzip
import hashlib
import io
import lzma
import os
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "ref_liquidglass27" / "data"
EXTRA = ROOT / "extra"          # optional add-ons (CI-built percentage dylib + plist)
OUT = ROOT / "release-debs"

PKG = "com.wang7799.liquidglas"
VERSION = "1.0.3"
NAME = "LiquidGlas"
MAINTAINER = "wang7799"
AUTHOR = "wang7799"
SECTION = "Tweaks"
DEPENDS = "mobilesubstrate, preferenceloader, firmware (>= 15.0)"
HOMEPAGE = "https://github.com/wang7799/LiquidGlas-v1.0.1"

POSTINST = b"#!/bin/sh\n# Loading is a deliberate user action; package installation never restarts UI.\nexit 0\n"

SCHEMES = {
    "roothide": {
        "arch": "iphoneos-arm64e",
        "prefix": "",
        "desc": "iOS Control Center Liquid Glass effect (roothide / 隐根 build)",
    },
    "rootless": {
        "arch": "iphoneos-arm64",
        "prefix": "var/jb/",
        "desc": "iOS Control Center Liquid Glass effect (rootless / 无根 build, structural conversion)",
    },
}


def collect_payload():
    # extra/ 中同路径的文件覆盖主 payload（便于替换/追加模块）
    collected = {}
    for base in (SRC, EXTRA):
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames.sort()
            for fn in sorted(filenames):
                full = Path(dirpath) / fn
                collected[full.relative_to(base).as_posix()] = full
    return sorted(collected.items())


def make_tar(entries):
    """entries: list of (arcname, bytes|None, mode, is_dir)"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tf:
        for arcname, data, mode, is_dir in entries:
            ti = tarfile.TarInfo(arcname)
            ti.mode = mode
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "root"
            ti.mtime = 0
            if is_dir:
                ti.type = tarfile.DIRTYPE
                tf.addfile(ti)
            else:
                ti.type = tarfile.REGTYPE
                ti.size = len(data)
                tf.addfile(ti, io.BytesIO(data))
    return buf.getvalue()


def ar_member(name, data):
    hdr = (
        f"{name:<16}{'0':<12}{'0':<6}{'0':<6}{'100644':<8}{len(data):<10}`\n"
    ).encode("ascii")
    pad = b"\n" if len(data) % 2 else b""
    return hdr + data + pad


def build(scheme, files):
    cfg = SCHEMES[scheme]
    prefix = cfg["prefix"]
    total = sum(p.stat().st_size for _, p in files)
    installed_size = (total + 1023) // 1024

    control = (
        f"Package: {PKG}\n"
        f"Name: {NAME}\n"
        f"Version: {VERSION}\n"
        f"Architecture: {cfg['arch']}\n"
        f"Maintainer: {MAINTAINER}\n"
        f"Author: {AUTHOR}\n"
        f"Section: {SECTION}\n"
        f"Depends: {DEPENDS}\n"
        f"Description: {cfg['desc']}\n"
        f"Homepage: {HOMEPAGE}\n"
        f"Installed-Size: {installed_size}\n"
    ).encode("utf-8")

    control_entries = [
        ("./control", control, 0o644, False),
        ("./postinst", POSTINST, 0o755, False),
    ]
    control_tar = gzip.compress(make_tar(control_entries), mtime=0)

    # data.tar: root dir, all intermediate dirs, then files
    dirs = {""}
    data_entries = [("./", None, 0o755, True)]
    for rel, _ in files:
        parts = rel.split("/")
        for i in range(1, len(parts)):
            dirs.add("/".join(parts[:i]))
    if prefix:
        pp = prefix.rstrip("/").split("/")
        for i in range(1, len(pp) + 1):
            dirs.add("/".join(pp[:i]))
    for d in sorted(dirs):
        if d:
            data_entries.append((f"./{d}/", None, 0o755, True))
    for rel, full in files:
        mode = 0o755 if full.suffix in (".dylib",) or full.name in ("BGPreferences",) else 0o644
        data_entries.append((f"./{prefix}{rel}", full.read_bytes(), mode, False))
    data_tar = lzma.compress(make_tar(data_entries), format=lzma.FORMAT_ALONE, preset=6)

    deb = (
        b"!<arch>\n"
        + ar_member("debian-binary", b"2.0\n")
        + ar_member("control.tar.gz", control_tar)
        + ar_member("data.tar.lzma", data_tar)
    )
    fname = f"LiquidGlas_v{VERSION}_{cfg['arch']}-{scheme}.deb"
    path = OUT / fname
    path.write_bytes(deb)
    return path, control.decode(), data_entries


def main():
    if not SRC.is_dir():
        raise SystemExit(f"payload not found: {SRC}")
    OUT.mkdir(exist_ok=True)
    files = collect_payload()
    print(f"payload: {len(files)} files from {SRC}")
    for scheme in ("roothide", "rootless"):
        path, control, entries = build(scheme, files)
        sha = hashlib.sha256(path.read_bytes()).hexdigest()
        print(f"\n=== {path.name}  ({path.stat().st_size} bytes)")
        print(f"sha256: {sha}")
        print(control.strip())
        print(f"entries: {len(entries)} (dirs + files)")
        dyn = [e[0] for e in entries if e[0].endswith(".dylib")]
        print("dylibs:", *dyn, sep="\n  ")


if __name__ == "__main__":
    main()
