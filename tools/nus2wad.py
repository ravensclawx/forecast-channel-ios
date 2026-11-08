#!/usr/bin/env python3
"""Download a Wii title from the NUS CDN (same URLs Dolphin uses) and pack it as a WAD."""
import hashlib, struct, sys, urllib.request
from pathlib import Path

PREFIX = "http://nus.cdn.wup.shop.nintendo.net/ccs/download"

def get(url):
    print("GET", url)
    req = urllib.request.Request(url, headers={"User-Agent": "wii libnup/1.0"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return r.read()

def align(n, a=0x40):
    return (n + a - 1) & ~(a - 1)

def pad(b, a=0x40):
    return b + b"\0" * (align(len(b), a) - len(b))

SIG_LEN = {0x10000: 0x200, 0x10001: 0x100, 0x10002: 0x3C}
KEY_LEN = {0: 0x200 + 4 + 0x34, 1: 0x100 + 4 + 0x34, 2: 0x3C + 0x3C}

def split_certs(blob):
    certs, off = {}, 0
    while off + 4 <= len(blob):
        st = struct.unpack(">I", blob[off:off + 4])[0]
        if st not in SIG_LEN:
            break
        body = off + align(4 + SIG_LEN[st])
        kt = struct.unpack(">I", blob[body + 0x40:body + 0x44])[0]
        name = blob[body + 0x44:body + 0x84].rstrip(b"\0").decode()
        end = body + 0x88 + KEY_LEN[kt]
        certs[name[:2]] = blob[off:end]
        off = align(end)
    return certs

def main(title_id, version, out):
    base = f"{PREFIX}/{title_id.lower()}"
    cetk = get(f"{base}/cetk")
    tmd_raw = get(f"{base}/tmd.{version}" if version else f"{base}/tmd")

    ticket = cetk[:0x2A4]
    n = struct.unpack(">H", tmd_raw[0x1DE:0x1E0])[0]
    tmd_len = 0x1E4 + 36 * n
    tmd = tmd_raw[:tmd_len]

    certs = {**split_certs(cetk[0x2A4:]), **split_certs(tmd_raw[tmd_len:])}
    chain = b"".join(pad(certs[k]) for k in ("CA", "XS", "CP"))

    data = b""
    for i in range(n):
        c = tmd[0x1E4 + 36 * i:0x1E4 + 36 * (i + 1)]
        cid, idx, ctype, size = struct.unpack(">IHHQ", c[:16])
        blob = get(f"{base}/{cid:08x}")
        if len(blob) < size:
            sys.exit(f"content {cid:08x} truncated")
        data += pad(blob[:align(size, 16)])

    hdr = struct.pack(">IHHIIIIII", 0x20, 0x4973, 0, len(chain), 0, len(ticket), len(tmd), len(data), 0)
    wad = pad(hdr) + chain + pad(ticket) + pad(tmd) + data
    Path(out).write_bytes(wad)
    tver = struct.unpack(">H", tmd[0x1DC:0x1DE])[0]
    print(f"Wrote {out}: {len(wad)} bytes, {n} contents, title version {tver}, sha1 {hashlib.sha1(wad).hexdigest()}")

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "", sys.argv[3] if len(sys.argv) > 3 else "out.wad")
