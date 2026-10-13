#!/usr/bin/env python3
"""Extract bundled Cangjie and ArkTS examples into a new directory."""

import argparse
from pathlib import Path
import re


REFERENCE = Path(__file__).resolve().parents[1] / "references" / "interop_optimization_handoff.md"
FILE_BLOCK = re.compile(
    r"^<!-- embedded-file: ([^\n]+) -->\n\n```[^\n]*\n(.*?)^```\n",
    re.MULTILINE | re.DOTALL,
)


def embedded_files(document):
    files = FILE_BLOCK.findall(document)
    if not files:
        raise ValueError("No embedded files found")
    seen = set()
    for name, content in files:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or path == Path("."):
            raise ValueError("Invalid embedded path: " + name)
        if path in seen:
            raise ValueError("Duplicate embedded path: " + name)
        seen.add(path)
    return files


def extract(files, destination):
    destination = destination.resolve()
    if destination.exists():
        raise ValueError("Choose a new destination directory; existing directories are not overwritten")
    destination.mkdir(parents=True, exist_ok=False)
    for name, content in files:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("x", encoding="utf-8") as output:
            output.write(content)
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", nargs="?", type=Path, help="new output directory")
    parser.add_argument("--list", action="store_true", help="list embedded files without writing")
    args = parser.parse_args()
    if not args.list and args.destination is None:
        parser.error("provide a new destination directory, or use --list")
    try:
        files = embedded_files(REFERENCE.read_text(encoding="utf-8"))
        if args.list:
            for name, content in files:
                print(name)
        else:
            destination = extract(files, args.destination)
            print(f"Extracted {len(files)} files to {destination}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"Error: {error}\n")


if __name__ == "__main__":
    main()
