#!/usr/bin/env python3
"""Build deterministic AMD64 COFF icon/manifest resources using only stdlib."""
import argparse
from pathlib import Path
import struct
import sys
import tempfile
import xml.etree.ElementTree as xml


def read_icon(data):
    if len(data) < 6:
        raise ValueError("ICO header is truncated")
    reserved, icon_type, count = struct.unpack_from("<HHH", data)
    if reserved != 0 or icon_type != 1 or count == 0:
        raise ValueError("Expected a nonempty ICO image")
    table_end = 6 + count * 16
    if table_end > len(data):
        raise ValueError("ICO directory is truncated")
    images = []
    ranges = []
    for index in range(count):
        entry = struct.unpack_from("<BBBBHHII", data, 6 + index * 16)
        width, height, colors, entry_reserved, planes, bits, size, offset = entry
        if entry_reserved != 0 or not size or offset < table_end or offset + size > len(data):
            raise ValueError("ICO image has an invalid directory entry")
        if any(offset < end and offset + size > start for start, end in ranges):
            raise ValueError("ICO image ranges overlap")
        ranges.append((offset, offset + size))
        image = data[offset:offset + size]
        expected_width, expected_height = width or 256, height or 256
        if image.startswith(b"\x89PNG\r\n\x1a\n"):
            if len(image) < 33 or image[8:16] != b"\x00\x00\x00\rIHDR":
                raise ValueError("ICO PNG header is invalid")
            actual_width, actual_height = struct.unpack_from(">II", image, 16)
        elif len(image) >= 40 and struct.unpack_from("<I", image)[0] >= 40:
            actual_width, doubled_height = struct.unpack_from("<ii", image, 4)
            actual_height = abs(doubled_height) // 2
            if doubled_height % 2:
                raise ValueError("ICO bitmap height is invalid")
        else:
            raise ValueError("ICO entry must contain PNG or a Windows bitmap")
        if (actual_width, actual_height) != (expected_width, expected_height):
            raise ValueError("ICO dimensions differ from the directory entry")
        group_entry = struct.pack("<BBBBHHIH", width, height, colors, 0,
                                  planes, bits, size, index + 1)
        images.append((group_entry, image))
    return images


def build_resource_section(images, manifest):
    # Resource directory offsets are relative to .rsrc; data RVAs are relocated.
    group = struct.pack("<HHH", 0, 1, len(images))
    group += b"".join(entry for entry, image in images)
    resources = {
        3: {index + 1: {1033: image} for index, (entry, image) in enumerate(images)},
        14: {1: {1033: group}},
        24: {1: {1033: manifest}},
    }
    data = bytearray()
    leaves = []

    def append_directory(entries):
        offset = len(data)
        keys = sorted(entries)
        data.extend(struct.pack("<IIHHHH", 0, 0, 0, 0, 0, len(keys)))
        data.extend(b"\x00" * (8 * len(keys)))
        for index, key in enumerate(keys):
            value = entries[key]
            pointer_offset = offset + 16 + 8 * index
            if isinstance(value, dict):
                child_offset = append_directory(value) | 0x80000000
            else:
                child_offset = len(data)
                data.extend(b"\x00" * 16)
                leaves.append((child_offset, value))
            struct.pack_into("<II", data, pointer_offset, key, child_offset)
        return offset

    append_directory(resources)
    relocations = []
    for entry_offset, value in leaves:
        data.extend(b"\x00" * (-len(data) % 4))
        struct.pack_into("<IIII", data, entry_offset, len(data), len(value), 0, 0)
        relocations.append(entry_offset)
        data.extend(value)
    data.extend(b"\x00" * (-len(data) % 4))
    return bytes(data), relocations


def build_coff(images, manifest):
    section, relocations = build_resource_section(images, manifest)
    if len(relocations) > 65535:
        raise ValueError("Too many resource entries for COFF")
    raw_offset = 20 + 40
    relocation_offset = raw_offset + len(section)
    symbol_offset = relocation_offset + 10 * len(relocations)
    header = struct.pack("<HHIIIHH", 0x8664, 1, 0, symbol_offset, 1, 0, 0)
    section_header = struct.pack("<8sIIIIIIHHI", b".rsrc", 0, 0, len(section),
                                 raw_offset, relocation_offset, 0,
                                 len(relocations), 0, 0x40300040)
    # IMAGE_REL_AMD64_ADDR32NB resolves the .rsrc symbol plus each blob offset.
    relocation_table = b"".join(struct.pack("<IIH", offset, 0, 3)
                                for offset in relocations)
    symbol = struct.pack("<8sIhHBB", b".rsrc", 0, 1, 0, 3, 0)
    return header + section_header + section + relocation_table + symbol + struct.pack("<I", 4)


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", nargs="?", type=Path,
                        default=root / "windows/app_windows_amd64.syso")
    args = parser.parse_args()
    try:
        images = read_icon((root / "assets/app.ico").read_bytes())
        manifest = (root / "assets/windows.manifest").read_bytes()
        xml.fromstring(manifest)
        result = build_coff(images, manifest)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        # Atomic replacement avoids leaving a partially written linker input.
        with tempfile.NamedTemporaryFile(dir=args.output.parent, delete=False) as temporary:
            temporary.write(result)
            temporary_path = Path(temporary.name)
        try:
            temporary_path.chmod(0o644)
            temporary_path.replace(args.output)
        finally:
            temporary_path.unlink(missing_ok=True)
        print(f"Built {args.output.name}: {len(images)} icon sizes and application manifest")
        return 0
    except (OSError, ValueError, xml.ParseError) as error:
        print(f"Resource build failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
