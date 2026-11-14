#!/usr/bin/env python3
"""Build and inspect .vescpkg files without VESC Tool.

Produces byte-for-byte the same container format as VESC Tool's
CodeLoader::packVescPackage() / lispPackImports():

    qCompress( "VESC Packet\\0"
               { name\\0  i32 len  bytes } ...
               "qmlIsFullscreen\\0" i32 1 u8 )

qCompress = 4-byte big-endian uncompressed size + zlib stream (level 9).
lispData  = u16 flags(0) + code + '\\0' + i16 import count (0).

Usage:
    build_vescpkg.py build  path/to/pkgdesc.qml [-o out.vescpkg]
    build_vescpkg.py verify path/to/file.vescpkg
"""

import argparse
import html
import os
import re
import struct
import sys
import zlib

MAGIC = "VESC Packet"


# --------------------------------------------------------------------------
#  Low level helpers (VByteArray equivalents)
# --------------------------------------------------------------------------
def vb_string(s: str) -> bytes:
    return s.encode("utf-8") + b"\0"


def vb_field(name: str, data: bytes) -> bytes:
    return vb_string(name) + struct.pack(">i", len(data)) + data


def q_compress(data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + zlib.compress(data, 9)


def q_uncompress(data: bytes) -> bytes:
    (size,) = struct.unpack(">I", data[:4])
    out = zlib.decompress(data[4:])
    if len(out) != size:
        raise ValueError("size header mismatch")
    return out


# --------------------------------------------------------------------------
#  Package description
# --------------------------------------------------------------------------
def read_props(pkgdesc_path: str) -> dict:
    txt = open(pkgdesc_path, encoding="utf-8").read()
    props = {}
    for m in re.finditer(r'property\s+(string|bool)\s+(\w+)\s*:\s*("([^"]*)"|true|false)', txt):
        kind, key, raw, sval = m.groups()
        props[key] = sval if kind == "string" else (raw == "true")
    props["_qml"] = txt
    return props


def md_to_html(md: str) -> str:
    head = ('<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0//EN" '
            '"http://www.w3.org/TR/REC-html40/strict.dtd">\n')
    try:
        import markdown  # optional, gives nicer output
        return head + markdown.markdown(md, extensions=["tables"])
    except ImportError:
        return head + "<pre>" + html.escape(md) + "</pre>"


def lisp_pack(code: bytes) -> bytes:
    if "@import" in code.decode("utf-8", "replace"):
        sys.exit("error: @import is not supported by this packer, use VESC Tool")
    data = struct.pack(">H", 0) + code
    if not data.endswith(b"\0"):
        data += b"\0"
    return data + struct.pack(">h", 0)  # no imported files


def build(pkgdesc: str, out: str = None) -> str:
    base = os.path.dirname(os.path.abspath(pkgdesc))
    p = read_props(pkgdesc)

    def rd(key, mode="rb"):
        return open(os.path.join(base, p[key]), mode).read()

    body = vb_string(MAGIC)
    if p.get("pkgName"):
        body += vb_field("name", p["pkgName"].encode())
    if p.get("pkgDescriptionMd"):
        md = rd("pkgDescriptionMd", "r")
        body += vb_field("description", md_to_html(md).encode())
        body += vb_field("description_md", md.encode())
    if p.get("pkgLisp"):
        body += vb_field("lispData", lisp_pack(rd("pkgLisp")))
    if p.get("pkgQml"):
        body += vb_field("qmlFile", rd("pkgQml"))
    body += vb_field("pkgDescQml", p["_qml"].encode())
    body += vb_string("qmlIsFullscreen") + struct.pack(">i", 1) + \
        bytes([1 if p.get("pkgQmlIsFullscreen") else 0])

    out = out or os.path.join(base, p.get("pkgOutput", "package.vescpkg"))
    with open(out, "wb") as f:
        f.write(q_compress(body))
    return out


# --------------------------------------------------------------------------
#  Verification (mirrors CodeLoader::unpackVescPackage)
# --------------------------------------------------------------------------
def unpack(path: str) -> dict:
    vb = q_uncompress(open(path, "rb").read())

    def pop_str(i):
        j = vb.index(b"\0", i)
        return vb[i:j].decode(), j + 1

    name, i = pop_str(0)
    if name != MAGIC:
        raise ValueError("invalid VESC package")
    fields = {}
    while i < len(vb):
        key, i = pop_str(i)
        (ln,) = struct.unpack(">i", vb[i:i + 4])
        i += 4
        fields[key] = vb[i:i + ln]
        i += ln
    return fields


def verify(path: str) -> None:
    f = unpack(path)
    print(f"{path}: OK ({os.path.getsize(path)} bytes compressed)")
    for k, v in f.items():
        print(f"  {k:16s} {len(v):7d} bytes")
    if "lispData" in f:
        ld = f["lispData"]
        assert ld[:2] == b"\0\0", "lisp flags"
        code = ld[2:ld.index(b"\0", 2)]
        print(f"  lisp code        {len(code):7d} bytes, imports: "
              f"{struct.unpack('>h', ld[len(code) + 3:len(code) + 5])[0]}")
    for k in ("name", "qmlIsFullscreen"):
        if k in f:
            print(f"  {k} = {f[k] if k != 'name' else f[k].decode()!r}")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("pkgdesc")
    b.add_argument("-o", "--out")
    v = sub.add_parser("verify")
    v.add_argument("vescpkg")
    a = ap.parse_args()

    if a.cmd == "build":
        out = build(a.pkgdesc, a.out)
        verify(out)
    else:
        verify(a.vescpkg)


if __name__ == "__main__":
    main()
