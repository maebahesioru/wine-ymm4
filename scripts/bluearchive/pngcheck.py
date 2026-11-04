#!/usr/bin/env python3
# PNG の実体検証: 壊れた ICO エントリ（容量不一致）を弾くために使う。
# 用法: pngcheck.py FILE … 合格したものだけ "WxH" を 1 行ずつ出力し、1 枚でも
# 不合格なら終了コード 1（不合格の内訳は stderr）。
import struct, sys, zlib

SIG = bytes([137, 80, 78, 71, 13, 10, 26, 10])


def check(path):
    d = open(path, "rb").read()
    if d[:8] != SIG:
        return None, "PNG 署名が無い"
    i, idat, w, h, seen_end = 8, b"", 0, 0, False
    while i + 8 <= len(d):
        ln = struct.unpack(">I", d[i:i + 4])[0]
        typ = d[i + 4:i + 8]
        data = d[i + 8:i + 8 + ln]
        if typ == b"IHDR":
            w, h = struct.unpack(">II", data[:8])
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            seen_end = True
            break
        i += 12 + ln
    if not seen_end:
        return None, "IEND が無い（切り詰め）"
    if len(idat) == 0:
        return None, "IDAT が無い"
    try:
        zlib.decompress(idat)
    except Exception as e:
        return None, "IDAT を展開できない: %s" % e
    if w != h or w < 16 or w > 512:
        return None, "寸法が想定外: %dx%d" % (w, h)
    return (w, h), None


def main():
    bad = 0
    for p in sys.argv[1:]:
        dim, err = check(p)
        if dim is None:
            print("%s: %s" % (p, err), file=sys.stderr)
            bad += 1
        else:
            print("%dx%d" % dim)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
