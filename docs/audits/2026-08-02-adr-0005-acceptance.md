# ADR-0005 acceptance baseline — structural audit (cross-section pass)

Backfilled 2026-08-02 per ADR-0006, from the report posted as a comment on
issue #89. Verbatim below the rule; nothing re-derived. This report PREDATES
ADR-0006 (and the disposal-draft/provenance requirements added with it), so it
carries no per-shape disposal drafts — those dispositions are tracked as the
checklist in #89's body, and §4's three findings are now issues #95, #96, #97.

It is the richer of the two 2026-08-02 audits: a full per-invariant
classification in ADR-0005's vocabulary (§1), the rule-asserting comment sweep
(§2), self-failure coverage across the suites (§3), and three mutation
spot-checks that proved live fail-open guards (§4). The sibling report
`2026-08-02-repo-wide.md` is the history-inclusive pass over the whole repo.
A later audit should rerun §Method's M1–M7 and compare.

ADR-0006's amendment of 2026-08-04 makes committing a report optional; this
one is kept as historical record, so M1–M7 remain rerunnable from here even
though no future audit is obliged to leave a successor.

---

*Everything below is the report as posted on #89 — "this issue" and "posted
here" refer to that comment thread, not to this file.*

## ADR-0005 acceptance baseline

This is the structural-audit baseline that PR #88 (ADR-0005, accepted) cites, posted here because this issue tracks the sweep it re-measures. Provenance:

- **Audited tree:** `b7817a1` (PR #88's branch before the acceptance commit; all numbers are unaffected by the acceptance commit itself, which touches only the CLAUDE.md header/Conventions and the ADR).
- **Produced by:** a structural-auditor run using the agent definition from #90's branch at `1254335` (run via a general agent since #90 is unmerged — if #90 changes materially, this baseline still stands on its recorded commands).
- **Headline corrections to the ADR's hand counts:** the "58 rule-asserting comments" becomes a recorded, re-runnable **119-line** grep (instrument in §Method), of which **27 lines / 15 distinct cross-file facts / 6 unguarded** — two of those six in no CLAUDE.md invariant at all, including this issue's 4-copy `NIX_USER`↔`EXTRA_PATH` coupling. "2 of 25" is **verified** under the strict criterion (6 of 25 counting the bump tools' refusal fixtures).
- **§4 warrants attention beyond this sweep:** all three vacuous-pass spot checks stayed green through the full `tests/run-all` — a one-directional anchor check (invariant #8), a fail-open dispatch parser (#33 residual, the #86 shape recurring), and a textual COPY-coverage match a comment satisfies (#1). These are live fail-open guards and likely deserve their own issues/fixes.

---

# ADR-0005 acceptance baseline — structural audit (cross-section pass)

Audited tree: `/workspaces/src` at `b7817a1` (branch `docs/adr-0005-guard-taxonomy`).
Scope per invocation: cross-section only; the history pass was skipped except for one
commit-date check used in §1's reconciliation. See "Not examined" at the end.

Concurrency note: while this audit ran, another session modified the working
tree's `CLAUDE.md` (Invariants section HEADER adopting the ADR-0005 vocabulary,
plus one new Conventions bullet) and flipped `docs/adr/0005-guard-taxonomy.md` to
Accepted. This audit made no repo edits (scratchpad only; verified via
`git diff`). All 36 invariant bullets are byte-unchanged by that concurrent diff
(`git diff CLAUDE.md | grep -E '^[+-]- '` shows only the added Conventions
bullet), and the §4 spot-check clones were of committed HEAD `b7817a1`, so every
number below is unaffected.

All invariants are referenced by handle and bullet number (ordinal position in
CLAUDE.md `## Invariants`, lines 73–249); they are not restated here.

---

## 1. Invariant classification (ADR-0005 vocabulary)

Mechanical counts on the current tree (commands in §Method, M1–M4):

- 36 invariant bullets total.
- 29 cite at least one `tests/test-*.sh` path.
- 5 end in `(—)`.
- 2 cite neither (#6 Dockerfile-mirror, #10 base-vs-seed exclusivity) — they gesture
  at guards or enforcement in prose.

Reconciliation with ADR-0005's numbers: the ADR's hand count (21 test / 5 `—` / 10
prose) and mechanical count (26 / 5 / 5) were taken before `1a2d031` (#87) landed
`tests/test-nix-base-trigger-paths.sh` and rewrote/added the two trigger-paths
bullets (#12, #13), and the hand count additionally filed test-citing bullets whose
citation is embedded in long prose (#8, #9, #11, #15, #16, #25) under "prose". The
current-tree mechanical baseline is 29 / 5 / 2; the classification below is the
judgment-layer version of the same 36 bullets.

| # | Handle | Classification | Justification |
|---|---|---|---|
| 1 | COPY sources hashed by fingerprint | `test:` | test-image-fingerprint.sh COPY-coverage; but coverage is textual containment — proven mutable-green, §4-C |
| 2 | build args via emit_build_args | `test:` | fingerprint suite build-arg sensitivity + path-independence |
| 3 | staleness hash superset of image hash | `test:` | fingerprint suite split test |
| 4 | nix route never hashes root Dockerfile | `test:` | fingerprint suite mutation F (root-Dockerfile edit leaves nix tag) |
| 5 | .dockerignore lib allowlist | `test:` | test-dockerignore-lib-allowlist.sh, derived via shared parser, empty-set fails |
| 6 | two Dockerfiles mirror COPY block | `test:` (partial) + de-facto `unguarded` remainder — judgment | bullet itself says fingerprint+dockerignore "catch most, not all"; the residue has no annotation and no reason line |
| 7 | classic-arg regex == Dockerfile ARG set | `test:` | test-classic-args-sync.sh, expectation derived (rung 2), every extraction nonempty-guarded |
| 8 | BASE_IMAGE pin byte-anchor, four encodings | `test:` — judgment: one-directional | test-nix-base-pin.sh + test-bump-nix-base.sh check the compose-line side only; the `ensure_nix_base()` grep side is restated, not read — proven mutable-green, §4-A |
| 9 | digest must be a manifest LIST | `tool:` + `test:` | fact lives on the registry; dev/bump-nix-base refuses per-arch digests, test-bump-nix-base.sh proves the refusal (negative fixture) |
| 10 | base image xor seed volume | `unguarded` — judgment | "routing enforced in dev/devcontainer" is the SUT, not a drift guard; no test cites it. Closest honest annotation is `unguarded` with a reason — exactly the case ADR-0005's vocabulary exists for |
| 11 | publish→repin ownership (pin job) | `ci:` + `tool:` + `test:` | nix-base.yml#pin invokes the tool; test-bump-nix-base.sh guards tool behavior incl. the exit-0-when-pinned no-op |
| 12 | pin file excluded from triggers | `test:` | test-nix-base-trigger-paths.sh L146–153 asserts non-coverage |
| 13 | triggers cover tail-build inputs | `test:` | test-nix-base-trigger-paths.sh, expectation derived from Dockerfile + workflow (rung 2) |
| 14 | claude-code pinned twice | `test:` (+ `tool:` bump path) | test-claude-code-pin-sync.sh compares committed values directly; tool only for moving them |
| 15 | NIX_VERSION + installer sha pair | `tool:` + `test:` | sha↔release fact is outside the tree; dev/bump-nix is the coupling, test-bump-nix.sh proves abort-on-bad-download |
| 16 | hadolint triple + pre-commit rev | `tool:` + `test:` | checksums unverifiable hermetically; dev/bump-hadolint writes all-or-nothing, test-bump-hadolint.sh proves it; version==rev also in test-lint-config-sync.sh |
| 17 | linter pins in exactly two places | `test:` | test-lint-config-sync.sh, both sides extracted, nonempty-guarded |
| 18 | lint.yml stays single pre-commit gate | `unguarded` | `(—)`; prose gives the rule's rationale but no accepted-risk reason in the ADR-0005 sense |
| 19 | root logic injected per run, not baked | `test:` (partial) — judgment | test-volume-chown-guard.sh pins only the volume-perms driver line; other injected snippets uncited |
| 20 | setup() idempotent; guarded chown | `test:` | test-volume-chown-guard.sh exercises the guard decision incl. interrupted-walk case |
| 21 | lock discipline fd 9 / fd 8 | `unguarded` | `(—)` |
| 22 | compose file order in dc() | `unguarded` | `(—)` |
| 23 | `${VAR:?}` host-mount discipline | `unguarded` | `(—)` |
| 24 | sanitize_name three consumers | `test:` | test-sanitize-names.sh + test-devcontainer-sessions.sh |
| 25 | naming contracts parsed downstream | `test:` (partial, self-declared) | bullet says "partially tested" |
| 26 | worktree .claude layout, three vintages | `test:` | test-worktree-claude-layout.sh |
| 27 | clean deletes through link + recreates | `test:` | same suite, block lifted and run on all three layouts |
| 28 | pre-flight uses --untracked-files=all | `test:` | same suite |
| 29 | setup-token tier fall-through | `test:` | test-claude-token.sh |
| 30 | profile resolution + re-pin | `test:` | test-claude-token.sh + test-claude-seed.sh |
| 31 | token-env unset-list == HIGHER_PRECEDENCE_ENV | `test:` | test-token-env-snippet.sh derives BOTH sides at check time (rung 2), anchors nonempty-guarded |
| 32 | init never touches pre-existing files | `test:` | test-init-nix.sh (includes refusal negative fixtures) |
| 33 | command surface single source | `structural` + `test:` | generation removes four encodings; residual hand pair (dispatch==table) tested — but the dispatch parser has a fail-open blind spot, proven §4-B |
| 34 | arg-type four-file vocabulary | `test:` | test-completions-sync.sh synthetic one-command-per-type table, wiring must be nonempty and distinct |
| 35 | atomic completion install | `test:` | test-completions-sync.sh |
| 36 | worktree manifest format lockstep | `unguarded` | `(—)` |

**Totals (composed annotations counted once per invariant):**

- `test:` appears in **30** of 36 (the 29 mechanical citations + #6 by judgment).
- `tool:` appears in **4** (#9, #11, #15, #16; #14 has a bump tool but the sync itself is hermetically tested).
- `ci:` appears in **1** (#11).
- `structural` appears in **1** (#33).
- `unguarded` (no drift guard at all): **6** (#10, #18, #21, #22, #23, #36) — 5 marked `(—)`, one (#10) hidden in prose. **None of the six carries a stated accepted-risk reason** as ADR-0005 §1 will require.
- Marked partial / one-directional by this audit: #6, #8, #19, #25 (plus the proven vacuous mechanisms in #1 and #33's residual test, §4).

Judgment calls are flagged in the rows: the load-bearing ones are #10 (runtime
enforcement is not a guard kind — the taxonomy's gap made concrete) and #8
(two suites both restate the anchor; neither reads `dev/devcontainer`).

---

## 2. Rule-asserting comment sweep (baseline for #89)

Reproducible command (run from the repo root):

```
git grep -nEi '(^|[[:space:]])#[^!].*\b(must|never|in sync|lockstep|mirror)\b' -- ':!tests/' ':!docs/' ':!*.md'
```

**Total: 119 lines** (`| wc -l`). Notes on the instrument: `#[^!]` excludes
shebangs; the match is case-insensitive with word boundaries; it has known noise
(e.g. `lib/host-bridge.sh:406` matches the noun "mirror" in "transcript mirror";
many `never` hits describe behavior, not rules) and known blindness (rules stated
without the five marker words are invisible). It is a baseline instrument, not a
definition of "rule".

**Cross-file subset: 27 of the 119 lines assert a cross-file fact that can drift,
covering 15 distinct facts:**

| Fact | Lines | Coupled files | Guard |
|---|---|---|---|
| Trigger paths cover tail-build inputs | `.github/workflows/nix-base.yml:27` | workflow ↔ `nix/base/Dockerfile.nix-default` ↔ `.dockerignore` | `test:` tests/test-nix-base-trigger-paths.sh (derived) |
| Pin file excluded from triggers | `.github/workflows/nix-base.yml:36,52` | workflow ↔ `nix/base/compose.nix-base.yml` | `test:` same suite (L146–153) |
| CI must not re-implement run-all's loop | `.github/workflows/test.yml:19` | workflow ↔ `tests/run-all` | **none** |
| Linter pins paired | `.pre-commit-config.yaml:20`, `projects/devcontainer/install-system.sh:30`, `dev/bump-hadolint:297` | the two pin files | `test:` tests/test-lint-config-sync.sh |
| Pin-file formats anchor the bump tools | `dev/bump-hadolint:41` | tool sed/grep anchors ↔ target file formats | `test:` lint-config-sync nonempty anchors + tests/test-bump-hadolint.sh |
| Claude Code double pin | `dev/bump-claude-code:139`, `nix/base/pkgs/claude-code.nix:43` | `Dockerfile` ↔ `nix/base/pkgs/claude-code.nix` | `test:` tests/test-claude-code-pin-sync.sh |
| BASE_IMAGE anchor trio "kept in sync by hand" | `dev/bump-nix-base:77` | `dev/bump-nix-base` ↔ `dev/devcontainer` `ensure_nix_base()` ↔ `tests/test-nix-base-pin.sh` | `test:` — **one-directional**, see §4-A |
| Every COPY in image_config_files | `dev/devcontainer:513,514` | Dockerfiles ↔ `image_config_files()` | `test:` fingerprint COPY-coverage — **textual, mutable-green**, see §4-C |
| Host-mounts override before first dc() | `dev/devcontainer:776` | `dev/devcontainer` ↔ `lib/host-mounts.sh` | **none** (invariant #22 area, `(—)`) |
| Worktree manifest lockstep | `dev/setup-worktree:11` | `dev/setup-worktree` ↔ `dev/cleanup-worktree` | **none** (invariant #36, `(—)`) |
| Table name == dispatch arm | `lib/command-table.tsv:14` | table ↔ `dev/devcontainer` dispatch | `test:` completions-sync — **fail-open parser blind spot**, see §4-B |
| NIX_USER ↔ hardcoded nix-profile PATH | `lib/nix-seed.sh:27,29`, `projects/devcontainer/compose.override.yml:6,8`, `templates/nix/compose.override.yml:5,7` | `lib/nix-seed.sh` `NIX_USER` ↔ `EXTRA_PATH` in projects/devcontainer, templates/nix, and `projects/xorq-desktop/compose.override.yml:6` (4 value copies) | **none** — two of the copies carry an explicit "keep the two in sync by hand". This is the live coupling ADR-0005's Consequences reference |
| All consumers use dev_main_tree resolver | `lib/git.sh:5` | `lib/git.sh` ↔ every caller | **none** (convention) |
| Sourcer-provides contract | `lib/host-mounts.sh:14` | `lib/host-mounts.sh` ↔ `dev/devcontainer` | **none** (interface prose; borderline inclusion) |
| Tail Dockerfile matches root tail; flake PATH hand-maintained | `nix/base/Dockerfile.nix-default:5`, `nix/base/flake.nix:151` | the two Dockerfiles; flake env ↔ built image | partial (invariant #6); `ci:` `nix/base/check-env-drift.sh` via `nix-base.yml:111` for PATH |

Also cross-file but already guard-adjacent rather than drifting rules:
`setup-claude.py:58` (↔ token-env snippet, `test:` token-env-snippet, derived) and
`nix/home-manager/package.nix:84` (claims `structural` via generation — accurate).

The remaining **~90 lines are local prose** (behavior descriptions, single-file
rules, format notes such as the five `worktree-copies.txt:4` header copies) and get
only this count.

**Unguarded cross-file facts found by the sweep: 6** (test.yml↔run-all;
NIX_USER↔EXTRA_PATH ×4 copies; host-mounts ordering; manifest lockstep;
dev_main_tree convention; host-mounts sourcer contract). The first two exist in no
CLAUDE.md invariant at all.

---

## 3. Suites with self-failure checks ("2 of 25")

Criterion S (ADR §2 sense — the suite feeds its own detection logic a deliberately
broken variant of the guarded artifact and asserts red):

- `tests/test-completions-sync.sh` — `mutate()` battery of 9 broken tables the
  validator must reject (L195–213), a synthetic one-command-per-type table, and an
  explicit anti-vacuity note (L228).
- `tests/test-image-fingerprint.sh` — tree-copy mutations asserting the fingerprint
  changes (content/build-arg sensitivity) and does NOT change (nix-route
  root-Dockerfile edit).

**ADR's "2 of 25" is verified under criterion S.** (Names above; no other suite
mutates its guarded artifact.)

Broader reading — under ADR-0005's own taxonomy the bump tools ARE guards, and four
suites prove the tool goes red on a broken fact (negative fixtures: refused per-arch
digest, unreachable registry, checksum/download failure, reformatted pin):
`test-bump-nix-base.sh`, `test-bump-hadolint.sh`, `test-bump-nix.sh`,
`test-bump-claude-code.sh`. Counting those, **6 of 25**. The report recommends the
ADR keep "2 of 25" only if it scopes the claim to drift-guard suites proving their
own detection; otherwise 6 is the defensible number.

A third tier — anti-vacuity anchors (`assert_nonempty` / explicit empty-set `_fail`
on every extraction), which make the guard fail closed on anchor drift but do not
demonstrate red on a broken invariant: `test-claude-code-pin-sync.sh`,
`test-nix-base-pin.sh`, `test-classic-args-sync.sh`, `test-lint-config-sync.sh`,
`test-dockerignore-lib-allowlist.sh`, `test-nix-base-trigger-paths.sh`,
`test-token-env-snippet.sh`, `test-completions-sync.sh` (7 distinct suites beyond
the two above). The remaining ~14 suites are behavioral SUT tests with neither.

`git grep -n 'Verified:' tests/` → no matches: no suite yet carries the ADR §2
mutation record, consistent with the ADR being new.

---

## 4. Vacuous-pass spot checks

Method: fresh `git clone` of the repo into the scratchpad (`base`, `mutA`, `mutB`,
`mutC`); baseline run of the four target suites in `base` — all green. Each
mutation was applied ONLY in its scratch copy; the real tree was never modified.
After each cited-suite run, the FULL `bash tests/run-all` was run in the mutated
copy. **All three mutations stayed green everywhere** (cited suites pass; run-all:
`Results: 70 passed, 0 failed`, exit 0, for all three).

**A. Invariant #8 (pin byte-anchor) — guard is one-directional.**
Mutation: in `mutA/dev/devcontainer` line 472, the `ensure_nix_base()` extraction
was changed from `grep -oP '\$\{DEV_NIX_BASE_IMAGE:-\K[^}]+'` to
`...DEV_NIX_BASE_IMG:-...`. This breaks the runtime pull path (the pin extraction
now always yields empty). `tests/test-nix-base-pin.sh`: 6 passed, 0 failed.
`tests/test-bump-nix-base.sh`: 62 passed, 0 failed. Full suite green. Both suites
restate the anchor ("keep in sync by hand", test header and `dev/bump-nix-base:77`)
and grep the compose file themselves; nothing reads the anchor actually executed by
`dev/devcontainer`. The four-encoding invariant is guarded only on the
compose-line side.

**B. Invariant #33 residual pair (dispatch arms == table rows) — fail-open parser
blind spot.** Mutation: inserted into `mutB/dev/devcontainer` (before the
`bump-nix-base` early dispatch) a live, reachable subcommand absent from the table:

```
if [[ "${1:-}" == "phantom-cmd" ]]; then
    echo "phantom"
    exit 0
fi
```

`tests/test-completions-sync.sh`: 76 passed, 0 failed; full suite green. The
extraction regex requires the exact shape `if [ "${1:-}" = "<cmd>" ]; then` — a
`[[ ... == ... ]]` arm silently drops out of the derived dispatch set, so a new
command can bypass the table (no usage line, no completions) with every guard
green. Same shape as the #86 parser gap the ADR cites (fixed for COPY parsing in
`tests/lib/dockerfile.sh`, recurring here).

**C. Invariant #1 (COPY sources hashed) — coverage check is textual containment.**
Mutation: in `mutC/dev/devcontainer` `image_config_files()`, the entry
`"$DEV_BASE_DIR/lib/claude-code-token-env.sh" \` was deleted from the emitted list
and a comment added inside the function body:
`# lib/claude-code-token-env.sh is injected at runtime; no longer hashed here.`
The file is genuinely no longer hashed — edits to it would silently reuse a stale
image, the exact failure the invariant names. `tests/test-image-fingerprint.sh`: 34
passed, 0 failed; full suite green. The coverage check (`grep -qF "$src"` against
the function's TEXT, test line ~36) matches the comment. The suite's functional
sensitivity check would have caught this for `lib/git.sh` (the one file it
mutates), but for no other COPY source. Restated-expectation, rung 3, fails open.

Not mutation-tested (candidates considered and set aside as failing closed on
inspection): `test-token-env-snippet.sh` (derives both sides),
`test-classic-args-sync.sh` (derived, nonempty-guarded), the volume-chown driver
pin (`grep -qF` on the exact executed line goes red if the line changes).

---

## Not examined

- The history pass (repeated `fix:` clusters, guard-arrives-late correlation,
  issue re-solves) — out of scope for this invocation, except one `git log` on
  `tests/test-nix-base-trigger-paths.sh` for the §1 reconciliation.
- The ~14 behavioral suites were skimmed for self-failure idioms only, not audited
  for correctness; `tests/lib/harness.sh` was read only for its assert surface.
- CI behavior was read from workflow YAML, never from run logs; no network, no
  docker builds, no registry checks.
- ADR-0001..0003, `nix/base/README.md`'s design record, and `defaults/` overlays
  were not re-read for this baseline.
- The comment sweep sees only the five marker words; rule-comments phrased
  otherwise are uncounted. Comments inside `docs/` and `*.md` were excluded by
  design.
- Only 3 vacuous-pass candidates were mutation-tested; other restated guards
  (atomic-write check, driver-line pin, `test-nix-base-trigger-paths.sh`'s
  fixed-shape YAML parse) were assessed by reading only.

## Method (headline-number commands, run from /workspaces/src)

- M1 total bullets (36): `awk '/^## Invariants$/,/^## Conventions$/' CLAUDE.md | grep -c '^- '`
- M2 bullets citing a test (29): `awk '/^## Invariants$/,/^## Conventions$/' CLAUDE.md | awk '/^- /{if(b)print b;b=$0;next}/^  /{b=b" "$0}END{if(b)print b}' | grep -c 'tests/test-'`
- M3 bullets with `(—)` (5): same join, `| grep -c '(—)'`
- M4 bullets with neither (2): same join, `| grep -v 'tests/test-' | grep -vc '(—)'`
- M5 comment sweep (119): `git grep -nEi '(^|[[:space:]])#[^!].*\b(must|never|in sync|lockstep|mirror)\b' -- ':!tests/' ':!docs/' ':!*.md' | wc -l`
- M6 Verified-header absence: `git grep -n 'Verified:' tests/` (no matches)
- M7 spot checks: `git clone /workspaces/src <scratch>/{base,mutA,mutB,mutC}`; per-copy
  `bash tests/<cited-suite>.sh` then `bash tests/run-all` (exact mutations quoted in §4;
  mutated copies retained under the scratchpad as `mutA/`, `mutB/`, `mutC/`).

