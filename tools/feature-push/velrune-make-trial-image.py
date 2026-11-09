#!/usr/bin/env python3
"""Make the RAM-boot TRIAL image of a Velrune generation: the Nix-built boot image with
`fp6.trial=1` added to the kernel command line (which arms fp6-trial-revert.timer, a
15-minute reboot into the installed boot_b), and nothing else changed.

Local file operation only: never touches the phone, fastboot or a block device.
Refuses to overwrite; regular files only. Checks that the source is an Android v2 image
of exactly its own size, pins exactly one mobile-nixos.generation equal to --generation,
does not already carry fp6.trial, and that every byte outside the two cmdline fields and
the SHA1 id field is identical in the result. The id is recomputed the way the source's is
(SHA1 over kernel, ramdisk, second, dtbo, dtb with sizes) and the tool first checks that
this reproduces the source's own id, so a wrong recipe cannot go unnoticed.

  velrune-make-trial-image.py SOURCE.img OUTPUT.img --generation /nix/store/...-nixos-system-... \
      [--source-sha256 HEX]
"""
import argparse, hashlib, json, pathlib, struct, sys

def cmdline(img):
    return (img[64:576] + img[608:1632]).split(b"\0", 1)[0].decode()

def ident(img, ksz, rsz, dtb, page):
    up = lambda n: (n + page - 1) // page * page
    koff = page; roff = koff + up(ksz); doff = roff + up(rsz)
    h = hashlib.sha1()
    for blob in (img[koff:koff + ksz], img[roff:roff + rsz], b"", b"", img[doff:doff + dtb]):
        h.update(blob); h.update(struct.pack("<I", len(blob)))
    return h.digest() + bytes(12)

def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("source", type=pathlib.Path)
    p.add_argument("output", type=pathlib.Path)
    p.add_argument("--generation", required=True, help="the toplevel the image must pin")
    p.add_argument("--source-sha256")
    a = p.parse_args()
    if a.output.exists():
        sys.exit("refusing to overwrite " + str(a.output))
    if str(a.output.resolve()).startswith("/dev/"):
        sys.exit("regular files only")
    src = a.source.read_bytes()
    sha = hashlib.sha256(src).hexdigest()
    if a.source_sha256 and sha != a.source_sha256:
        sys.exit("source SHA256 mismatch")
    if src[:8] != b"ANDROID!":
        sys.exit("not an Android boot image")
    ksz, _, rsz, _, ssz, _, _, page, version, _ = struct.unpack_from("<10I", src, 8)
    dtb = struct.unpack_from("<I", src, 1648)[0]
    up = lambda n: (n + page - 1) // page * page
    if version != 2 or page != 4096 or ssz != 0 or struct.unpack_from("<I", src, 40)[0] != 2:
        sys.exit("expected header v2, page 4096, no second stage")
    if len(src) != page + up(ksz) + up(rsz) + up(dtb):
        sys.exit("image size does not match its header")
    if ident(src, ksz, rsz, dtb, page) != src[576:608]:
        sys.exit("cannot reproduce the source's own id: recipe is wrong for this image")
    old = cmdline(src)
    toks = old.split()
    if toks.count("mobile-nixos.generation=" + a.generation) != 1 or sum(t.startswith("mobile-nixos.generation=") for t in toks) != 1:
        sys.exit("source must pin exactly one generation, and it must be --generation")
    if any(t.startswith("fp6.trial") for t in toks):
        sys.exit("source already carries fp6.trial")
    new = " ".join(toks + ["fp6.trial=1"]).encode()
    if len(new) >= 1536 or b"\0" in new:
        sys.exit("cmdline too long")
    out = bytearray(src)
    out[64:576] = new[:512].ljust(512, b"\0")
    out[608:1632] = new[512:].ljust(1024, b"\0")
    out[576:608] = ident(out, ksz, rsz, dtb, page)  # kernel, ramdisk, dtb unchanged: same id
    allowed = set(range(64, 1632))
    if any(i not in allowed for i in range(len(src)) if src[i] != out[i]) or len(out) != len(src):
        sys.exit("internal error: bytes outside the cmdline fields changed")
    if cmdline(out).split().count("fp6.trial=1") != 1:
        sys.exit("internal error: marker missing")
    with a.output.open("xb") as f:
        f.write(out)
    rec = {"source": str(a.source), "source_sha256": sha, "output": str(a.output),
           "sha256": hashlib.sha256(out).hexdigest(), "size": len(out), "generation": a.generation,
           "old_cmdline": old, "new_cmdline": new.decode()}
    a.output.with_suffix(".json").write_text(json.dumps(rec, indent=1) + "\n")
    print(json.dumps(rec, indent=1))

if __name__ == "__main__":
    main()
