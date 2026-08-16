#!/usr/bin/env python3
"""Regenerate sources.json from the kenn-io GitHub releases.

This is both the bootstrap tool and the update tool: producing the initial set
of hashes and refreshing them are the same operation, so there is no separate
"pin by hand once" step.

No tarballs are downloaded. Every release publishes a checksum manifest, so the
SRI hashes are derived from ~7 small text files rather than ~500MB of binaries.

Usage:
    ./update.py                       # bump everything to latest
    ./update.py --tool kata forge     # only these
    ./update.py --pin kata=0.14.3     # hold one at a version
    ./update.py --check               # exit 1 if sources.json is stale (CI)
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

SOURCES = Path(__file__).with_name("sources.json")

# repo -> binary name shipped inside the tarball. These differ: the `forge`
# repo installs a binary called `kenn-forge`.
TOOLS: dict[str, str] = {
    "kata": "kata",
    "forge": "kenn-forge",
    "roborev": "roborev",
    "msgvault": "msgvault",
    "docbank": "docbank",
    "kwt": "kwt",
    "agentsview": "agentsview",
}

# Nix system -> (goos, goarch) as they appear in the release asset names.
PLATFORMS: dict[str, tuple[str, str]] = {
    "x86_64-linux": ("linux", "amd64"),
    "aarch64-linux": ("linux", "arm64"),
    "x86_64-darwin": ("darwin", "amd64"),
    "aarch64-darwin": ("darwin", "arm64"),
}

# kwt publishes checksums.txt; every other repo publishes SHA256SUMS.
CHECKSUM_FILES = ("SHA256SUMS", "checksums.txt")


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def github_token() -> str | None:
    for var in ("GH_TOKEN", "GITHUB_TOKEN"):
        if os.environ.get(var):
            return os.environ[var]
    try:
        out = subprocess.run(
            ["gh", "auth", "token"], capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def http_get(url: str, token: str | None = None) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "kenn-io-flake-updater"})
    if token and "api.github.com" in url:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return resp.read()


def latest_version(repo: str, token: str | None) -> str:
    url = f"https://api.github.com/repos/kenn-io/{repo}/releases/latest"
    data = json.loads(http_get(url, token))
    return data["tag_name"].lstrip("v")


def fetch_checksums(repo: str, version: str, token: str | None) -> dict[str, str]:
    """Return {asset_name: hex_sha256} for a release.

    Two upstream inconsistencies are handled here:
      * the manifest is SHA256SUMS everywhere except kwt (checksums.txt)
      * forge prefixes every entry with "./" while the others use a bare name
    """
    base = f"https://github.com/kenn-io/{repo}/releases/download/v{version}"
    text = None
    for candidate in CHECKSUM_FILES:
        try:
            text = http_get(f"{base}/{candidate}", token).decode()
            break
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise
    if text is None:
        raise RuntimeError(
            f"{repo} v{version}: no {' or '.join(CHECKSUM_FILES)} in the release"
        )

    sums: dict[str, str] = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        digest, name = parts[0], parts[-1]
        if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            continue
        name = name.removeprefix("./").removeprefix("*")  # forge; binary-mode marker
        sums[name] = digest.lower()
    if not sums:
        raise RuntimeError(f"{repo} v{version}: checksum manifest parsed to nothing")
    return sums


def to_sri(hex_digest: str) -> str:
    return "sha256-" + base64.b64encode(binascii.unhexlify(hex_digest)).decode()


def build_entry(repo: str, version: str, token: str | None) -> dict:
    sums = fetch_checksums(repo, version, token)
    platforms: dict[str, dict[str, str]] = {}

    for system, (goos, goarch) in PLATFORMS.items():
        # Exact name, never a glob. kata publishes decoys that a loose pattern
        # would happily match: kata_0.14.3_homebrew_linux_amd64.tar.gz sits
        # right next to kata_0.14.3_linux_amd64.tar.gz. agentsview likewise
        # ships .AppImage/.dmg desktop artifacts in the same release.
        asset = f"{repo}_{version}_{goos}_{goarch}.tar.gz"
        if asset not in sums:
            log(f"    ! {system}: no {asset} published, skipping")
            continue
        platforms[system] = {"asset": asset, "hash": to_sri(sums[asset])}

    if not platforms:
        raise RuntimeError(f"{repo} v{version}: no usable platform assets")

    return {
        "version": version,
        "binary": TOOLS[repo],
        "platforms": dict(sorted(platforms.items())),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tool", nargs="+", choices=sorted(TOOLS), metavar="NAME")
    ap.add_argument(
        "--pin", action="append", default=[], metavar="REPO=VERSION",
        help="hold a tool at an explicit version instead of resolving latest",
    )
    ap.add_argument(
        "--check", action="store_true",
        help="do not write; exit 1 if sources.json differs from upstream",
    )
    args = ap.parse_args()

    pins = dict(p.split("=", 1) for p in args.pin)
    unknown = set(pins) - set(TOOLS)
    if unknown:
        log(f"unknown tool(s) in --pin: {', '.join(sorted(unknown))}")
        return 2

    existing = json.loads(SOURCES.read_text()) if SOURCES.exists() else {}
    targets = args.tool or sorted(TOOLS)
    result = dict(existing)
    token = github_token()
    if not token:
        log("note: no GitHub token found; using unauthenticated API (60 req/hr)")

    failed: list[str] = []
    for repo in targets:
        try:
            version = pins.get(repo) or latest_version(repo, token)
            previous = existing.get(repo, {}).get("version")
            entry = build_entry(repo, version, token)
        except Exception as exc:  # noqa: BLE001 - one bad repo must not stop the rest
            log(f"  {repo}: FAILED - {exc}")
            failed.append(repo)
            continue

        change = "unchanged" if previous == version else f"{previous or 'new'} -> {version}"
        log(f"  {repo:<12} v{version:<10} {len(entry['platforms'])} platforms  ({change})")
        result[repo] = entry

    if failed:
        log(f"\n{len(failed)} tool(s) failed: {', '.join(failed)}")

    result = dict(sorted(result.items()))
    rendered = json.dumps(result, indent=2, sort_keys=False) + "\n"

    if args.check:
        current = SOURCES.read_text() if SOURCES.exists() else ""
        if current != rendered:
            log("\nsources.json is out of date; run ./update.py")
            return 1
        log("\nsources.json is up to date")
        return 1 if failed else 0

    SOURCES.write_text(rendered)
    log(f"\nwrote {SOURCES}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
