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
    ./update.py --check               # report committed vs latest, never edit
    ./update.py --verify              # gate the committed pins (CI)

--check and --verify follow the same split as dev/bump-hadolint and
dev/bump-nix-base, and are NOT interchangeable:

  --check  is a report. Drift is news, not a failure — it exits 0 whether or
           not a newer release exists, and non-zero only when it has no report
           to give (a version it could not resolve at all).
  --verify is the gate. It re-derives every COMMITTED version's entry from that
           release's published checksum manifest and fails on any disagreement
           — a wrong hash, a vanished asset, an unresolvable release, or an
           entry for a tool this script no longer knows about. An unreachable
           upstream fails rather than passing unchecked.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import shutil
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
    gh = shutil.which("gh")
    if not gh:
        return None
    try:
        out = subprocess.run(  # noqa: S603 -- fixed argv, no shell, resolved path
            [gh, "auth", "token"], capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def http_get(url: str, token: str | None = None) -> bytes:
    if not url.startswith("https://"):
        msg = f"refusing non-https URL: {url}"
        raise ValueError(msg)
    req = urllib.request.Request(  # noqa: S310 -- scheme enforced above
        url, headers={"User-Agent": "kenn-io-flake-updater"}
    )
    if token and "api.github.com" in url:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310
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
        raise RuntimeError(f"{repo} v{version}: no {' or '.join(CHECKSUM_FILES)} in the release")

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


def parse_pins(specs: list[str]) -> dict[str, str]:
    """Parse `--pin REPO=VERSION` arguments.

    Both halves are required: a bare `--pin kata` used to die with a raw
    ValueError traceback, and `--pin kata=` used to fall through to "resolve
    latest", silently doing the opposite of what pinning asks for.
    """
    pins: dict[str, str] = {}
    for spec in specs:
        repo, sep, version = spec.partition("=")
        if not sep or not repo or not version:
            msg = f"--pin expects REPO=VERSION, got: {spec!r}"
            raise ValueError(msg)
        # Tags are `vX.Y.Z` upstream but stored bare; accept either spelling.
        pins[repo] = version.removeprefix("v")
    return pins


def obsolete_entries(existing: dict) -> list[str]:
    """Committed entries for tools this script no longer knows about.

    sources.json, TOOLS here, and toolMeta in packages.nix are three encodings
    of one tool set (see tests/test-bump-kenn.sh). A leftover entry keeps the
    flake shipping a tool nobody maintains a pin story for.
    """
    return sorted(set(existing) - set(TOOLS))


def do_check(existing: dict, targets: list[str], pins: dict[str, str], token: str | None) -> int:
    """Report committed vs latest without editing. Drift is news, not a failure."""
    failed: list[str] = []
    behind = 0
    for repo in targets:
        try:
            latest = pins.get(repo) or latest_version(repo, token)
        except Exception as exc:  # noqa: BLE001 - one bad repo must not stop the rest
            log(f"  {repo:<12} FAILED - {exc}")
            failed.append(repo)
            continue
        current = existing.get(repo, {}).get("version")
        if current == latest:
            log(f"  {repo:<12} v{current:<10} up to date")
        else:
            behind += 1
            log(f"  {repo:<12} v{current or '-':<10} -> v{latest}")

    for repo in obsolete_entries(existing):
        behind += 1
        log(f"  {repo:<12} committed but no longer in TOOLS")

    if failed:
        # No report to give — that is the failure, not the drift (#126).
        log(f"\n{len(failed)} tool(s) could not be resolved: {', '.join(failed)}")
        return 1
    log(f"\n{behind} pin(s) out of date; run ./update.py" if behind else "\nall pins are current")
    return 0


def do_verify(existing: dict, targets: list[str], token: str | None) -> int:
    """Gate the COMMITTED pins against the published checksum manifests."""
    failed: list[str] = []
    for repo in targets:
        entry = existing.get(repo)
        if not entry:
            log(f"  {repo:<12} FAILED - not pinned in {SOURCES.name}")
            failed.append(repo)
            continue
        try:
            fresh = build_entry(repo, entry["version"], token)
        except Exception as exc:  # noqa: BLE001 - one bad repo must not stop the rest
            log(f"  {repo:<12} FAILED - {exc}")
            failed.append(repo)
            continue
        if fresh == entry:
            log(f"  {repo:<12} v{entry['version']:<10} {len(fresh['platforms'])} platforms  OK")
        else:
            log(f"  {repo:<12} v{entry['version']:<10} MISMATCH - committed pins disagree with the release")
            failed.append(repo)

    for repo in obsolete_entries(existing):
        log(f"  {repo:<12} FAILED - committed but no longer in TOOLS")
        failed.append(repo)

    if failed:
        log(f"\n{len(failed)} tool(s) failed verification: {', '.join(sorted(set(failed)))}")
        return 1
    log("\nall committed pins verified against upstream")
    return 0


def do_write(existing: dict, targets: list[str], pins: dict[str, str], token: str | None) -> int:
    # Drop entries for tools TOOLS no longer lists rather than carrying them
    # forward untouched, which left them invisible to every later --check.
    result = {repo: entry for repo, entry in existing.items() if repo in TOOLS}
    for repo in obsolete_entries(existing):
        log(f"  {repo:<12} dropped (no longer in TOOLS)")

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

    SOURCES.write_text(json.dumps(dict(sorted(result.items())), indent=2, sort_keys=False) + "\n")
    log(f"\nwrote {SOURCES}")
    return 1 if failed else 0


def main() -> int:
    # Raw: the docstring's usage block and the --check/--verify contract below
    # it are line-formatted on purpose; the default formatter reflows them into
    # one unreadable paragraph.
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tool", nargs="+", choices=sorted(TOOLS), metavar="NAME")
    ap.add_argument(
        "--pin",
        action="append",
        default=[],
        metavar="REPO=VERSION",
        help="hold a tool at an explicit version instead of resolving latest",
    )
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument(
        "--check",
        action="store_true",
        help="report committed vs latest without editing (exit 0 whether or not they differ)",
    )
    mode.add_argument(
        "--verify",
        action="store_true",
        help="gate the committed pins against the published checksum manifests (non-zero on any mismatch)",
    )
    args = ap.parse_args()

    try:
        pins = parse_pins(args.pin)
    except ValueError as exc:
        log(str(exc))
        return 2
    unknown = set(pins) - set(TOOLS)
    if unknown:
        log(f"unknown tool(s) in --pin: {', '.join(sorted(unknown))}")
        return 2

    existing = json.loads(SOURCES.read_text()) if SOURCES.exists() else {}
    targets = args.tool or sorted(TOOLS)
    token = github_token()
    if not token:
        log("note: no GitHub token found; using unauthenticated API (60 req/hr)")

    if args.verify:
        return do_verify(existing, targets, token)
    if args.check:
        return do_check(existing, targets, pins, token)
    return do_write(existing, targets, pins, token)


if __name__ == "__main__":
    sys.exit(main())
