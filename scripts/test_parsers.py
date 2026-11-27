"""Reconstruct the pinned backend and run its no-data parser corpus tests."""

import argparse
import subprocess
import tempfile
from pathlib import Path

import build_native as backend


def prepare(checkout, source):
    checkout.mkdir(parents=True, exist_ok=False)
    backend.checkout_source(
        checkout, source, backend.REVISION, backend.PATCHES, backend.RENDER_CRATE
    )


def test(checkout):
    subprocess.run(
        ["cargo", "test", "--locked", "-p", "victory-fuzz", "--lib", "--", "--nocapture"],
        cwd=checkout,
        check=True,
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", help="optional local Git clone holding the pinned revision")
    parser.add_argument("--checkout", type=Path, help="new persistent directory under target/native")
    parser.add_argument("--prepare-only", action="store_true", help="prepare a checkout for cargo-fuzz")
    args = parser.parse_args()
    if args.prepare_only and args.checkout is None:
        parser.error("--prepare-only requires --checkout")
    backend.WORK.mkdir(parents=True, exist_ok=True)
    source = str(Path(args.source).resolve()) if args.source else backend.UPSTREAM
    if args.checkout:
        checkout = args.checkout.resolve()
        if not checkout.is_relative_to(backend.WORK.resolve()) or checkout == backend.WORK.resolve():
            parser.error("--checkout must be a new directory under target/native")
        prepare(checkout, source)
        if not args.prepare_only:
            test(checkout)
        print(f"Parser workspace: {checkout}")
    else:
        with tempfile.TemporaryDirectory(dir=backend.WORK, prefix="parser-tests-") as folder:
            checkout = Path(folder) / "source"
            prepare(checkout, source)
            test(checkout)
