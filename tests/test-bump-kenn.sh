#!/usr/bin/env bash
# Guard: the kenn-io toolkit flake spreads ONE tool set across four encodings,
# and nothing else in this repo can see them disagree.
#
#   nix/kenn/update.py     TOOLS         repo -> binary name (writes sources.json)
#   nix/kenn/packages.nix  toolMeta      per-repo description/license/runtimeDeps
#   nix/kenn/sources.json  top-level     the generated pins
#   nix/kenn/flake.nix     systems       must equal update.py's PLATFORMS keys
#
# ADR-0007's source-build set is a SECOND, smaller encoding set with the same
# failure mode, guarded in §6 rather than here: SOURCE_BUILD_TOOLS,
# source-build.nix's exposed attributes, and source-builds.json's keys. It was
# four until flake.nix's hand-written `inherit (sourceBuilds) ...` list became
# a `lib.filterAttrs` on the suffix, which deleted the fourth rather than
# guarding it — the tenth §2 pair below.
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
#
# Third pair, for §6's ADR-0007 source-build shape guard (added 2026-08-20):
#   1. FORM-ONLY — reorder SOURCE_BUILD_TOOLS's keys and add a blank line
#      between two of them in update.py. Green: 75 passed, 0 failed — the shape
#      checks read the dict's keys/values, not its literal layout.
#   2. SEMANTIC, in a form this suite does not write — COMMENT OUT (not delete)
#      ANY ONE entry of SOURCE_BUILD_TOOLS, leaving its derivation in
#      source-build.nix, its pin in source-builds.json and its attribute in
#      flake.nix: the mapping and the three things keyed off it fall out of
#      step, which is this guard's whole subject. Observed red:
#        FAIL: source-build.nix exposes exactly SOURCE_BUILD_TOOLS's attrs
#        FAIL: flake.nix's packages output re-exposes exactly those attrs
#        FAIL: source-builds.json is pinned for exactly SOURCE_BUILD_TOOLS
#        FAIL: SOURCE_BUILD_BUN_NIX is a subset of SOURCE_BUILD_TOOLS
#      Results: 73 passed, 4 failed
#      NAMES NO TOOL, deliberately. This mutation was rewritten three times as
#      tools graduated under it — `"roborev": []`, then `"kata": []`, then
#      `"forge": []`, each a bare "add an ungraduated tool" that stopped being a
#      mutation the moment that tool graduated. With all seven graduated there
#      is no ungraduated tool left to name, so the mutation now runs the
#      coupling backwards instead, and no assertion in the observed output
#      names a tool either. Same reason §4 below DERIVES its ungraduated tool.
#      (This form also puts §4 back to work: with one tool declared
#      ungraduated its refusal test runs instead of skipping, which is why the
#      total here is 77 assertions against the baseline's 75.)
#   (mutation runs 2026-08-20; re-run and semantic half rewritten 2026-08-21)
#
# Fourth pair, for §6's SOURCE_BUILD_BUN_NIX coverage — the generated-file half
# of a source-build pin (ADR-0007's 2026-08-20 amendment, added same day):
#   1. FORM-ONLY — collapse SOURCE_BUILD_BUN_NIX to a single-line dict literal
#      and hoist its trailing comment above the assignment. Green: 75 passed,
#      0 failed — assertion count unchanged.
#   2. SEMANTIC, in a form this suite does not write — COMMENT OUT the
#      `"roborev"` key, leaving nix/kenn/bun/roborev.nix committed and still
#      imported by source-build.nix. This is the ORPHAN direction, and the one
#      with no other symptom at all: the build keeps working, and the file is
#      simply no longer regenerated by any bump, so it rots against the rev
#      sitting next to it in source-builds.json. Observed red:
#        FAIL: every committed generated bun.nix belongs to a
#              SOURCE_BUILD_BUN_NIX tool
#      Results: 74 passed, 1 failed
#   And for degrade_git_lock_entries, whose failure is likewise silent —
#   replace the `"@github:" in entry[0] or "@git+" in entry[0]` detection with
#   the naive `entry[0].rsplit("@", 1)[-1].startswith(("github:", "git+"))`,
#   i.e. the version anyone would write first. Observed red:
#     FAIL: two git/github entries rewritten: got 1, want 2
#     FAIL: the git+ssh entry is rewritten too, despite the @ inside its URL
#   (a git+ssh URL carries its own "@", so splitting at the last one loses it)
#   (mutation runs 2026-08-20)
#
# Fifth pair, for §6's flake.nix exposure check (added 2026-08-21). THE CHECK
# THIS PAIR DESCRIBES IS GONE — flake.nix now derives its `-from-source` attrs
# with `lib.filterAttrs`, so there is no hand-written list to compare against
# and no fourth encoding to guard; see the tenth pair. Kept because its lesson
# outlived it: the block-comment fail-open it found is why both Nix comment
# forms are still stripped in the two parsers that remain.
#   1. FORM-ONLY — rewrite the single multi-line `inherit (sourceBuilds)` as
#      three one-line `inherit` statements. Green: 75
#      passed, 0 failed — assertion count unchanged. The check reads names out
#      of the `packages` region, not the shape of the statement carrying them.
#   2. SEMANTIC, in a form this suite does not write — neutralise one attribute
#      with a Nix BLOCK comment (`/* <attr>-from-source */`) rather than
#      deleting the line or using a `#`. Observed red:
#        FAIL: flake.nix's packages output re-exposes exactly those attrs
#      Results: 74 passed, 1 failed
#      This mutation earned its keep: the first version of the check stripped
#      only `#.*` and passed this GREEN — the attribute genuinely unexposed,
#      every assertion agreeing it was fine. The parser now strips both Nix
#      comment forms. Recorded because it is the clearest instance in this file
#      of §2's rule working as designed: the mutation aimed at the invariant
#      (delete the line) would have passed the broken parser.
#   (mutation runs 2026-08-21, re-run the same day once forge graduated: the
#   baseline moved 77 -> 75 because §4's refusal test has no ungraduated tool
#   left to use and stands down, which is what its SKIP line records.)
#
# Sixth pair, for §6's expand_unresolvable_github_refs coverage — the second
# lockfile rewrite generation does, added with forge (2026-08-21; baseline 76):
#   1. FORM-ONLY — rewrite the leave-it-alone guard from one `or`-ed `if` into a
#      `resolvable` local set in two steps. Green: 76 passed, 0 failed — the
#      test drives the function, so the shape of that condition is not
#      load-bearing.
#   2. SEMANTIC, in a form this suite does not write — return the tag OBJECT's
#      own sha instead of dereferencing it to a commit (the widen-only fix,
#      which is the version anyone would write first: it is what "expand an
#      abbreviated sha" literally means, and it fails at 40 chars exactly as at
#      7 because bun2nix's `?ref=` form resolves through the commits endpoint).
#      The http_get call is commented out rather than deleted. Observed red:
#        FAIL: expand_unresolvable_github_refs rewrites only what nix cannot
#              resolve, to a commit
#      Results: 75 passed, 1 failed
#      Worth recording because this mutation is not a hypothetical: widening was
#      the first implementation, it was committed to a run against the real
#      registry, and the 422 came back identical. The test asserts the COMMIT
#      specifically for that reason.
#   (mutation runs 2026-08-21)
#
# Seventh pair, for §6's source-build.nix parse — the fifth pair's fix applied
# to the OTHER parser in the same block (2026-08-21 review; baseline 78):
#   1. FORM-ONLY — hoist kata's trailing `# see the block comment` comment onto
#      its own line, with a blank line above it. Green: 78 passed, 0 failed.
#   2. SEMANTIC, in a form this suite does not write — comment out, don't
#      delete, once per parser this file reads out of source-build.nix:
#      `# inherit kata-from-source;` in the final attrset, and
#      `/* cp ${./bun/kata.nix} "$out/bun.nix" */`. Observed red, separately:
#        FAIL: source-build.nix exposes exactly SOURCE_BUILD_TOOLS's attrs
#        FAIL: source-build.nix imports every generated bun.nix update.py writes
#      Results: 77 passed, 1 failed each
#      Both passed GREEN before this run: the fifth pair fixed comment
#      stripping in the flake.nix parser and left the source-build.nix one
#      reading raw text, so a commented-out `inherit` — the natural first step
#      of un-graduating a tool, which ADR-0007 keeps reversible — satisfied
#      every assertion while `nix build .#kata-from-source` died on `attribute
#      missing`. The same run showed WHY the `#`-then-block order matters here
#      and not in the flake: two `#` comments in source-build.nix mention
#      `packages/*`, so stripping blocks first paired that `/*` with the
#      mutation's own `*/` and swallowed 150 lines, reporting a second,
#      unrelated failure.
#
# Eighth pair, for §6's bun.lock plumbing — the SECOND generated file, whose
# absence was the live `FailedToOpenSocket` (2026-08-21 review; baseline 78):
#   1. FORM-ONLY — reflow forge's `cp ${./bun/forge.lock} "$out/bun.lock"`
#      across three backslash-continued lines. Green: 78 passed, 0 failed —
#      which is the point of the window rather than a same-line match.
#   2. SEMANTIC, in a form this suite does not write — one mutation per
#      direction: block-comment forge's whole `optionalString` copy block, and
#      (separately) drop an orphan `nix/kenn/bun/msgvault.lock` in for the one
#      bun tool deliberately NOT in SOURCE_BUILD_BUN_NIX. Observed red:
#        FAIL: source-build.nix copies every generated bun.lock over the
#              fetched one
#        FAIL: every committed generated bun.lock belongs to a
#              SOURCE_BUILD_BUN_NIX tool
#      Results: 77 passed, 1 failed each
#      A third, unpaired run points the copy at `"$out/web/lockfile"` instead of
#      removing it, and is red too: the destination is checked, not just the
#      reference, because a lock copied anywhere else is the live failure again
#      with the plumbing apparently present. What a text search cannot reach is
#      a copy block left present but inert (`false && builtins.pathExists ...`);
#      that is not a plausible accident, and it is stated in CLAUDE.md rather
#      than pretended away.
#
# Ninth pair, for the rate-limit branch in github_ref_is_a_commit /
# commit_behind_tag_object (2026-08-21 review; baseline 78):
#   1. FORM-ONLY — hoist `(403, 429)` into a module-level `RATE_LIMIT_CODES`.
#      Green: 78 passed, 0 failed.
#   2. SEMANTIC, in a form this suite does not write — restore the blind
#      `except urllib.error.HTTPError: return False` / `return None`, once per
#      function. Observed red:
#        FAIL: the error should name the rate limit and the stage (resolving a
#              ref): ... while listing kenn-io/kata tags ...
#        FAIL: a rate limit while listing tags should raise, not read as an
#              absent ref
#      Results: 77 passed, 1 failed each
#      The first line is why the assertion names the STAGE and not just the
#      word "rate-limited": both lookups sit on one path, so a 403 swallowed by
#      the commit half still raises a nearly-right error from the tags half a
#      moment later. Asserted generically, that mutation ran GREEN.
#
# Tenth pair, for the replacement of the fifth (2026-08-21; baseline 78). The
# fourth encoding is not guarded better — it is DELETED: flake.nix's `packages`
# output filters `sourceBuilds` on the `-from-source` suffix instead of listing
# seven names, so it exposes whatever source-build.nix exposes at zero tools or
# seven. What §6 still asserts is that it stays derived:
#   1. FORM-ONLY — split the `lib.filterAttrs` call across lines and rename its
#      lambda argument. Green: 78 passed, 0 failed.
#   2. SEMANTIC, in a form this suite does not write — add
#      `inherit (sourceBuilds) kwt-from-source;` back BESIDE the filter, which
#      is the shape the regression actually takes: not a deletion but somebody
#      being explicit about what the flake exposes — redundant, harmless-
#      looking, and the first line of a list that grows back. Observed red:
#        FAIL: flake.nix derives its -from-source attrs instead of listing them
#      Results: 77 passed, 1 failed
#      This assertion is INVERTED relative to the one it replaces (a literal is
#      the failure), so the fail-open direction inverts with it: over-stripping
#      comments now HIDES a hand-written name, which is why `#` is stripped
#      before blocks here too.
#      That the filter genuinely exposes the seven is not asserted here and
#      cannot be — it needs the evaluator. Verified directly instead, by
#      `nix eval .#packages.x86_64-linux --apply builtins.attrNames` before and
#      after the change: the same 17 attributes, no `mkKennToolFromSource`, no
#      `override`/`overrideDerivation`. Ongoing, that is `--source --verify`'s
#      job — it builds through this very output.
#
# Eleventh pair, for `strip_nix_comments()` (#147, 2026-08-21). A refactor that
# grew a guard, so it owes preserved behaviour AND a pair: the property the
# refactor concentrated into one place turned out to be covered by nothing, and
# the measurement that showed it (below) is what a §2 semantic half is for.
# The two call sites had the same expression written twice, in the same order,
# correct at each for a DIFFERENT reason neither site could see — one file's
# contents (a `/*` inside a `#` comment) and the other's inverted assertion
# (over-stripping fails open there, closed here). BASELINE MOVES 78 -> 80 (two
# probe assertions), so every record above reads against a lower baseline; the
# six mutations that read either file were re-run here and each still names the
# same single assertion as its own record: 7's and 10's form-only 80/0, 7's two
# semantic halves, 8's orphan lock and 10's re-listing 79/1.
#   Centralising the expression moved its load-bearing ORDER from two copies (a
#   bad edit breaks one check) to one (a bad edit breaks both), while leaving it
#   observable by nothing: the swap ran GREEN at 78/0. Recorded as
#   measured-not-guarded at first, which was the wrong disposition — closed
#   instead, and the closing took two rounds, which is the ADR-0005 §2 law
#   working exactly as written:
#     - Round one probed the ORDER alone (one value: does `alpha` survive?).
#       It caught the swap and stopped there. Review then aimed a mutation one
#       step over — DELETE block stripping outright — and that ran GREEN at
#       79/0, because neither .nix file currently block-comments a name any
#       assertion looks for. A guard for the order is not a guard for "both
#       forms are stripped"; the author's three mutations were all aimed at
#       the order, and none of them could see that.
#     - Round two made the fixture carry a marker inside each comment form and
#       report TWO values — survivors and leaks. Measured, one fixture now
#       separates four ways of getting this wrong:
#         swap (blocks first)   79/1  FAIL: ... takes `#` out before `/* */`
#         block strip deleted   79/1  FAIL: ... removes both comment forms
#         hash strip deleted    78/2  both of the above
#         `flags=re.S` moved to the inner sub, so `#.*` eats to EOF: ABORTS,
#           rc=1, no Results line — `nix` comes back empty and the block dies
#           on `nix.rindex("\nin\n")` with `ValueError: substring not found`,
#           because this first python block is a plain `$(...)` assignment
#           rather than one of the three `|| rc=$?` blocks below. Worth
#           knowing which way each failure reports: the loud over-strips abort,
#           the quiet ones (a swap, a deleted strip) are what need the probe.
#   The fixture is contents-independent on purpose — a literal, not a read of
#   source-build.nix — so it cannot rot when either file's comments change,
#   which is what a measurement against today's tree had already done.
#
# All three `|| rc=$?` python blocks below report through `$rc`, not `$?`:
# under `set -e` a failing block aborts the suite before its own assert_eq can
# count it, which is still red but reports one line instead of the section. The
# FIRST python block is not one of them — it is a `$(...)` assignment, so it
# aborts the suite outright, which is how the eleventh pair's third mutation
# reports.
#
# What §6 does NOT attempt: whether a COMMITTED source-build hash — or a
# committed generated bun.nix — is still correct against a live rebuild. There
# is no manifest to re-derive either from —
# `nix build` succeeding is the only oracle (same as dev/bump-nix's installer
# checksum) — so do_source_write/do_source_verify/nix_build/
# discover_source_hashes/generate_bun_nix are proven by actually running
# `nix build .#kwt-from-source` / `.#docbank-from-source` /
# `.#roborev-from-source` for real (see the commits that
# introduced them), not by a fixture here. Faking a "nix build succeeded"
# result would be exactly the vacuous-pass shape ADR-0005 warns about. What IS
# hermetic about the generated-file half is its SHAPE agreement, plus the one
# piece of real logic generation adds (degrade_git_lock_entries).
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

    # ADR-0007's --source path: resolve a ref to a commit sha. Canned as a
    # plain {ref: sha} map per repo, independent of the release "latest" map.
    m = re.fullmatch(r"https://api\.github\.com/repos/kenn-io/([^/]+)/commits/([^/]+)", url)
    if m:
        repo, ref = m.groups()
        sha = universe.get("commits", {}).get(repo, {}).get(ref)
        if sha is None:
            raise http404(url)
        return json.dumps({"sha": sha}).encode()

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

# --- 6. source builds (ADR-0007) ---------------------------------------------

echo ""
echo "== source builds (ADR-0007) =="

# ADR-0007 splits the drift guard's job in two, and this section only attempts
# the half that CAN be hermetic: does SOURCE_BUILD_TOOLS (update.py) agree
# with source-build.nix's actual attributes and source-builds.json's actual
# keys? Whether a COMMITTED hash is still correct against a live rebuild is
# the other half, and it has no hermetic form — nix build is the only oracle,
# same as dev/bump-nix's installer checksum — so it is deliberately NOT
# attempted here. do_source_write/do_source_verify/nix_build/
# discover_source_hashes are exercised for real (a real "nix build .#kwt...")
# above in this PR's own history, not by this suite: faking a nix build
# result would be exactly the vacuous-pass shape ADR-0005 warns about.
source_build_encodings="$(
    python3 - "$KENN" <<'PY'
import importlib.util
import re
import sys
from pathlib import Path

kenn = Path(sys.argv[1])

spec = importlib.util.spec_from_file_location("kenn_update", kenn / "update.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def strip_nix_comments(text):
    """Remove both Nix comment forms, `#` before `/* */`.

    Every check in this block is a name search over Nix source, and a comment
    is what makes a name search lie — in whichever direction the assertion
    points (see each call site). So no check reads a raw file; they all read
    this.

    The ORDER is load-bearing, and for a reason no call site can see on its
    own: source-build.nix carries two `#` comments mentioning `packages/*`.
    Strip blocks first and that `/*` pairs with the next real `*/`, swallowing
    everything between — measured, a `/* ... */` mutation at kata's bun.nix
    copy took kata's bun.lock line with it and reported a second, unrelated
    failure. Taking `#` comments out first removes the stray opener with them.

    ONE definition on purpose (#147). This lived at two call sites, in this
    order at both, correct at each for a different reason: one file's contents
    made the order matter and the other file's inverted assertion made
    over-stripping fail open rather than closed. Neither reason was visible
    where the expression sat, and a third reader would have copied whichever
    spelling was nearest.

    One definition WITHIN THIS HEREDOC, which is as far as a `def` reaches: the
    suite's other python blocks cannot see this one, so a Nix parser added to
    any of them would copy the expression again. None of them reads .nix today.
    The cross-block version of this fix is a shared module under tests/lib/,
    which is #119's direction and lands inside #127's complaint that those
    helpers are themselves the subject of no test.

    Not a Nix lexer: a `#` inside a string would be stripped as a comment.
    Neither file has one, and over-stripping is loud at the three checks over
    source-build.nix, which search for a name they expect to FIND. It is SILENT
    at the flake call site, whose assertion is inverted — see the comment there.
    """
    return re.sub(r"/\*.*?\*/", "", re.sub(r"#.*", "", text), flags=re.S)


# Probes the helper above (rationale: its docstring; measurements: the header's
# eleventh entry). A FIXTURE, not a read of either .nix file, so it cannot rot
# when their comments change — the failure mode of the measurement it replaces.
#
# Two values, because "strips comments, `#` first" is two facts and an
# order between them, and a probe for the order alone stayed green when either
# strip was deleted outright: `alpha` must SURVIVE (it does not if the order
# swaps, since the stray `/*` then pairs with the real `*/`) and both markers
# must be GONE (they are not if that form stopped being stripped at all).
# Between them the two values separate every variant measured: the committed
# spelling, the swap, each strip deleted, and `flags=re.S` moved to the inner
# sub — which makes `#.*` eat to EOF, so nothing survives.
probe = "# hash_marker /* opener\nalpha = 1;\n/* block_marker */\nomega = 2;\n"
probe_stripped = strip_nix_comments(probe)
strip_survivors = ",".join(m for m in ("alpha", "omega") if m in probe_stripped) or "<none>"
strip_leaks = ",".join(m for m in ("hash_marker", "block_marker") if m in probe_stripped) or "<none>"


# Stripped before any of the three checks below read this file: the attrset
# scan, the `pin.<field>` reference check and the generated bun.nix/bun.lock
# import checks are all searches for a name they expect to find, so a
# commented-out line satisfies every one of them while the derivation
# genuinely loses the thing named — #86/#97's shape, measured green here for
# `# inherit kata-from-source;` and for a `#`-ed `cp ${./bun/kata.nix}` before
# the stripping existed. Fails CLOSED if it ever over-strips: a lost `pin.` or
# import reference is a red assertion, not a silent pass.
nix = strip_nix_comments((kenn / "source-build.nix").read_text())
# The final `in { ... }` attrset is where every exposed package attribute is
# either bound directly (`kwt-from-source = ...`) or re-exposed via `inherit`
# (`inherit docbank-from-source;`) — a single name-pattern search over just
# that block, not the whole file, so a `-from-source` mention inside a
# comment or the `mkKennToolFromSource` helper itself can't count.
in_idx = nix.rindex("\nin\n")
attrset = nix[in_idx:]
exposed = sorted(set(re.findall(r"\b([A-Za-z][\w-]*-from-source)\b", attrset)))

import json

source_builds = json.loads((kenn / "source-builds.json").read_text())


def out(key, value):
    print(f"{key}={value}")


# Computed beside strip_nix_comments(), reported here because `out` is defined
# after it: every other check in this block depends on that helper.
out("sb_strip_survivors", strip_survivors)
out("sb_strip_leaks", strip_leaks)
out("tools", ",".join(sorted(mod.TOOLS)))
out("sb_tools", ",".join(sorted(mod.SOURCE_BUILD_TOOLS)))
out("sb_exposed", ",".join(exposed))
out("sb_expected_attrs", ",".join(sorted(f"{mod.TOOLS[r]}-from-source" for r in mod.SOURCE_BUILD_TOOLS)))
out("sb_json_keys", ",".join(sorted(source_builds)))

# flake.nix WAS the fourth encoding of the source-build set — a hand-written
# `inherit (sourceBuilds) kwt-from-source docbank-from-source ...` list, whose
# omission had no symptom but `nix build .#<x>-from-source` dying on `does not
# provide attribute` for a tool every other encoding agreed was graduated. It
# is now `lib.filterAttrs` on the `-from-source` suffix, so the flake exposes
# whatever source-build.nix exposes and the encoding is gone rather than
# guarded: `structural` per ADR-0005, with the filter's correctness `tool:`
# (--source --verify runs `nix build <flake_dir>#<attr>` THROUGH this output,
# so a broken filter fails every tool at once and loudly).
#
# What is left to check is that it STAYS derived. Any `-from-source` literal in
# the `packages` region means somebody has started listing them again — the
# edit that reads as harmless ("be explicit about what we expose") and quietly
# restores the encoding. Note the assertion is INVERTED against the one it
# replaces, which flips what stripping is for: a name inside a comment is not a
# hand-list, so stripping prevents a FALSE FAILURE here rather than a fail-open
# — and over-stripping fails OPEN here, the one direction
# strip_nix_comments()'s own docstring cannot warn about, since the other call
# site is the opposite.
#
# Still scoped by paren depth rather than grepped whole-file: a `-from-source`
# name legitimately appearing elsewhere (an `apps` entry, say) is not this
# check's business, and the scan fails loudly on an unbalanced region.
flake_src = (kenn / "flake.nix").read_text()
anchor = "packages = forAllSystems ("
start = flake_src.index(anchor) + len(anchor) - 1
depth = 0
for j in range(start, len(flake_src)):
    if flake_src[j] == "(":
        depth += 1
    elif flake_src[j] == ")":
        depth -= 1
        if depth == 0:
            break
else:
    raise SystemExit("flake.nix: `packages = forAllSystems (` never closes")
packages_region = strip_nix_comments(flake_src[start : j + 1])
listed = sorted(set(re.findall(r"\b([A-Za-z][\w-]*-from-source)\b", packages_region)))
out("sb_flake_listed", ",".join(listed) or "<none>")
# Every extra hash field a tool's SOURCE_BUILD_TOOLS entry names must appear
# referenced somewhere in source-build.nix, or update.py would discover it
# but source-build.nix would never read it back.
missing_refs = []
for repo, extra_fields in mod.SOURCE_BUILD_TOOLS.items():
    for field in extra_fields:
        if f"pin.{field}" not in nix:
            missing_refs.append(f"{repo}:{field}")
out("sb_missing_field_refs", ",".join(missing_refs) or "<none>")

# SOURCE_BUILD_BUN_NIX (ADR-0007's 2026-08-20 amendment): the tools whose
# bun2nix expression this repo GENERATES because upstream ships none. Three
# things can disagree here that nothing else would notice, since generation
# and consumption are in different languages and different files:
#   - a key with no committed file (update.py would regenerate it, but a fresh
#     checkout cannot evaluate at all),
#   - a committed file with no key (nothing regenerates it, so it silently
#     rots against the rev beside it in source-builds.json),
#   - a key whose file source-build.nix never imports (update.py writes it and
#     the derivation goes on building a stub frontend, quietly).
# Derived, not restated: the expected path comes from update.py's own
# BUN_NIX_DIR and the dict's own keys.
out("sb_bun_nix", ",".join(sorted(mod.SOURCE_BUILD_BUN_NIX)))
missing_files = sorted(r for r in mod.SOURCE_BUILD_BUN_NIX if not (mod.BUN_NIX_DIR / f"{r}.nix").is_file())
out("sb_bun_nix_missing_files", ",".join(missing_files) or "<none>")
committed = sorted(p.stem for p in mod.BUN_NIX_DIR.glob("*.nix")) if mod.BUN_NIX_DIR.is_dir() else []
out("sb_bun_nix_committed", ",".join(committed))
rel_dir = mod.BUN_NIX_DIR.name
missing_imports = sorted(r for r in mod.SOURCE_BUILD_BUN_NIX if f"./{rel_dir}/{r}.nix" not in nix)
out("sb_bun_nix_missing_imports", ",".join(missing_imports) or "<none>")

# The SECOND generated file: the widened bun.lock. Its plumbing is the one
# coupling here whose failure was observed LIVE rather than reasoned about —
# a widened ref that reaches bun/<repo>.nix but not the bun.lock the real
# build ships builds all the way to bunNodeModulesInstallPhase and dies there
# on FailedToOpenSocket, because bun2nix's runtime hook re-derives its lookup
# key from the shipped lockfile. Two directions, both silent:
#   - a SOURCE_BUILD_BUN_NIX tool source-build.nix never copies the lock for
#     (generation writes it, the build ignores it — the live failure),
#   - a committed bun/<repo>.lock for a tool no longer in SOURCE_BUILD_BUN_NIX
#     (regenerated by nothing, so it rots against the rev beside it, the same
#     orphan direction as the bun.nix check above).
# The destination is checked too, not just the reference: a copy landing
# anywhere other than bun.lock is the live failure again with the plumbing
# apparently present. Window rather than same-line, so reflowing the copy
# across lines stays form-only.
lock_ref_pats = {r: re.escape(f"./{rel_dir}/{r}.lock") + r"[\s\S]{0,120}?bun\.lock" for r in mod.SOURCE_BUILD_BUN_NIX}
missing_lock_plumbing = sorted(r for r, pat in lock_ref_pats.items() if not re.search(pat, nix))
out("sb_bun_lock_missing_plumbing", ",".join(missing_lock_plumbing) or "<none>")
committed_locks = sorted(p.stem for p in mod.BUN_NIX_DIR.glob("*.lock")) if mod.BUN_NIX_DIR.is_dir() else []
out("sb_bun_lock_orphans", ",".join(sorted(set(committed_locks) - set(mod.SOURCE_BUILD_BUN_NIX))) or "<none>")
PY
)"

sb_get() { printf '%s\n' "$source_build_encodings" | sed -n "s/^$1=//p"; }

assert_eq "strip_nix_comments takes \`#\` out before \`/* */\`" \
    "alpha,omega" "$(sb_get sb_strip_survivors)"
assert_eq "strip_nix_comments removes both comment forms" \
    "<none>" "$(sb_get sb_strip_leaks)"
assert_true "SOURCE_BUILD_TOOLS is a subset of TOOLS" test -z "$(comm -23 <(sb_get sb_tools | tr ',' '\n' | sort) <(sb_get tools | tr ',' '\n' | sort))"
assert_eq "source-build.nix exposes exactly SOURCE_BUILD_TOOLS's attrs" \
    "$(sb_get sb_expected_attrs)" "$(sb_get sb_exposed)"
assert_eq "flake.nix derives its -from-source attrs instead of listing them" \
    "<none>" "$(sb_get sb_flake_listed)"
assert_eq "source-builds.json is pinned for exactly SOURCE_BUILD_TOOLS" \
    "$(sb_get sb_tools)" "$(sb_get sb_json_keys)"
assert_eq "every SOURCE_BUILD_TOOLS extra hash field is read in source-build.nix" \
    "<none>" "$(sb_get sb_missing_field_refs)"

assert_true "SOURCE_BUILD_BUN_NIX is a subset of SOURCE_BUILD_TOOLS" test -z "$(comm -23 <(sb_get sb_bun_nix | tr ',' '\n' | sort) <(sb_get sb_tools | tr ',' '\n' | sort))"
assert_eq "every SOURCE_BUILD_BUN_NIX tool has a committed generated bun.nix" \
    "<none>" "$(sb_get sb_bun_nix_missing_files)"
assert_eq "every committed generated bun.nix belongs to a SOURCE_BUILD_BUN_NIX tool" \
    "$(sb_get sb_bun_nix)" "$(sb_get sb_bun_nix_committed)"
assert_eq "source-build.nix imports every generated bun.nix update.py writes" \
    "<none>" "$(sb_get sb_bun_nix_missing_imports)"
assert_eq "source-build.nix copies every generated bun.lock over the fetched one" \
    "<none>" "$(sb_get sb_bun_lock_missing_plumbing)"
assert_eq "every committed generated bun.lock belongs to a SOURCE_BUILD_BUN_NIX tool" \
    "<none>" "$(sb_get sb_bun_lock_orphans)"

# harvest_hash_mismatches: the one genuinely new parsing logic in this mode,
# tested directly against canned `nix build` stderr rather than trusted.
rc=0
python3 - "$KENN" <<'PY' || rc=$?
import importlib.util
import sys
from pathlib import Path

kenn = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("kenn_update", kenn / "update.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

ok = True


def check(name, got, want):
    global ok
    if got != want:
        ok = False
        print(f"FAIL: {name}: got {got!r}, want {want!r}")


single = """error: hash mismatch in fixed-output derivation '/nix/store/cp8bky3mib89sw8dljpshdb84dw3k8im-source.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-REALHASHHERE=
"""
check("single 'source' mismatch -> srcHash", mod.harvest_hash_mismatches(single), {"srcHash": "sha256-REALHASHHERE="})

multi = """error: hash mismatch in fixed-output derivation '/nix/store/7wzfnk99ksac992airdfclxqc5dl1hq7-docbank-frontend-abc123-npm-deps.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-NPMDEPSHASH=
error: hash mismatch in fixed-output derivation '/nix/store/97idgzbxfjv17fwpkriddbq2rqxzihs7-docbank-abc123-go-modules.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-VENDORHASH=
"""
check(
    "two mismatches in one run -> both fields",
    mod.harvest_hash_mismatches(multi),
    {"npmDepsHash": "sha256-NPMDEPSHASH=", "vendorHash": "sha256-VENDORHASH="},
)

check("no mismatch in stderr -> empty, not an error", mod.harvest_hash_mismatches("build failed for some other reason"), {})

unrecognized = """error: hash mismatch in fixed-output derivation '/nix/store/cp8bky3mib89sw8dljpshdb84dw3k8im-something-else-entirely.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-WHATEVEN=
"""
try:
    mod.harvest_hash_mismatches(unrecognized)
    ok = False
    print("FAIL: an unrecognized derivation name should raise, not be silently dropped")
except RuntimeError as exc:
    if "something-else-entirely" not in str(exc):
        ok = False
        print(f"FAIL: the refusal should name the unrecognized derivation: {exc}")

sys.exit(0 if ok else 1)
PY
assert_eq "harvest_hash_mismatches maps known drv suffixes and refuses to guess" 0 "$rc"

# degrade_git_lock_entries: the other genuinely new parsing logic, and the one
# whose failure is SILENT rather than loud. It exists because bun2nix dispatches
# on a lockfile entry's arity, and bun writes a `github:` dependency with the
# same arity as an npm one — get this wrong in the "leave it alone" direction
# and the generated expression fetches a registry URL that does not exist; get
# it wrong in the "rewrite too much" direction and a real npm package loses its
# integrity hash. Driven against a canned bun.lock rather than trusted, in the
# JSONC-with-trailing-commas form bun actually writes.
rc=0
python3 - "$KENN" <<'PY' || rc=$?
import importlib.util
import sys
from pathlib import Path

kenn = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("kenn_update", kenn / "update.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

ok = True


def check(name, got, want):
    global ok
    if got != want:
        ok = False
        print(f"FAIL: {name}: got {got!r}, want {want!r}")


# Trailing commas everywhere, as bun writes them.
lock = """{
  "lockfileVersion": 1,
  "workspaces": {
    "": { "devDependencies": { "playwright": "1.61.1", }, },
  },
  "packages": {
    "@scope/gh": ["@scope/gh@github:owner/repo#abc1234", { "bin": { "x": "./x.mjs" } }, "owner-repo-abc1234", "sha512-GHHASH=="],
    "@scope/ssh": ["@scope/ssh@git+ssh://git@example.com/o/r#deadbee", { }, "o-r-deadbee", "sha512-SSHHASH=="],
    "vite": ["vite@8.1.3", "", { "bin": { "vite": "bin/vite.js" } }, "sha512-NPMHASH=="],
    "tarball": ["tarball@https://example.com/t.tgz", { }, "sha512-TARHASH=="],
    "ws": ["@scope/ws"],
  },
}
"""

import json

out, rewritten = mod.degrade_git_lock_entries(lock)
check("two git/github entries rewritten", rewritten, 2)
pkgs = json.loads(out)["packages"]

check(
    "the github entry loses its cache key and keeps its integrity",
    pkgs["@scope/gh"],
    ["@scope/gh@github:owner/repo#abc1234", {"bin": {"x": "./x.mjs"}}, "sha512-GHHASH=="],
)
# A git+ssh URL contains its own "@", which is why detection cannot split at
# the last one. This case is the whole reason for that.
check(
    "the git+ssh entry is rewritten too, despite the @ inside its URL",
    pkgs["@scope/ssh"],
    ["@scope/ssh@git+ssh://git@example.com/o/r#deadbee", {}, "sha512-SSHHASH=="],
)
check(
    "an ordinary npm entry is left exactly alone",
    pkgs["vite"],
    ["vite@8.1.3", "", {"bin": {"vite": "bin/vite.js"}}, "sha512-NPMHASH=="],
)
check("an already-arity-3 tarball entry is left alone", pkgs["tarball"], ["tarball@https://example.com/t.tgz", {}, "sha512-TARHASH=="])
check("a workspace entry is left alone", pkgs["ws"], ["@scope/ws"])

# The backstop for the above going stale: if bun2nix ever stops needing the
# rewrite (or starts needing a different one), what lands is a registry URL
# with a git specifier embedded in it. update.py refuses to write that rather
# than committing an expression whose only symptom is a 404 at build time.
bogus = '    url = "https://registry.npmjs.org/@kenn-io/kit-ui/-/kit-ui-github:kenn-io/kit-ui#97be355.tgz";'
check("the bogus-URL backstop matches what bun2nix 2.1.2 emits unrewritten", bool(mod.BOGUS_REGISTRY_URL_RE.search(bogus)), True)
fine = '    url = "https://registry.npmjs.org/glob-parent/-/glob-parent-6.0.2.tgz";'
check("the bogus-URL backstop does not fire on an ordinary registry URL", bool(mod.BOGUS_REGISTRY_URL_RE.search(fine)), False)

sys.exit(0 if ok else 1)
PY
assert_eq "degrade_git_lock_entries rewrites only git/github entries, and the backstop catches a miss" 0 "$rc"

# expand_unresolvable_github_refs: the SECOND lockfile rewrite generation does,
# added with forge. Bun records an ANNOTATED tag's object sha for a
# `github:owner/repo#<tag>` dependency, and bun2nix asks nix for
# `github:owner/repo?ref=<sha>` — a form that resolves through the commits
# endpoint at any length, so a tag object is refused at 40 chars exactly as at
# 7. Two directions to get wrong, hence both are driven here: rewrite too
# little and forge cannot build at all; rewrite too much and roborev's and
# kata's committed bun.nix churn for no behaviour change (their kit-ui ref is an
# abbreviated COMMIT, which resolves fine and must be left alone).
#
# Hermetic because update.py's only network entry point is http_get: it is
# replaced here with a canned GitHub, so the 422-on-a-tag-object shape is
# exercised for real without touching the network.
rc=0
python3 - "$KENN" <<'PY' || rc=$?
import importlib.util
import json
import sys
import urllib.error
from pathlib import Path

kenn = Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("kenn_update", kenn / "update.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

ok = True


def check(name, got, want):
    global ok
    if got != want:
        ok = False
        print(f"FAIL: {name}: got {got!r}, want {want!r}")


TAG_OBJ = "c6685725ecd6a31aaea83cf98908e0c866c5d434"
COMMIT = "410ee88bca267b117c845a36f8249890c5160e3b"
LIGHTWEIGHT = "dddddddddddddddddddddddddddddddddddddddd"
calls = []


def fake_http_get(url, token=None):
    calls.append(url)
    # A commit prefix resolves; a tag-object prefix does not, which is the whole
    # asymmetry this function exists for.
    if "/commits/" in url:
        ref = url.rsplit("/", 1)[-1]
        if ref in ("97be355", COMMIT):
            return json.dumps({"sha": COMMIT}).encode()
        raise urllib.error.HTTPError(url, 422, "Unprocessable Entity", {}, None)
    if "/git/refs/tags" in url:
        return json.dumps(
            [
                {"ref": "refs/tags/v0.1.0", "object": {"sha": LIGHTWEIGHT, "type": "commit"}},
                {"ref": "refs/tags/v0.14.3", "object": {"sha": TAG_OBJ, "type": "tag"}},
            ]
        ).encode()
    if "/git/tags/" in url:
        return json.dumps({"object": {"sha": COMMIT, "type": "commit"}}).encode()
    raise AssertionError(f"unexpected URL: {url}")


mod.http_get = fake_http_get

lock = json.dumps(
    {
        "packages": {
            # Real arity-4 shape bun writes for a github: dependency —
            # [ident, meta, cacheKey, integrity] — cacheKey spelled
            # `<owner>-<repo>-<ref>`, the SAME abbreviated ref ident carries.
            "@kenn-io/kit-ui": [
                "@kenn-io/kit-ui@github:kenn-io/kit-ui#97be355",
                {},
                "kenn-io-kit-ui-97be355",
                "sha512-KIT==",
            ],
            "@kenn-io/kata-ui": ["kata@github:kenn-io/kata#c668572", {}, "kenn-io-kata-c668572", "sha512-KATA=="],
            "vite": ["vite@8.1.3", "", {}, "sha512-NPM=="],
        }
    }
)
out, widened = mod.expand_unresolvable_github_refs(lock, None)
pkgs = json.loads(out)["packages"]

check("only the unresolvable ref is rewritten", widened, 1)
check(
    "an abbreviated COMMIT ref is left byte-identical (no pin churn)",
    pkgs["@kenn-io/kit-ui"][0],
    "@kenn-io/kit-ui@github:kenn-io/kit-ui#97be355",
)
check(
    "its cache key is left byte-identical too",
    pkgs["@kenn-io/kit-ui"][2],
    "kenn-io-kit-ui-97be355",
)
# The commit the tag dereferences to, NOT the widened tag-object sha: widening
# alone is the fix that looks right and fails identically.
check(
    "a tag-object ref becomes the COMMIT the tag names",
    pkgs["@kenn-io/kata-ui"][0],
    f"kata@github:kenn-io/kata#{COMMIT}",
)
# bun's own install reads the CACHE KEY back, not ident, when it cannot
# satisfy a dependency locally (measured against a real build's
# `FailedToOpenSocket kata@github:kenn-io/kata#c668572` — the OLD ref —
# even after ident alone had been widened). Both copies must move together.
check(
    "its cache key widens to the same commit, not just ident",
    pkgs["@kenn-io/kata-ui"][2],
    f"kenn-io-kata-{COMMIT}",
)
check("an ordinary npm entry is untouched", pkgs["vite"][0], "vite@8.1.3")
check("the rewrite dereferences via the tag object, not the refs listing alone", any("/git/tags/" in c for c in calls), True)

# A ref that is neither a commit nor a tag object must REFUSE, not pass through
# to bun2nix as an unresolvable fetch.
try:
    mod.expand_unresolvable_github_refs(
        json.dumps({"packages": {"x": ["x@github:kenn-io/kata#ffffff9", {}, "sha512-X=="]}}), None
    )
    ok = False
    print("FAIL: an unresolvable github ref should raise, not be written")
except RuntimeError as exc:
    if "cannot pin it" not in str(exc):
        ok = False
        print(f"FAIL: the refusal should say what it could not do: {exc}")

# A lightweight tag whose sha the commits endpoint already refused is a
# contradiction, not something to pin anyway.
check(
    "a lightweight-tag match is refused rather than pinned",
    mod.commit_behind_tag_object("kenn-io", "kata", LIGHTWEIGHT[:7], None),
    None,
)


# A rate limit is not an answer. Read as "not a commit" — which is what any
# HTTPError meant here — it sent a perfectly resolvable rev off to be
# dereferenced as a tag, and refused it with a message naming the wrong cause.
# This tool already runs unauthenticated by default, so the 403 is the ordinary
# case, not the exotic one.
def rate_limited(url, token=None):
    raise urllib.error.HTTPError(url, 403, "rate limit exceeded", {}, None)


mod.http_get = rate_limited
# The expected fragment names the STAGE, not just "rate-limited": both lookups
# are on the same path, so a check for the generic word passes while the
# commit-resolution half is still swallowing 403s — the tags listing raises
# a moment later and the message is nearly right. Measured: with only the
# generic fragment asserted, reverting `github_ref_is_a_commit` to a blind
# `except urllib.error.HTTPError: return False` left this GREEN.
for label, fragment, call in (
    (
        "resolving a ref",
        "whether the ref is a commit",
        lambda: mod.expand_unresolvable_github_refs(
            json.dumps({"packages": {"x": ["x@github:kenn-io/kata#97be355", {}, "sha512-X=="]}}), None
        ),
    ),
    (
        "listing tags",
        "while listing",
        lambda: mod.commit_behind_tag_object("kenn-io", "kata", TAG_OBJ[:7], None),
    ),
):
    try:
        call()
        ok = False
        print(f"FAIL: a rate limit while {label} should raise, not read as an absent ref")
    except RuntimeError as exc:
        if "rate-limited" not in str(exc) or fragment not in str(exc):
            ok = False
            print(f"FAIL: the error should name the rate limit and the stage ({label}): {exc}")
mod.http_get = fake_http_get

sys.exit(0 if ok else 1)
PY
assert_eq "expand_unresolvable_github_refs rewrites only what nix cannot resolve, to a commit" 0 "$rc"

# --- argument handling + do_source_check's report contract -------------------
# Reuses the real driver from section 3, extended with a "commits" map so
# commit_sha() (do_source_check's only network call) resolves hermetically.
# do_source_write/do_source_verify are NOT driven here — they call nix_build
# for real, which this driver deliberately does not stub (see the section
# header comment).

cp "$sandbox/good-sources.json" "$sandbox/sources.json"
cat >"$sandbox/source-universe.json" <<'JSON'
{
  "latest": {},
  "releases": {},
  "commits": {
    "kwt": {"main": "1111111111111111111111111111111111111a", "v0.4.0": "2222222222222222222222222222222222222b"}
  }
}
JSON
printf '{"kwt": {"rev": "1111111111111111111111111111111111111a", "srcHash": "x", "vendorHash": "y"}}\n' \
    >"$sandbox/source-builds.json"

# --rev only makes sense under --source.
assert_eq "--rev without --source is refused" 2 "$(drive_rc source-universe.json --rev main)"

# --pin has no meaning once --source selects the other pin space.
out="$(drive source-universe.json --source --pin kwt=1.0.0 --tool kwt --rev main || true)"
assert_eq "--pin under --source is refused" 2 \
    "$(drive_rc source-universe.json --source --pin kwt=1.0.0 --tool kwt --rev main)"
assert_contains "and says why" "no meaning under --source" "$out"

# --verify gates the committed rev; an explicit --rev makes that ill-defined,
# the same shape as --pin-under-release---verify.
out="$(drive source-universe.json --source --verify --rev main || true)"
assert_eq "--rev under --source --verify is refused" 2 \
    "$(drive_rc source-universe.json --source --verify --rev main)"
assert_contains "and says why" "gates the rev already committed" "$out"

# A rev has no meaning shared across repos, unlike a release version.
assert_eq "--source write/check needs exactly one --tool" 2 \
    "$(drive_rc source-universe.json --source --tool kwt docbank --rev main)"

# A tool with no source-build derivation must be refused, not silently
# attempted and left half-written.
#
# The tool name is DERIVED — the first of TOOLS that SOURCE_BUILD_TOOLS does
# not list — rather than written here. It used to be a literal `kata`, which
# silently stopped testing anything the day kata graduated: the assertion
# reddened with a 404 from a repo the canned universe does not describe, i.e.
# it failed for a reason unrelated to what it checks. Deriving it means this
# keeps testing the refusal for as long as ANY tool is ungraduated, and turns
# into a clean skip rather than a false failure when none is.
#
# As of 2026-08-21 that skip is the STANDING state, not a hypothetical: forge
# graduated, so all seven tools have derivations and there is nothing left for
# this to refuse. It stays because un-graduating a tool is explicitly reversible
# (ADR-0007's Consequences), which would put it back to work.
ungraduated="$(comm -23 <(sb_get tools | tr ',' '\n' | sort) <(sb_get sb_tools | tr ',' '\n' | sort) | head -1)"
if [ -n "$ungraduated" ]; then
    out="$(drive source-universe.json --source --tool "$ungraduated" --rev main || true)"
    assert_eq "an ungraduated source-build tool is refused ($ungraduated)" 2 \
        "$(drive_rc source-universe.json --source --tool "$ungraduated" --rev main)"
    assert_contains "and names the known tools" "docbank" "$out"
else
    echo "  SKIP: every tool has graduated, nothing left to refuse"
fi

assert_eq "--source write/check needs --rev" 2 \
    "$(drive_rc source-universe.json --source --tool kwt)"

# do_source_check's report contract: exit 0 whether or not the ref moved,
# non-zero only when it could not be resolved at all (mirrors the release
# --check contract this repo has gotten wrong twice already, #126 / #135).
out="$(drive source-universe.json --source --check --tool kwt --rev main || true)"
assert_eq "--source --check exits 0 when the ref matches the committed rev" 0 \
    "$(drive_rc source-universe.json --source --check --tool kwt --rev main)"
assert_contains "and reports up to date" "up to date" "$out"

out="$(drive source-universe.json --source --check --tool kwt --rev v0.4.0 || true)"
assert_eq "--source --check exits 0 on drift too (drift is news)" 0 \
    "$(drive_rc source-universe.json --source --check --tool kwt --rev v0.4.0)"
assert_contains "and reports the new sha" "22222222" "$out"

out="$(drive source-universe.json --source --check --tool kwt --rev nope || true)"
assert_eq "--source --check fails when the ref cannot be resolved" 1 \
    "$(drive_rc source-universe.json --source --check --tool kwt --rev nope)"

finish
