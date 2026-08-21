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

Source builds (ADR-0007), a SEPARATE pin space (source-builds.json, not
sources.json) for building a tool from a git revision instead of a release:

    ./update.py --source --tool kwt --rev main       # bump to a branch's HEAD
    ./update.py --source --tool docbank --rev abc123 # pin an explicit commit
    ./update.py --source --check --tool kwt --rev main   # report drift only
    ./update.py --source --verify                        # gate all committed
    ./update.py --source --verify --tool kwt             # gate just this one

Only tools in SOURCE_BUILD_TOOLS have a source-build derivation at all — a
strict subset of TOOLS, since a tool graduates into it deliberately (ADR-0007
decision 1), not automatically. --rev applies to exactly one tool: unlike a
release version, a git ref has no meaning shared across repos.

This mode cannot be as hermetically checkable as the release path above: a
release pin's hash comes from a published checksum manifest (one HTTPS fetch);
a revision has no such manifest, so the ONLY way to learn its srcHash/
vendorHash/npmDepsHash is to actually run `nix build` and read the real hash
back out of a deliberate mismatch. `--source --verify` re-runs that same build
against the COMMITTED hashes and fails on anything but a clean build — nix
build is the oracle here, not a fixture, matching how dev/bump-nix's installer
checksum has no hermetic test either (see ADR-0007's Decision 3).

Some source-build tools need more than hashes: see SOURCE_BUILD_BUN_NIX. For
those, `--source` ALSO regenerates a whole file (nix/kenn/bun/<repo>.nix), so
the pin is a rev + hashes + a generated dependency expression.
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
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

SOURCES = Path(__file__).with_name("sources.json")
SOURCE_BUILDS = Path(__file__).with_name("source-builds.json")
BUN_NIX_DIR = Path(__file__).with_name("bun")
FLAKE_DIR = Path(__file__).parent

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

# Tools with a source-build derivation in nix/kenn/source-build.nix
# (ADR-0007). A deliberate SUBSET of TOOLS: a tool graduates into this dict
# only when its derivation actually exists there, never automatically. The
# value is the EXTRA hash fields that tool's derivation needs beyond the two
# every source build needs (srcHash from fetchFromGitHub, vendorHash from
# buildGoModule) — e.g. docbank's npm frontend adds npmDepsHash. Keeping this
# hand-written, like toolMeta's runtimeDeps in packages.nix, is what the
# shape half of the drift guard checks against source-build.nix's actual
# attribute references (tests/test-bump-kenn.sh).
SOURCE_BUILD_TOOLS: dict[str, list[str]] = {
    "kwt": [],
    "docbank": ["npmDepsHash"],
    "agentsview": ["npmDepsHash"],
    # No extra field: msgvault's bun frontend is vendored via bun2nix reading
    # a COMMITTED web/bun.nix inside the fetched tree, not a separately
    # discovered hash — its per-package hashes are already covered by srcHash.
    "msgvault": [],
    "roborev": [],  # generated bun.nix, not a committed one — SOURCE_BUILD_BUN_NIX
    "kata": [],  # same shape as roborev, down to the same kit-ui rev
    "forge": [],  # likewise; note its attr/pname is the BINARY, kenn-forge
}

# Tools whose bun2nix dependency expression this repo has to GENERATE, because
# upstream ships none (ADR-0007's 2026-08-20 amendment). Maps repo -> the
# bun.lock path inside the fetched tree that generation reads; the result is
# written to BUN_NIX_DIR/<repo>.nix and read back by source-build.nix.
#
# This is deliberately a separate mapping from SOURCE_BUILD_TOOLS rather than
# another field on it: a generated FILE is not a discovered hash. It cannot come
# out of discover_source_hashes' build-and-harvest loop at all, because
# source-build.nix imports it — the file has to already exist for the first
# round to even evaluate.
#
# msgvault is deliberately NOT here: its web/bun.nix is committed upstream, so
# there is nothing to generate and its per-package hashes ride along in srcHash.
SOURCE_BUILD_BUN_NIX: dict[str, str] = {
    "roborev": "bun.lock",  # workspace root, not a self-contained subdirectory
    "kata": "bun.lock",  # likewise
    "forge": "bun.lock",  # likewise; workspaces = ["frontend", "packages/*"]
}

FAKE_HASH = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# nixpkgs' own fixed-output derivation naming conventions for the fetchers
# nix/kenn's source builds use — not something this repo invented. A
# derivation named exactly one of HASH_FIELD_BY_DRV_NAME, or ending in
# "-<suffix>" for one of HASH_FIELD_BY_DRV_SUFFIX, maps to the JSON field that
# feeds it.
HASH_FIELD_BY_DRV_NAME: dict[str, str] = {
    "source": "srcHash",  # fetchFromGitHub
}
HASH_FIELD_BY_DRV_SUFFIX: dict[str, str] = {
    "go-modules": "vendorHash",  # buildGoModule
    "npm-deps": "npmDepsHash",  # buildNpmPackage's fetchNpmDeps
}

HASH_MISMATCH_RE = re.compile(
    r"hash mismatch in fixed-output derivation '[^']*?/[0-9a-z]{32}-(?P<name>.+?)\.drv':\s*\n"
    r"\s*specified:\s*(?P<specified>\S+)\s*\n"
    r"\s*got:\s*(?P<got>\S+)"
)


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


# --- source builds (ADR-0007) -------------------------------------------------


def commit_sha(repo: str, ref: str, token: str | None) -> str:
    """Resolve a branch, tag, or (possibly abbreviated) sha to a full commit sha."""
    url = f"https://api.github.com/repos/kenn-io/{repo}/commits/{ref}"
    data = json.loads(http_get(url, token))
    return data["sha"]


def nix_bin() -> str:
    nix = shutil.which("nix")
    if not nix:
        msg = "nix not found on PATH; --source needs a working Nix to discover hashes"
        raise RuntimeError(msg)
    return nix


def prefetch_source(repo: str, rev: str) -> Path:
    """Fetch a revision into the store and return its path.

    `nix flake prefetch github:<owner>/<repo>/<rev>` reports the same NAR hash
    fetchFromGitHub would (verified against nix-prefetch-github), but the hash
    is not what this is for — SOURCE_BUILD_BUN_NIX generation needs the actual
    TREE, before any hash is known, because source-build.nix imports the
    generated file and so cannot even evaluate without it.
    """
    cmd = [
        nix_bin(),
        "--extra-experimental-features",
        "nix-command flakes",
        "flake",
        "prefetch",
        f"github:kenn-io/{repo}/{rev}",
        "--json",
    ]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=1800, check=False)  # noqa: S603
    if out.returncode != 0:
        msg = f"nix flake prefetch of kenn-io/{repo}@{rev} failed:\n{out.stderr[-2000:]}"
        raise RuntimeError(msg)
    return Path(json.loads(out.stdout)["storePath"])


def degrade_git_lock_entries(lock_text: str) -> tuple[str, int]:
    """Rewrite bun.lock's git/github package entries into bun2nix's arity-3 shape.

    bun2nix dispatches purely on a lockfile entry's ARITY: 3 means
    tarball/git/github (it re-derives the hash with `nix flake prefetch`), 4
    means an npm registry package (it builds a registry URL from the
    identifier). Bun writes a `github:` dependency with FOUR elements —
    `[ident, meta, cacheKey, integrity]` — so bun2nix 2.1.2 routes it down the
    npm path and emits a `fetchurl` of a registry URL that does not exist:

        url = "https://registry.npmjs.org/@kenn-io/kit-ui/-/kit-ui-github:kenn-io/kit-ui#97be355.tgz"

    Dropping the cache-key element leaves `[ident, meta, integrity]`, which
    bun2nix's github branch handles correctly (a real fetchFromGitHub, named
    `github:<owner>-<repo>-<rev>` — the name bun's own cache layout wants).
    Only generation reads the patched lockfile; the build uses upstream's own.

    Not a hand-guess at bun's format: msgvault's committed web/bun.nix takes the
    arity-3 path already, because its kit-ui dependency is spelled as a tarball
    URL rather than `github:`. Same dependency, two spellings, and only one of
    them trips this.
    """
    # bun.lock is JSONC: trailing commas, no comments in practice.
    strict = re.sub(r",(\s*[}\]])", r"\1", lock_text)
    data = json.loads(strict)
    rewritten = 0
    for entry in data.get("packages", {}).values():
        if not isinstance(entry, list) or len(entry) != 4:
            continue
        # Match on the identifier rather than splitting at the last "@": a
        # git+ssh URL contains its own "@" and would be misread by a split.
        if "@github:" in entry[0] or "@git+" in entry[0]:
            del entry[2]
            rewritten += 1
    return json.dumps(data, indent=2) + "\n", rewritten


BOGUS_REGISTRY_URL_RE = re.compile(r'url = "https://registry\.npmjs\.org/[^"]*(?:github:|git\+)')

FULL_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
GITHUB_IDENT_RE = re.compile(r"github:(?P<owner>[^/#]+)/(?P<repo>[^#]+)#(?P<ref>.+)$")


def github_ref_is_a_commit(owner: str, repo: str, ref: str, token: str | None) -> bool:
    """Whether nix's github fetcher can resolve `ref` the ordinary way.

    That fetcher asks /repos/<o>/<r>/commits/<ref> for anything that is not a
    full 40-char sha, so this is the same question it will ask.
    """
    try:
        http_get(f"https://api.github.com/repos/{owner}/{repo}/commits/{ref}", token)
    except urllib.error.HTTPError:
        return False
    return True


def commit_behind_tag_object(owner: str, repo: str, ref: str, token: str | None) -> str | None:
    """Resolve an abbreviated ANNOTATED TAG OBJECT sha to the COMMIT it names.

    The commit, not the widened tag-object sha: bun2nix asks nix for
    `github:<o>/<r>?ref=<sha>`, and the `?ref=` form goes through the commits
    endpoint whatever its length, so a tag object 422s at 40 chars exactly as it
    does at 7. The commit resolves, and prefetches to the same NAR hash as both
    the tag object and the tag name (measured, all three).

    Paginated defensively: the repo that needed this has 19 tags, but a listing
    that silently ended early would look exactly like "no such tag".
    """
    for page in range(1, 11):
        url = f"https://api.github.com/repos/{owner}/{repo}/git/refs/tags?per_page=100&page={page}"
        try:
            refs = json.loads(http_get(url, token))
        except urllib.error.HTTPError:
            return None
        if not refs:
            return None
        for entry in refs:
            obj = entry.get("object", {})
            sha = obj.get("sha", "")
            if not sha.startswith(ref):
                continue
            if obj.get("type") != "tag":
                # A lightweight tag points straight at a commit, which the
                # commits endpoint would already have resolved — so reaching
                # here with one means something else is wrong; say so rather
                # than pinning a sha nix has just refused.
                return None
            deref = json.loads(http_get(f"https://api.github.com/repos/{owner}/{repo}/git/tags/{sha}", token))
            return deref.get("object", {}).get("sha") or None
        if len(refs) < 100:
            return None
    return None


def expand_unresolvable_github_refs(lock_text: str, token: str | None = None) -> tuple[str, int]:
    """Rewrite `github:` lockfile refs that nix cannot resolve, to a commit sha.

    Bun records the object a `github:owner/repo#<tag>` dependency resolved to as
    a 7-char abbreviation. For a COMMIT that is fine — nix asks
    /repos/o/r/commits/<ref>, which accepts a prefix, and roborev's and kata's
    `@kenn-io/kit-ui` take exactly that path, so this function deliberately
    leaves them byte-identical rather than churning two committed pins.

    But for an ANNOTATED tag, bun records the sha of the TAG OBJECT, which is
    not a commit, so that endpoint answers 422 "No commit found for SHA" and the
    fetch dies deep inside bun2nix, nowhere near its cause. forge's
    `@kenn-io/kata-ui` (`github:kenn-io/kata#v0.14.3`, recorded as
    `kata@github:kenn-io/kata#c668572`, the tag object `c6685725...`) is the
    first instance, and nothing about it is forge-specific — any dependency on
    an annotated tag will do it.

    Only unresolvable refs are rewritten, and to the COMMIT the tag names, not
    to the widened tag-object sha: bun2nix asks for `github:<o>/<r>?ref=<sha>`,
    and that form resolves through the commits endpoint at any length, so the
    tag object fails at 40 chars too (measured, both forms). Verified equivalent
    rather than assumed: `nix flake prefetch` of the tag object sha, the commit
    it dereferences to, and the tag NAME all report the same NAR hash, so this
    cannot change what gets fetched.

    An arity-4 entry carries the SAME abbreviated ref a second time, as its
    cache-key element (`[ident, meta, cacheKey, integrity]`, cacheKey spelled
    `<owner>-<repo>-<ref>`) — and it is this element, not `ident`, that bun's
    own install reads back when it cannot satisfy the dependency locally: the
    live `FailedToOpenSocket` error names the OLD abbreviated ref even after
    `ident` alone was widened (measured against a real build). Both copies of
    the ref have to move together or bun2nix's generated attribute name
    (derived from `ident`) and bun's own cache lookup (derived from cacheKey)
    disagree, and the dependency falls through to a network fetch the build
    sandbox refuses.
    """
    strict = re.sub(r",(\s*[}\]])", r"\1", lock_text)
    data = json.loads(strict)
    rewritten = 0
    for entry in data.get("packages", {}).values():
        if not isinstance(entry, list) or not entry or not isinstance(entry[0], str):
            continue
        m = GITHUB_IDENT_RE.search(entry[0])
        if not m:
            continue
        owner, repo, ref = m.group("owner"), m.group("repo"), m.group("ref")
        if FULL_SHA_RE.match(ref) or github_ref_is_a_commit(owner, repo, ref, token):
            continue
        full = commit_behind_tag_object(owner, repo, ref, token)
        if not full:
            msg = (
                f"{entry[0]}: github ref {ref!r} is neither a commit nor an abbreviated "
                f"tag object in {owner}/{repo} — cannot pin it, refusing to generate"
            )
            raise RuntimeError(msg)
        entry[0] = entry[0][: m.start("ref")] + full + entry[0][m.end("ref") :]
        if len(entry) >= 3 and entry[2] == f"{owner}-{repo}-{ref}":
            entry[2] = f"{owner}-{repo}-{full}"
        rewritten += 1
    return json.dumps(data, indent=2) + "\n", rewritten


def git_tracks(path: Path) -> bool:
    """Whether git tracks `path`. True when git isn't available to ask.

    Not bookkeeping — a correctness precondition. Nix reads only TRACKED files
    out of a dirty git work tree, so a freshly generated file source-build.nix
    imports is invisible to the very build that has to read it, and the symptom
    is an eval error about a missing path rather than about the real cause.
    """
    git = shutil.which("git")
    if not git:
        return True
    out = subprocess.run(  # noqa: S603 -- fixed argv, no shell, resolved path
        [git, "-C", str(path.parent), "ls-files", "--error-unmatch", "--", path.name],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    return out.returncode == 0


def generate_bun_nix(repo: str, rev: str, flake_dir: Path) -> None:
    """Regenerate BUN_NIX_DIR/<repo>.nix for a tool upstream ships no bun.nix for.

    Runs the flake's OWN pinned bun2nix (`nix run .#bun2nix`), so the generator
    and the `bun2nix.hook` that later consumes the result can never be different
    versions — bun.nix has no schema stability guarantee between them.
    """
    lock_rel = SOURCE_BUILD_BUN_NIX[repo]
    tree = prefetch_source(repo, rev)
    lock_src = tree / lock_rel
    if not lock_src.is_file():
        msg = f"{repo}@{rev[:12]} has no {lock_rel}; SOURCE_BUILD_BUN_NIX is out of date"
        raise RuntimeError(msg)

    build_lock_path = BUN_NIX_DIR / f"{repo}.lock"
    with tempfile.TemporaryDirectory(prefix=f"kenn-bun-{repo}-") as tmp:
        work = Path(tmp) / "tree"
        shutil.copytree(tree, work)
        # Store paths are read-only, and copytree preserves their modes — the
        # root included, so it is in this list too rather than relying on
        # write_text only needing the file bit.
        for path in [work, *work.rglob("*")]:
            path.chmod(path.stat().st_mode | 0o200)
        original_lock = (work / lock_rel).read_text()
        # Widen BEFORE degrading, and on the UNDEGRADED text: a widened ref is
        # not only bun2nix's problem. bun2nix derives its `github:<o>-<r>-<rev>`
        # attribute name from this same ref text at hook-run time too, by
        # re-parsing whatever bun.lock actually ships in the build — and that
        # is upstream's own arity-4 entry, never the degraded copy below, which
        # exists only to route bun2nix's generator down the right branch. If
        # the ref bun2nix generated from and the ref the real build's lockfile
        # carries disagree, the runtime hook misses its own cache and bun
        # falls through to a live fetch, which the build sandbox has no
        # network for (see build_lock_path below).
        widened_lock, widened = expand_unresolvable_github_refs(original_lock, github_token())
        if widened:
            log(f"    widened {widened} abbreviated github ref{'' if widened == 1 else 's'} to a full sha")
        patched, rewritten = degrade_git_lock_entries(widened_lock)
        log(f"    rewrote {rewritten} git/github lockfile entr{'y' if rewritten == 1 else 'ies'} for bun2nix")
        (work / lock_rel).write_text(patched)

        generated = Path(tmp) / "bun.nix"
        cmd = [
            nix_bin(),
            "--extra-experimental-features",
            "nix-command flakes",
            "run",
            f"{flake_dir}#bun2nix",
            "--",
            "--lock-file",
            str(work / lock_rel),
            "--output-file",
            str(generated),
        ]
        log(f"    bun2nix {lock_rel} -> {BUN_NIX_DIR.name}/{repo}.nix")
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=1800, check=False)  # noqa: S603
        if out.returncode != 0:
            msg = f"bun2nix failed for {repo}@{rev[:12]}:\n{out.stderr[-4000:]}"
            raise RuntimeError(msg)
        text = generated.read_text()

    # A git/github dependency that still came out as a registry URL means the
    # arity rewrite above missed it (bun changed its lockfile shape, or bun2nix
    # changed its dispatch). Refuse rather than commit an expression whose only
    # symptom is a 404 at build time.
    bogus = BOGUS_REGISTRY_URL_RE.search(text)
    if bogus:
        msg = f"bun2nix emitted a registry URL for a git dependency, refusing to write it: {bogus.group(0)}"
        raise RuntimeError(msg)

    header = (
        f"# GENERATED by ./update.py --source --tool {repo} --rev <ref>. Do not hand-edit.\n"
        f"#\n"
        f"# kenn-io/{repo} ships no bun.nix of its own (unlike msgvault), so this is\n"
        f"# regenerated from its {lock_rel} on every rev bump and belongs to the\n"
        f"# source-builds.json entry for {repo!r}. See ADR-0007 and nix/kenn/README.md.\n"
    )
    BUN_NIX_DIR.mkdir(exist_ok=True)
    out_path = BUN_NIX_DIR / f"{repo}.nix"
    out_path.write_text(header + text)

    if not git_tracks(out_path):
        rel = out_path.relative_to(FLAKE_DIR.parent.parent)
        msg = (
            f"wrote {rel}, but git does not track it yet — nix reads only tracked "
            f"files from a dirty work tree, so source-build.nix cannot see it. Run\n"
            f"    git add {rel}\n"
            f"and rerun this command. (The file is left in place for exactly that.)"
        )
        raise RuntimeError(msg)

    # The widened lockfile source-build.nix must lay over upstream's own
    # bun.lock before the real build's bunNodeModulesInstallPhase runs — see
    # the comment above the widen/degrade split. Only written when widening
    # actually happened; a stale one from an earlier rev whose ref no longer
    # needs widening is removed rather than left to shadow upstream's lock.
    if widened:
        build_lock_path.write_text(widened_lock)
        if not git_tracks(build_lock_path):
            rel = build_lock_path.relative_to(FLAKE_DIR.parent.parent)
            msg = (
                f"wrote {rel}, but git does not track it yet — nix reads only tracked "
                f"files from a dirty work tree, so source-build.nix cannot see it. Run\n"
                f"    git add {rel}\n"
                f"and rerun this command. (The file is left in place for exactly that.)"
            )
            raise RuntimeError(msg)
    elif build_lock_path.exists():
        build_lock_path.unlink()


def nix_build(flake_dir: Path, attr: str) -> subprocess.CompletedProcess:
    """Run `nix build` for one flake output.

    Never raises on a failed build — hash discovery deliberately reads stderr
    from a failure (a fixed-output hash mismatch names the real hash). Raises
    only if nix itself isn't available to run at all.
    """
    cmd = [
        nix_bin(),
        "--extra-experimental-features",
        "nix-command flakes",
        "build",
        f"{flake_dir}#{attr}",
        "--no-link",
        "--keep-going",
    ]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=1800)  # noqa: S603


def harvest_hash_mismatches(stderr: str) -> dict[str, str]:
    """Map each fixed-output hash mismatch in `nix build` stderr to a JSON field.

    Refuses to guess: a derivation name matching neither HASH_FIELD_BY_DRV_NAME
    nor a known HASH_FIELD_BY_DRV_SUFFIX raises rather than being silently
    dropped, which would otherwise leave that hash's placeholder committed.
    """
    found: dict[str, str] = {}
    unrecognized: list[str] = []
    for m in HASH_MISMATCH_RE.finditer(stderr):
        name = m.group("name")
        field = HASH_FIELD_BY_DRV_NAME.get(name)
        if field is None:
            for suffix, candidate in HASH_FIELD_BY_DRV_SUFFIX.items():
                if name.endswith(f"-{suffix}"):
                    field = candidate
                    break
        if field is None:
            unrecognized.append(name)
            continue
        found[field] = m.group("got")
    if unrecognized:
        msg = f"hash mismatch in unrecognized derivation(s), refusing to guess: {', '.join(unrecognized)}"
        raise RuntimeError(msg)
    return found


def discover_source_hashes(flake_dir: Path, attr: str, all_entries: dict, repo: str, *, max_rounds: int = 8) -> None:
    """Repeatedly build `attr`, harvesting real hashes from each failure.

    `all_entries[repo]` starts holding FAKE_HASH placeholders and is mutated
    in place, round by round, until `attr` builds cleanly. SOURCE_BUILDS is
    rewritten to disk every round: source-build.nix reads it from the real
    file path (mirroring packages.nix/sources.json), so there is no way to
    sandbox this away from the working tree — the caller is responsible for
    restoring the original file if this raises.
    """
    for round_num in range(1, max_rounds + 1):
        SOURCE_BUILDS.write_text(json.dumps(dict(sorted(all_entries.items())), indent=2) + "\n")
        log(f"    round {round_num}: nix build .#{attr}")
        result = nix_build(flake_dir, attr)
        if result.returncode == 0:
            return
        harvested = harvest_hash_mismatches(result.stderr)
        if not harvested:
            msg = f"nix build .#{attr} failed for a reason other than a hash mismatch:\n{result.stderr[-4000:]}"
            raise RuntimeError(msg)
        if all(all_entries[repo].get(k) == v for k, v in harvested.items()):
            msg = f"hash discovery for {attr} is not converging on: {harvested}"
            raise RuntimeError(msg)
        all_entries[repo].update(harvested)
    msg = f"hash discovery for {attr} did not converge in {max_rounds} rounds"
    raise RuntimeError(msg)


def do_source_write(repo: str, rev_ref: str, token: str | None, flake_dir: Path) -> int:
    sha = commit_sha(repo, rev_ref, token)
    original_text = SOURCE_BUILDS.read_text() if SOURCE_BUILDS.exists() else None
    existing = json.loads(original_text) if original_text else {}

    bun_nix = BUN_NIX_DIR / f"{repo}.nix"
    original_bun_nix = bun_nix.read_text() if repo in SOURCE_BUILD_BUN_NIX and bun_nix.exists() else None
    bun_lock = BUN_NIX_DIR / f"{repo}.lock"
    original_bun_lock = bun_lock.read_text() if repo in SOURCE_BUILD_BUN_NIX and bun_lock.exists() else None

    def rollback() -> None:
        # Don't leave a placeholder hash — or a generated file for a rev whose
        # build never came out clean — committed if this fails partway.
        if original_text is not None:
            SOURCE_BUILDS.write_text(original_text)
        elif SOURCE_BUILDS.exists():
            SOURCE_BUILDS.unlink()
        # A previously committed bun.nix/bun.lock is restored; a NEWLY
        # generated one is deliberately left on disk. It has to survive for
        # the `git add` that generate_bun_nix's own failure message asks for
        # (delete it and the rerun regenerates it and fails identically,
        # forever), and an untracked file claims nothing — source-builds.json
        # is what claims a rev graduated, and that has been rolled back above.
        if original_bun_nix is not None:
            bun_nix.write_text(original_bun_nix)
        if original_bun_lock is not None:
            bun_lock.write_text(original_bun_lock)

    working = dict(existing)
    working[repo] = {
        "rev": sha,
        "srcHash": FAKE_HASH,
        "vendorHash": FAKE_HASH,
        **{field: FAKE_HASH for field in SOURCE_BUILD_TOOLS[repo]},
    }
    attr = f"{TOOLS[repo]}-from-source"
    try:
        # Before the first build round, not after: source-build.nix imports the
        # generated expression, so a stale (or absent) one is an EVALUATION
        # error, which discover_source_hashes would report as "failed for a
        # reason other than a hash mismatch".
        if repo in SOURCE_BUILD_BUN_NIX:
            generate_bun_nix(repo, sha, flake_dir)
        discover_source_hashes(flake_dir, attr, working, repo)
    except Exception:
        rollback()
        raise
    log(f"  {repo:<12} {sha[:12]} written to {SOURCE_BUILDS.name} ({attr} builds clean)")
    return 0


def do_source_check(repo: str, rev_ref: str, token: str | None) -> int:
    """Report whether the committed rev is behind `rev_ref`'s current HEAD."""
    existing = json.loads(SOURCE_BUILDS.read_text()) if SOURCE_BUILDS.exists() else {}
    try:
        sha = commit_sha(repo, rev_ref, token)
    except Exception as exc:  # noqa: BLE001 - no report to give is the failure (#126)
        log(f"  {repo:<12} FAILED - {exc}")
        return 1
    current = existing.get(repo, {}).get("rev")
    if current == sha:
        log(f"  {repo:<12} {current[:12]:<12} up to date with {rev_ref!r}")
    else:
        shown = current[:12] if current else "-"
        log(f"  {repo:<12} {shown:<12} -> {sha[:12]} ({rev_ref!r})")
    return 0


def do_source_verify(targets: list[str], flake_dir: Path) -> int:
    """Gate the COMMITTED source-build pins by actually rebuilding them.

    There is no published manifest to re-derive a source-build hash from —
    `nix build` succeeding IS the check. A hash mismatch here means the
    committed hash was tampered with or upstream's tree changed under a fixed
    rev, which should never happen; a build failure for any other reason means
    the pin no longer builds at all.
    """
    existing = json.loads(SOURCE_BUILDS.read_text()) if SOURCE_BUILDS.exists() else {}
    failed: list[str] = []
    for repo in targets:
        if repo not in SOURCE_BUILD_TOOLS:
            log(f"  {repo:<12} FAILED - no source-build derivation (see SOURCE_BUILD_TOOLS)")
            failed.append(repo)
            continue
        entry = existing.get(repo)
        if not entry:
            log(f"  {repo:<12} FAILED - not pinned in {SOURCE_BUILDS.name}")
            failed.append(repo)
            continue
        if repo in SOURCE_BUILD_BUN_NIX and not (BUN_NIX_DIR / f"{repo}.nix").is_file():
            # nix would fail this on its own a second later, but on a path error
            # rather than on the fact — say the fact.
            log(f"  {repo:<12} FAILED - no {BUN_NIX_DIR.name}/{repo}.nix (rerun --source --tool {repo} --rev <ref>)")
            failed.append(repo)
            continue
        attr = f"{TOOLS[repo]}-from-source"
        result = nix_build(flake_dir, attr)
        if result.returncode == 0:
            log(f"  {repo:<12} {entry['rev'][:12]}  OK")
        else:
            log(f"  {repo:<12} {entry['rev'][:12]}  FAILED - nix build .#{attr} did not succeed")
            failed.append(repo)

    for repo in sorted(set(existing) - set(SOURCE_BUILD_TOOLS)):
        log(f"  {repo:<12} FAILED - committed but no longer in SOURCE_BUILD_TOOLS")
        failed.append(repo)

    if failed:
        log(f"\n{len(failed)} tool(s) failed source-build verification: {', '.join(sorted(set(failed)))}")
        return 1
    log("\nall committed source-build pins verified")
    return 0


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
    ap.add_argument(
        "--source",
        action="store_true",
        help="operate on source-build pins (source-builds.json, ADR-0007) instead of release pins",
    )
    ap.add_argument(
        "--rev",
        metavar="REF",
        help="branch, tag, or commit sha to resolve (--source write/check only; exactly one --tool)",
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

    if args.rev is not None and not args.source:
        log("--rev only applies under --source")
        return 2

    token = github_token()
    if not token:
        log("note: no GitHub token found; using unauthenticated API (60 req/hr)")

    if args.source:
        if pins:
            log("--pin has no meaning under --source: a source-build pin is a rev, not a version")
            return 2
        if args.verify:
            if args.rev is not None:
                # Same shape as --pin-under-release---verify above: the
                # committed rev is what --verify checks, so a different one
                # makes "does this match?" ill-defined rather than answerable.
                log("--rev cannot be combined with --source --verify: --verify gates the rev already committed")
                return 2
            targets = args.tool or sorted(SOURCE_BUILD_TOOLS)
            return do_source_verify(targets, FLAKE_DIR)

        # write and check both need exactly one tool: unlike a release
        # version, a git ref has no meaning shared across repos.
        if not args.tool or len(args.tool) != 1:
            log("--source --check and --source (write) need exactly one --tool")
            return 2
        repo = args.tool[0]
        if repo not in SOURCE_BUILD_TOOLS:
            log(f"'{repo}' has no source-build derivation; known: {', '.join(sorted(SOURCE_BUILD_TOOLS)) or '(none)'}")
            return 2
        if not args.rev:
            log("--source --check and --source (write) need --rev REF")
            return 2
        if args.check:
            return do_source_check(repo, args.rev, token)
        try:
            return do_source_write(repo, args.rev, token, FLAKE_DIR)
        except Exception as exc:  # noqa: BLE001 - a clean error, not a traceback
            log(f"FAILED - {exc}")
            return 1

    existing = json.loads(SOURCES.read_text()) if SOURCES.exists() else {}
    targets = args.tool or sorted(TOOLS)

    if args.verify:
        if pins:
            # NOT the sibling behaviour, deliberately. `bump-hadolint --verify
            # 2.14.0` is coherent because the committed state is a bare
            # checksum pair, so "do these shas belong to that release?" has an
            # answer. Here the committed state is a whole record — version,
            # asset names, per-platform hashes — so an explicit version makes
            # the comparison ill-defined: every field would differ by
            # construction. The honest options were reject or silently ignore,
            # and silently ignoring is what this flag exists to stop.
            log("--pin cannot be combined with --verify: --verify gates the versions already committed")
            return 2
        return do_verify(existing, targets, token)
    if args.check:
        return do_check(existing, targets, pins, token)
    return do_write(existing, targets, pins, token)


if __name__ == "__main__":
    sys.exit(main())
