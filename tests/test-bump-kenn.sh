#!/usr/bin/env bash
# Guard: the kenn-io toolkit flake spreads ONE tool set across four encodings,
# and nothing else in this repo can see them disagree.
#
#   nix/kenn/update.py     TOOLS         repo -> binary name (writes sources.json)
#   nix/kenn/packages.nix  toolMeta      per-repo description/license/runtimeDeps
#   nix/kenn/sources.json  top-level     the generated pins
#   nix/kenn/flake.nix     systems       must equal update.py's PLATFORMS keys
#
# The failure is silent AND out of reach of CI: no workflow evaluates this
# flake and tests/run-all is nix-free, so a repo added to TOOLS without a
# toolMeta entry regenerates sources.json cleanly and then throws
# `attribute missing` in the consumer's `use flake` — i.e. it surfaces first as
# somebody's broken direnv, not as a red build. Same for the `kenn-forge`
# string literal, which appears in packages.nix (the default-join filter) and
# flake.nix (the allowUnfreePredicate) but is OWNED by TOOLS["forge"]: change
# the binary name and the unfree scoping silently stops matching anything,
# which fails the build of that one package with an allowUnfree error.
#
# Derive, don't restate (ADR-0005): every expectation here is read out of the
# source of truth at check time. The Nix side is the risky parse — a flat
# regex over packages.nix is the fail-open shape this repo keeps getting bitten
# by (#86, #96) — so the toolMeta reader is brace-depth-tracked, fails on an
# unbalanced block, and is cross-checked against an INDEPENDENT signal inside
# the same block (one `lib.licenses.` line per tool). An under-parse that a
# name-set comparison would swallow diverges those two counts instead.
#
# Second half: the --check/--verify exit contract, which this repo has now got
# wrong twice (#126, and #135's "stop documenting a --check that cannot fail").
# --check is a REPORT (drift is news — exit 0 whether or not a newer release
# exists, non-zero only when a version could not be resolved at all); --verify
# is the GATE (non-zero on a bad committed pin OR an unreachable upstream).
# Run hermetically: the driver below loads the REAL update.py and replaces its
# one network entry point (http_get) with a canned release universe, so the
# manifest quirks the flake depends on — kwt's checksums.txt naming, forge's
# "./"-prefixed entries, kata's homebrew_* decoys — are exercised for real
# without touching the network.
#
# Verified (ADR-0005 §2), two mutations:
#   1. FORM-ONLY — reflow packages.nix's agentsview toolMeta entry (blank line
#      inserted before it, `license = lib.licenses.mit;` moved above
#      `description`). Green: 42 passed, 0 failed — assertion count unchanged.
#   2. SEMANTIC, in a form this suite does not write — COMMENT OUT (not delete)
#      the `agentsview = { ... };` attribute in packages.nix's toolMeta,
#      leaving it in TOOLS and sources.json. Observed red:
#        FAIL: packages.nix toolMeta covers exactly update.py TOOLS
#        FAIL: toolMeta parse agrees with its own license-line count
#      Results: 40 passed, 2 failed
#      The second failure is the point of the license cross-check: a commented
#      attribute leaves its `lib.licenses.` line inside the block, so the two
#      independently-derived counts diverge. A parser that quietly skipped the
#      entry for any other reason would trip the same wire.
#   (mutation runs 2026-08-17)
#
# Second pair, for §5's .envrc.user.kenn discovery guard (added 2026-08-18):
#   1. FORM-ONLY — rewrite the candidate loop as an array plus `|| continue`
#      instead of a line-continued `for` with an `if`. Green: 52 passed, 0
#      failed. This is the point of driving it functionally: the guard SOURCES
#      the fragment, so the spelling of the candidate list is not load-bearing.
#   2. SEMANTIC, in a form this suite does not write — neutralise the sibling
#      candidate with an inline `` `# ...` `` command substitution rather than
#      deleting the line. Observed red:
#        FAIL: sibling layout resolves to the framework beside the project
#      Results: 51 passed, 1 failed
#   And for §4's mode/option refusal: replace `if pins:` with
#   `if False and pins:` in update.py's --verify branch, restoring the exact
#   silent-ignore it closed. Observed red:
#     FAIL: --pin under --verify is refused, not ignored
#     FAIL: and says why
#   Results: 50 passed, 2 failed
#   (mutation runs 2026-08-18)
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lib/harness.sh"

DEV_BASE="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
KENN="$DEV_BASE/nix/kenn"

for f in update.py packages.nix flake.nix sources.json; do
    [ -f "$KENN/$f" ] || { echo "  FAIL: $KENN/$f not found"; exit 1; }
done

# --- 1. the four encodings of the tool set ----------------------------------

echo "== tool-set encodings =="

# Reads each source of truth and prints one `key=value` line per fact. The
# toolMeta reader tracks brace depth from the `toolMeta = {` anchor rather than
# scanning for a name pattern anywhere in the file, and reports its own
# license-line count so an under-parse cannot pass as agreement.
encodings="$(
    python3 - "$KENN" <<'PY'
import importlib.util
import json
import re
import sys
from pathlib import Path

kenn = Path(sys.argv[1])

spec = importlib.util.spec_from_file_location("kenn_update", kenn / "update.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

nix = (kenn / "packages.nix").read_text()
anchor = nix.index("toolMeta = {")
depth, names, licenses, i = 0, [], 0, anchor + len("toolMeta = ")
body_start = i
while i < len(nix):
    if nix[i] == "{":
        depth += 1
    elif nix[i] == "}":
        depth -= 1
        if depth == 0:
            break
    i += 1
else:
    raise SystemExit("packages.nix: toolMeta block never closes")
body = nix[body_start : i + 1]
for line in body.splitlines():
    m = re.fullmatch(r"\s{4}([A-Za-z_][\w-]*) = \{", line)
    if m:
        names.append(m.group(1))
    licenses += line.count("lib.licenses.")

flake = (kenn / "flake.nix").read_text()
sysm = re.search(r"systems = \[(.*?)\];", flake, re.S)
systems = re.findall(r'"([^"]+)"', sysm.group(1)) if sysm else []

sources = json.loads((kenn / "sources.json").read_text())


def out(key, value):
    print(f"{key}={value}")


out("tools", ",".join(sorted(mod.TOOLS)))
out("binaries", ",".join(f"{k}:{v}" for k, v in sorted(mod.TOOLS.items())))
out("platforms", ",".join(sorted(mod.PLATFORMS)))
out("toolmeta", ",".join(sorted(names)))
out("toolmeta_count", len(names))
out("license_count", licenses)
out("sources", ",".join(sorted(sources)))
out("sources_binaries", ",".join(f"{k}:{v['binary']}" for k, v in sorted(sources.items())))
out("sources_platforms", ",".join(sorted({p for e in sources.values() for p in e["platforms"]})))
out("flake_systems", ",".join(sorted(systems)))
out("forge_binary", mod.TOOLS.get("forge", "<missing>"))
out("nix_unfree_literals", ",".join(sorted(set(re.findall(r'n != "([^"]+)"', nix)))) or "<no filter literal>")
out("flake_unfree_literals", ",".join(sorted(set(re.findall(r'getName pkg == "([^"]+)"', flake)))))
out("flake_default_app", (re.search(r'default = mkApp "([^"]+)"', flake) or [None, ""])[1])
PY
)"

get() { printf '%s\n' "$encodings" | sed -n "s/^$1=//p"; }

tools="$(get tools)"
assert_nonempty "update.py TOOLS parsed" "$tools"
assert_nonempty "packages.nix toolMeta parsed" "$(get toolmeta)"
assert_nonempty "flake.nix systems parsed" "$(get flake_systems)"

assert_eq "packages.nix toolMeta covers exactly update.py TOOLS" "$tools" "$(get toolmeta)"
assert_eq "toolMeta parse agrees with its own license-line count" \
    "$(get toolmeta_count)" "$(get license_count)"
assert_eq "sources.json is pinned for exactly update.py TOOLS" "$tools" "$(get sources)"
assert_eq "sources.json binary names come from TOOLS" \
    "$(get binaries)" "$(get sources_binaries)"

assert_eq "flake.nix systems == update.py PLATFORMS" \
    "$(get platforms)" "$(get flake_systems)"
assert_eq "every pinned platform is a system the flake offers" \
    "$(get platforms)" "$(get sources_platforms)"

# The unfree scoping is keyed on a binary NAME, not a repo name.
assert_eq "packages.nix's default-join filter excludes TOOLS['forge']" \
    "$(get forge_binary)" "$(get nix_unfree_literals)"
assert_eq "flake.nix's allowUnfreePredicate names TOOLS['forge']" \
    "$(get forge_binary)" "$(get flake_unfree_literals)"
assert_contains "flake.nix's default app is a known binary" \
    ":$(get flake_default_app)," "$(get binaries),"

# --- 2. the tool is reachable the way its own docs say -----------------------

echo ""
echo "== bump-kenn wiring =="

bump="$DEV_BASE/dev/bump-kenn"
table="$DEV_BASE/lib/command-table.tsv"

# dispatch-arm <-> table-row equality is tests/test-completions-sync.sh's job.
# What it cannot see is that bump-kenn's own usage header documents an
# invocation that resolves: it shipped saying `devcontainer bump-kenn` while
# being in neither the table nor the dispatch, so the documented command
# printed the usage screen and did nothing.
documented="$(sed -n 's/^# *devcontainer \([a-z-]*\).*/\1/p' "$bump" | sort -u)"
assert_nonempty "bump-kenn documents a devcontainer invocation" "$documented"
while read -r cmd; do
    [ -n "$cmd" ] || continue
    assert_true "documented '$cmd' is a command-table row" \
        grep -q "^$cmd	" "$table"
done <<<"$documented"

assert_true "dev/bump-kenn is executable" test -x "$bump"

# --- 3. the --check / --verify exit contract --------------------------------

echo ""
echo "== --check / --verify exit contract =="

sandbox="$(mktemp -d)"
_cleanup_dirs+=("$sandbox")
cp "$KENN/update.py" "$sandbox/update.py"

cat >"$sandbox/drive.py" <<'PY'
#!/usr/bin/env python3
"""Run the REAL update.py against a canned upstream. No network, no gh.

argv: drive.py <universe.json> [update.py args...]
"""

import importlib.util
import json
import re
import sys
import urllib.error
from pathlib import Path

here = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("kenn_update", here / "update.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

universe = json.loads(Path(sys.argv[1]).read_text())


def http404(url):
    return urllib.error.HTTPError(url, 404, "Not Found", {}, None)


def fake_http_get(url, token=None):
    if not url.startswith("https://"):
        raise AssertionError(f"non-https URL reached the fetcher: {url}")
    for repo in universe.get("unreachable", []):
        if f"/{repo}/" in url:
            raise urllib.error.URLError("stub: upstream unreachable")

    m = re.fullmatch(r"https://api\.github\.com/repos/kenn-io/([^/]+)/releases/latest", url)
    if m:
        version = universe["latest"].get(m.group(1))
        if version is None:
            raise http404(url)
        return json.dumps({"tag_name": f"v{version}"}).encode()

    m = re.fullmatch(r"https://github\.com/kenn-io/([^/]+)/releases/download/v([^/]+)/(.+)", url)
    if m:
        repo, version, filename = m.groups()
        release = universe["releases"].get(repo, {}).get(version)
        if release is None or filename != release.get("manifest", "SHA256SUMS"):
            raise http404(url)
        prefix = release.get("prefix", "")
        return "".join(f"{d}  {prefix}{n}\n" for n, d in release["assets"].items()).encode()

    raise http404(url)


mod.http_get = fake_http_get
mod.github_token = lambda: "stub-token"  # never shell out to gh
sys.argv = ["update.py", *sys.argv[2:]]
sys.exit(mod.main())
PY

# Canned upstream. Deliberately reproduces the three upstream quirks the flake
# depends on, so the write path is exercised against them rather than trusted:
# kwt's checksums.txt filename, forge's "./"-prefixed entries, and kata's
# homebrew_* decoy assets sitting beside the real ones.
python3 - "$sandbox" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

sandbox = Path(sys.argv[1])
PLATFORMS = [("linux", "amd64"), ("linux", "arm64"), ("darwin", "amd64"), ("darwin", "arm64")]


def digest(name):
    return hashlib.sha256(name.encode()).hexdigest()


def release(repo, version, *, manifest="SHA256SUMS", prefix="", decoys=False):
    assets = {}
    for goos, goarch in PLATFORMS:
        real = f"{repo}_{version}_{goos}_{goarch}.tar.gz"
        assets[real] = digest(real)
        if decoys:
            decoy = f"{repo}_{version}_homebrew_{goos}_{goarch}.tar.gz"
            assets[decoy] = digest("DECOY-" + decoy)
    return {"assets": assets, "manifest": manifest, "prefix": prefix}


universe = {
    "latest": {"kata": "1.0.0", "forge": "2.0.0", "kwt": "3.0.0"},
    "releases": {
        "kata": {"1.0.0": release("kata", "1.0.0", decoys=True)},
        "forge": {"2.0.0": release("forge", "2.0.0", prefix="./")},
        "kwt": {"3.0.0": release("kwt", "3.0.0", manifest="checksums.txt")},
    },
}
(sandbox / "universe.json").write_text(json.dumps(universe))

# What update.py must produce for kata's real linux/amd64 asset, computed
# independently of to_sri().
import base64

asset = "kata_1.0.0_linux_amd64.tar.gz"
expected = "sha256-" + base64.b64encode(bytes.fromhex(digest(asset))).decode()
(sandbox / "expected-kata-hash").write_text(expected)
PY

expected_hash="$(cat "$sandbox/expected-kata-hash")"

drive() {
    local universe="$1"
    shift
    ( cd "$sandbox" && python3 drive.py "$universe" "$@" ) 2>&1
}
drive_rc() {
    local out
    out="$(drive "$@")" && echo 0 || echo $?
}

printf '{}\n' >"$sandbox/sources.json"
out="$(drive universe.json --tool kata forge kwt || true)"
assert_contains "write mode reports the new pins" "kata" "$out"
pinned="$(python3 -c 'import json,sys;print(",".join(sorted(json.load(open(sys.argv[1])))))' "$sandbox/sources.json")"
assert_eq "write mode pins every requested tool" "forge,kata,kwt" "$pinned"

kata_hash="$(python3 -c \
    'import json,sys;print(json.load(open(sys.argv[1]))["kata"]["platforms"]["x86_64-linux"]["hash"])' \
    "$sandbox/sources.json")"
assert_eq "hash is derived from the manifest digest" "$expected_hash" "$kata_hash"
kata_asset="$(python3 -c \
    'import json,sys;print(json.load(open(sys.argv[1]))["kata"]["platforms"]["x86_64-linux"]["asset"])' \
    "$sandbox/sources.json")"
assert_eq "the homebrew_* decoy is not what got pinned" "kata_1.0.0_linux_amd64.tar.gz" "$kata_asset"
assert_true "forge's ./-prefixed manifest still yields 4 platforms" \
    test "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["forge"]["platforms"]))' \
        "$sandbox/sources.json")" = 4
assert_true "kwt's checksums.txt fallback still yields 4 platforms" \
    test "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["kwt"]["platforms"]))' \
        "$sandbox/sources.json")" = 4

cp "$sandbox/sources.json" "$sandbox/good-sources.json"

assert_eq "--verify passes on freshly written pins" 0 \
    "$(drive_rc universe.json --verify --tool kata forge kwt)"
assert_eq "--check is quiet when nothing is behind" 0 \
    "$(drive_rc universe.json --check --tool kata forge kwt)"

# A tampered hash is exactly what --verify exists to catch.
python3 - "$sandbox/sources.json" <<'PY'
import json
import sys

p = sys.argv[1]
data = json.load(open(p))
data["kata"]["platforms"]["x86_64-linux"]["hash"] = "sha256-" + "A" * 43 + "="
json.dump(data, open(p, "w"), indent=2)
PY
out="$(drive universe.json --verify --tool kata || true)"
assert_eq "--verify fails on a tampered hash" 1 "$(drive_rc universe.json --verify --tool kata)"
assert_contains "--verify names the mismatch" "MISMATCH" "$out"
cp "$sandbox/good-sources.json" "$sandbox/sources.json"

# Drift is news, not a failure.
python3 - "$sandbox/universe.json" <<'PY'
import json
import sys

p = sys.argv[1]
u = json.load(open(p))
u["latest"]["kata"] = "9.9.9"
json.dump(u, open(p, "w"))
PY
out="$(drive universe.json --check --tool kata || true)"
assert_eq "--check exits 0 on drift (drift is news)" 0 "$(drive_rc universe.json --check --tool kata)"
assert_contains "--check reports the newer version" "9.9.9" "$out"
assert_eq "--verify ignores latest-ness and passes on a stale-but-correct pin" 0 \
    "$(drive_rc universe.json --verify --tool kata)"
assert_true "--check did not write" cmp -s "$sandbox/good-sources.json" "$sandbox/sources.json"

# An unreachable upstream must fail BOTH: --check has no report to give (#126),
# and --verify must not pass a pin it never checked.
python3 - "$sandbox/universe.json" <<'PY'
import json
import sys

p = sys.argv[1]
u = json.load(open(p))
u["latest"]["kata"] = "1.0.0"
u["unreachable"] = ["kata"]
json.dump(u, open(p, "w"))
PY
assert_eq "--check fails when a version cannot be resolved" 1 \
    "$(drive_rc universe.json --check --tool kata)"
assert_eq "--verify fails on an unreachable upstream" 1 \
    "$(drive_rc universe.json --verify --tool kata)"
python3 - "$sandbox/universe.json" <<'PY'
import json
import sys

p = sys.argv[1]
u = json.load(open(p))
u.pop("unreachable", None)
json.dump(u, open(p, "w"))
PY

# An entry for a tool update.py no longer knows about: reported by --check,
# failed by --verify, and dropped rather than carried forward by a write.
python3 - "$sandbox/sources.json" <<'PY'
import json
import sys

p = sys.argv[1]
data = json.load(open(p))
data["notatool"] = {"version": "0.0.1", "binary": "notatool", "platforms": {}}
json.dump(data, open(p, "w"), indent=2)
PY
out="$(drive universe.json --check --tool kata || true)"
assert_eq "--check still exits 0 with an obsolete entry" 0 "$(drive_rc universe.json --check --tool kata)"
assert_contains "--check names the obsolete entry" "notatool" "$out"
assert_eq "--verify fails on an obsolete entry" 1 "$(drive_rc universe.json --verify --tool kata)"
drive universe.json --tool kata >/dev/null 2>&1 || true
assert_false "a write drops the obsolete entry" \
    grep -q notatool "$sandbox/sources.json"

# --- 4. argument handling ----------------------------------------------------

echo ""
echo "== argument handling =="

cp "$sandbox/good-sources.json" "$sandbox/sources.json"

out="$(drive universe.json --pin kata --check || true)"
assert_eq "a --pin with no '=' exits 2" 2 "$(drive_rc universe.json --pin kata --check)"
assert_not_contains "and does not traceback" "Traceback" "$out"
assert_contains "and says what it wanted" "REPO=VERSION" "$out"

assert_eq "an empty --pin version exits 2" 2 "$(drive_rc universe.json --pin kata= --check)"
assert_eq "an unknown --pin tool exits 2" 2 "$(drive_rc universe.json --pin nope=1.0.0 --check)"
assert_eq "--check and --verify together are rejected" 2 \
    "$(drive_rc universe.json --check --verify)"

# An option a mode does not consume must be refused, not dropped on the floor.
# --verify gates the versions already committed, so a --pin has no target; it
# used to be accepted and then ignored, reporting the COMMITTED version as OK
# and exiting 0 — a green answer to a question nobody asked.
out="$(drive universe.json --verify --pin kata=0.5.0 || true)"
assert_eq "--pin under --verify is refused, not ignored" 2 \
    "$(drive_rc universe.json --verify --pin kata=0.5.0)"
assert_contains "and says why" "--pin cannot be combined with --verify" "$out"
# --check DOES consume it (report committed vs an explicitly named version),
# which is the sibling behaviour and must not be collateral damage.
out="$(drive universe.json --check --tool kata --pin kata=0.5.0 || true)"
assert_eq "--pin under --check is still honoured" 0 \
    "$(drive_rc universe.json --check --tool kata --pin kata=0.5.0)"
assert_contains "and reports against the pinned version, not latest" "0.5.0" "$out"

# `v1.0.0` and `1.0.0` name the same release; only the bare form is stored.
drive universe.json --pin kata=v1.0.0 --tool kata >/dev/null 2>&1 || true
assert_eq "--pin accepts a leading 'v' and stores the bare version" "1.0.0" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["kata"]["version"])' \
        "$sandbox/sources.json")"

# --- 5. .envrc.user.kenn's checkout discovery --------------------------------

echo ""
echo "== .envrc.user.kenn checkout discovery =="

# .envrcs/ is the least-guarded tier in the repo (no shared library, and until
# this block no suite exercised a fragment at all), which is how the sibling
# layout got missed: .envrc.user.template puts the framework's dev/ on PATH via
# `PATH_add $direnv_root/../devcontainer/dev`, while this fragment only tried
# $direnv_root and one absolute path — so a sibling checkout got the scripts
# and was then told the flake did not exist.
#
# Driven functionally rather than by grepping for the path expression: the
# fragment is SOURCED against a stubbed direnv (use flake / log_error / PATH_add
# are direnv stdlib, absent under bash), so what is asserted is the resolution
# these two files must agree on, not the spelling of either.
env_kenn="$DEV_BASE/.envrcs/.envrc.user.kenn"
template="$DEV_BASE/.envrcs/.envrc.user.template"

# Derive the layout the template assumes rather than restating it here.
template_sibling="$(sed -n 's|.*PATH_add \$direnv_root/\.\./\([A-Za-z0-9_-]*\)/dev.*|\1|p' "$template")"
assert_eq "the template still assumes a sibling framework checkout" "devcontainer" "$template_sibling"

# resolve <direnv_root> <fake-home> -> the DEVCONTAINER_HOME the fragment picks
resolve() {
    local root="$1" home="$2"
    env -i HOME="$home" PATH="$PATH" bash -c '
        direnv_root="$1"
        use() { :; }
        log_error() { :; }
        . "$2"
        printf "%s\n" "$DEVCONTAINER_HOME"
    ' _ "$root" "$env_kenn"
}

layouts="$(mktemp -d)"
_cleanup_dirs+=("$layouts")

# (a) sourced inside the framework repo itself
mkdir -p "$layouts/self/nix/kenn"
assert_eq "in-repo layout resolves to the checkout itself" "$layouts/self" \
    "$(resolve "$layouts/self" "$layouts/nohome")"

# (b) the sibling layout the template assumes: project beside the framework
mkdir -p "$layouts/work/$template_sibling/nix/kenn" "$layouts/work/proj"
assert_eq "sibling layout resolves to the framework beside the project" \
    "$layouts/work/$template_sibling" \
    "$(resolve "$layouts/work/proj" "$layouts/nohome")"

# (c) neither: the conventional absolute path, which the flake really is under
mkdir -p "$layouts/home/repos/github/devcontainer/nix/kenn" "$layouts/elsewhere"
assert_eq "otherwise the conventional \$HOME path wins" \
    "$layouts/home/repos/github/devcontainer" \
    "$(resolve "$layouts/elsewhere" "$layouts/home")"

# (d) nothing anywhere: still names an actionable path for the error message
assert_eq "an unresolvable checkout still names a path" \
    "$layouts/bare/repos/github/devcontainer" \
    "$(resolve "$layouts/elsewhere" "$layouts/bare")"

# An explicit export always wins — it is the documented override.
assert_eq "an explicit DEVCONTAINER_HOME is never second-guessed" "/opt/dc" \
    "$(DEVCONTAINER_HOME=/opt/dc env -i HOME="$layouts/home" PATH="$PATH" DEVCONTAINER_HOME=/opt/dc bash -c '
        direnv_root="$1"; use() { :; }; log_error() { :; }; . "$2"
        printf "%s\n" "$DEVCONTAINER_HOME"' _ "$layouts/self" "$env_kenn")"

finish
