#!/usr/bin/env python3
import ast
import struct
import sys


def u32(value):
    return value & 0xFFFFFFFF


def sfh_get16(data, offset):
    return data[offset] | (data[offset + 1] << 8)


def signed_byte(value):
    return value - 256 if value > 127 else value


def sfh_hash(data):
    if isinstance(data, str):
        data = data.encode("utf-8")
    length = len(data)
    if length <= 0:
        return 0

    h = length
    rem = length & 3
    blocks = length >> 2
    offset = 0

    for _ in range(blocks):
        h = u32(h + sfh_get16(data, offset))
        tmp = u32((sfh_get16(data, offset + 2) << 11) ^ h)
        h = u32((h << 16) ^ tmp)
        offset += 4
        h = u32(h + (h >> 11))

    if rem == 3:
        h = u32(h + sfh_get16(data, offset))
        h = u32(h ^ (h << 16))
        h = u32(h ^ (signed_byte(data[offset + 2]) << 18))
        h = u32(h + (h >> 11))
    elif rem == 2:
        h = u32(h + sfh_get16(data, offset))
        h = u32(h ^ (h << 11))
        h = u32(h + (h >> 17))
    elif rem == 1:
        h = u32(h + signed_byte(data[offset]))
        h = u32(h ^ (h << 10))
        h = u32(h + (h >> 1))

    h = u32(h ^ (h << 3))
    h = u32(h + (h >> 5))
    h = u32(h ^ (h << 4))
    h = u32(h + (h >> 17))
    h = u32(h ^ (h << 25))
    h = u32(h + (h >> 6))
    return h


def canonical_key(value):
    out = []
    prev_space = True
    for char in value:
        if char.isspace():
            if not prev_space:
                out.append(" ")
            prev_space = True
        else:
            out.append(char)
            prev_space = False
    if out and out[-1] == " ":
        out.pop()
    return "".join(out)


def lmo_key_hash(msgid, context=None, plural=-1):
    key = ""
    if context:
        key += canonical_key(context) + "\1"
    key += canonical_key(msgid)
    if plural > -1:
        key += "\2%d" % plural
    return sfh_hash(key)


def decode_po_string(text):
    return ast.literal_eval(text)


def parse_po(path):
    entries = []
    current = None
    field = None

    def flush():
        nonlocal current
        if not current:
            return
        msgid = current.get("msgid")
        msgstr = current.get("msgstr")
        if msgid is not None and msgstr is not None and not current.get("fuzzy"):
            entries.append((current.get("msgctxt"), msgid, msgstr))
        current = None

    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line:
                flush()
                field = None
                continue
            if line.startswith("#,") and "fuzzy" in line:
                if current is None:
                    current = {}
                current["fuzzy"] = True
                continue
            if line.startswith("#"):
                continue
            if line.startswith("msgctxt "):
                if current is None:
                    current = {}
                current["msgctxt"] = decode_po_string(line[8:].strip())
                field = "msgctxt"
                continue
            if line.startswith("msgid "):
                if current is None:
                    current = {}
                current["msgid"] = decode_po_string(line[6:].strip())
                field = "msgid"
                continue
            if line.startswith("msgstr "):
                if current is None:
                    current = {}
                current["msgstr"] = decode_po_string(line[7:].strip())
                field = "msgstr"
                continue
            if line.startswith('"') and field:
                current[field] = current.get(field, "") + decode_po_string(line)

    flush()
    return entries


def write_lmo(entries, output_path):
    payload = bytearray()
    index = []

    for context, msgid, msgstr in entries:
        if msgid and not msgstr:
            continue

        value = msgstr.encode("utf-8")
        offset = len(payload)
        payload.extend(value)
        while len(payload) % 4:
            payload.append(0)

        key_hash = 0 if msgid == "" and context is None else lmo_key_hash(msgid, context)
        value_hash = sfh_hash(value)
        index.append((key_hash, value_hash, offset, len(value)))

    index.sort(key=lambda item: item[0])
    index_offset = len(payload)

    with open(output_path, "wb") as handle:
        handle.write(payload)
        for item in index:
            handle.write(struct.pack("!IIII", *item))
        handle.write(struct.pack("!I", index_offset))


def main(argv):
    if len(argv) != 3:
        print("usage: po2lmo.py input.po output.lmo", file=sys.stderr)
        return 2
    write_lmo(parse_po(argv[1]), argv[2])
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
