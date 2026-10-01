#!/usr/bin/env python3
"""Reject obvious private paths/credentials in release files without printing them."""
import argparse
from pathlib import Path
import re
import sys
import zipfile

patterns = {
    "personal_directory": re.compile(rb"/(?:Users|home)/[^/\x00\r\n\" ]+|[A-Za-z]:[\\/]Users[\\/][^\\/\x00\r\n\" ]+"),
    "github_credential": re.compile(rb"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"),
    "private_key": re.compile(rb"-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----[\r\n]+[A-Za-z0-9+/=\r\n]{100,}-----END (?:[A-Z]+ )?PRIVATE KEY-----"),
}


def inspect_bytes(data):
    # Windows UTF-16 strings can also retain a build machine's directory.
    representations = [data, data[::2], data[1::2]]
    return [name for name, pattern in patterns.items()
            if any(pattern.search(value) for value in representations)]


def inspect_file(path):
    if not zipfile.is_zipfile(path):
        return inspect_bytes(path.read_bytes())
    findings = set()
    with zipfile.ZipFile(path) as archive:
        for entry in archive.infolist():
            if entry.is_dir():
                continue
            findings.update(inspect_bytes(entry.filename.encode("utf-8")))
            findings.update(inspect_bytes(archive.read(entry)))
    return sorted(findings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", type=Path, nargs="+")
    args = parser.parse_args()
    failed = False
    for path in args.files:
        findings = inspect_file(path)
        if findings:
            failed = True
            print("Privacy check failed:", path.name, ", ".join(findings), file=sys.stderr)
        else:
            print("Privacy check passed:", path.name)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
