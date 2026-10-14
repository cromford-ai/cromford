#!/bin/bash
# tests/registry-no-commit-test.sh — BH-1247. The lane registry's renders are
# GENERATED, and they are not committed.
#
# WHAT WAS WRONG. BH-1178 (#1182) split the three append targets into fragments
# and kept their renders in git: `cron/<box>.cron` ×10, `catalog/lanes.json` and
# `env-templates/global.env.example`. That left twelve committed artifacts whose
# content is a function of a directory every build writes to — so a PR that adds
# or edits a lane and does not re-render turns RED on
# tests/registry-render-test.sh, and once such a PR merges, every OTHER open PR
# inherits the red on a file its ticket never mentioned. Three merge trains died
# that way on 2026-09-21 (#1241, #1257, #1263); #1241 went red immediately after
# #1234 hand-edited four lanes.
#
# A generated file that is committed is a shared mutable cell every build
# writes, and `merge=union` in front of it is a driver that concatenates two
# renders into a third nobody produced. BH-1175 already answered this shape for
# docs/verification-map/README.md: take the file OUT of git rather than resolve
# the contest. This suite is that answer applied to the twelve.
#
# So the renders are git-ignored, every consumer renders before it reads, and
# `--check` stops comparing bytes (there is nothing committed to compare) and
# instead proves the three things that can still be wrong:
#
#   * the SOURCES are valid (what `--check` already validated),
#   * the render is DETERMINISTIC — two renders of the same sources are byte
#     identical, which is the property the byte comparison used to stand in for,
#   * no render is TRACKED in git, whether or not .gitignore still covers it.
#
# `--check-committed` keeps the old byte comparison for a repo that still
# commits its renders (exactly as bin/verification-map-build.sh does).
#
# WHAT THESE ASSERTIONS ARE WORTH. Every case drives the REAL renderers, the
# REAL loader and REAL git — real branches, a real merge, the repo's real
# sources copied into scratch repositories. Nothing below restates the logic it
# is testing.
#
#   RN-1  this repo really does not TRACK any of the twelve.
#   RN-2  ...and really does IGNORE all twelve, so a `git add -A` cannot
#         reintroduce one by accident.
#   RN-3  a TRACKED render fails `--check`, by name, for all three renderers.
#   RN-4  ...and it fails even when .gitignore no longer covers it. A gate whose
#         subject can delete the gate is not a gate (BH-1175's wording).
#   RN-5  `--check` proves DETERMINISM: two renders of the same sources are
#         byte-identical, and a source that renders differently each time is
#         refused. This is what replaces "the committed bytes equal the render".
#   RN-6  `--check-committed` still answers the OLD question, both ways, so the
#         lanes and target repos that still commit a render keep their check.
#   RN-7  THE TICKET. Two branches that each add a lane MERGE CLEAN with no
#         merge attribute and no resolver — the contest is gone because the
#         contested files are gone — and both lanes reach the render afterwards.
#   RN-8  .gitattributes declares NO merge driver for any of the twelve. An
#         attribute left behind on a path git never sees comes back into force
#         the day somebody re-adds the file (BH-1175's negative list).
#   RN-9  THE CONSUMERS. A tree with NO cron/<box>.cron still renders a full
#         crontab through bin/render-crontab.sh, and bin/box-name.sh still
#         resolves the box name from it — the two paths a box installs through.
#   RN-10 the lanes loader renders a registry when none is on disk, is STABLE on
#         a second call (it does not re-render unchanged sources), and
#         RE-RENDERS after a lane file changes. A loader that caches a stale
#         registry is a lane whose kill switch reads yesterday's answer.
#   RN-11 the reviewable diff is not lost: bin/render-diff.sh prints what a box
#         will actually run, against a base ref, for the crontabs and the
#         registry. That is the cost BH-1247 was asked to pay back.
#
# No network, no clock, no gh: scratch repositories under $T and nothing else.
# Run from anywhere: bash tests/registry-no-commit-test.sh   (0 = all pass)
# As root next to a live harness: HARNESS_TEST_SANDBOX=1 bash tests/registry-no-commit-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
done_() { echo "registry-no-commit: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]; }

command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
command -v jq  >/dev/null || { echo "jq missing — skipping";  exit 0; }
# RN-5 bounds a renderer it has deliberately made non-deterministic, and
# `timeout` is GNU-only — absent on a stock macOS. The case SAYS SO and is
# counted as skipped rather than failing; everything else here is portable.
# (tests/lib/scratch.sh separately needs `realpath -m`, which is the same story
# for every suite in this repo, not something this one can fix.)
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
for S in render-cron.sh lanes-build.sh render-env-example.sh render-crontab.sh box-name.sh render-diff.sh; do
  [ -x "$DIR/bin/$S" ] || { echo "FAIL: bin/$S is missing or not executable"; exit 1; }
done
[ -r "$DIR/bin/lib/lanes-registry.sh" ] || { echo "FAIL: bin/lib/lanes-registry.sh is missing"; exit 1; }

export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com
git config --global user.name  t
git config --global init.defaultBranch main
git config --global commit.gpgsign false

BOXES="project-4 hub project-6 project-1 project-3 project-10 project-9 small project-2 project-5"
GENERATED="catalog/lanes.json env-templates/global.env.example"
for B in $BOXES; do GENERATED="$GENERATED cron/$B.cron"; done

# ── RN-1 nothing among the twelve is tracked ────────────────────────────────
# `git ls-files` over the real repo, not a fixture: the claim is about what this
# branch ships. A working-tree test would pass while git still carried the file.
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  TRACKED=""
  for P in $GENERATED; do
    [ -n "$(git -C "$DIR" ls-files -- "$P" 2>/dev/null)" ] && TRACKED="$TRACKED $P"
  done
  [ -z "${TRACKED// /}" ] && ok \
    || bad "RN-1 these renders are still TRACKED in git:$TRACKED — they are generated (BH-1247)"

  # ── RN-2 ...and all twelve are ignored ────────────────────────────────────
  NOTIGN=""
  for P in $GENERATED; do
    git -C "$DIR" check-ignore -q --no-index -- "$P" 2>/dev/null || NOTIGN="$NOTIGN $P"
  done
  [ -z "${NOTIGN// /}" ] && ok \
    || bad "RN-2 .gitignore does not cover:$NOTIGN — the next \`git add -A\` commits it again"
else
  echo "registry-no-commit: RN-1/RN-2 skipped (no git dir at $DIR)"; ok; ok
fi

# ── a scratch repo carrying this branch's REAL committed sources ────────────
# `git archive HEAD`, NOT `cp -r`: the fixture must commit exactly what this
# branch commits. A working-tree copy would carry the generated files either way
# and RN-7 would never have been red.
# The tree is exported ONCE and copied per case. Eleven `git archive HEAD | tar`
# of a repo this size is minutes of wall clock on a shared runner, and every
# case wants the same bytes.
TEMPLATE="$T/template"
mkdir -p "$TEMPLATE"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1 \
   && git -C "$DIR" archive HEAD 2>/dev/null | tar -x -C "$TEMPLATE" 2>/dev/null \
   && [ -d "$TEMPLATE/catalog/lanes.d" ]; then :
else
  # No git (a bare export): the working tree, minus the artifacts. A fixture
  # that inherited a stale render would grade a tree nobody ships.
  cp -R "$DIR/bin" "$DIR/cron" "$DIR/catalog" "$DIR/env-templates" "$TEMPLATE/" 2>/dev/null
  cp "$DIR/fleet.conf" "$TEMPLATE/fleet.conf" 2>/dev/null
  cp "$DIR/.gitignore" "$TEMPLATE/.gitignore" 2>/dev/null || :
  cp "$DIR/.gitattributes" "$TEMPLATE/.gitattributes" 2>/dev/null || :
  rm -f "$TEMPLATE/catalog/lanes.json" "$TEMPLATE/catalog/.lanes.json.stamp" \
        "$TEMPLATE/env-templates/global.env.example"
  rm -f "$TEMPLATE"/cron/*.cron
fi
[ -d "$TEMPLATE/catalog/lanes.d" ] || { echo "FAIL: could not build a fixture tree from $DIR"; exit 1; }

scratch_repo() { # scratch_repo <name> — prints the path
  local d="$T/$1"
  scratch_rm "$d" || exit 1
  cp -a "$TEMPLATE" "$d" || exit 1
  printf '%s' "$d"
}

# ── RN-3 a TRACKED render fails --check, by name ────────────────────────────
# Each renderer is driven in its own scratch repo, with its own render force-added
# past .gitignore — the stale-branch and `git add -f` shapes, which are the two
# ways a contested file comes back after it has been removed.
# rn3 <label> <script> <write-flag> <check-flag> <rendered path>. The write and
# check flags are passed SEPARATELY rather than derived from one another: the
# cron renderer writes with `--all` and checks with `--check`, so a helper that
# rewrote `--write` into `--check` silently ran `--all` twice and graded a
# renderer that had never been asked the question (caught red, first run).
rn3() {
  local label="$1" script="$2" wflag="$3" cflag="$4" path="$5" out rc r
  r=$(scratch_repo "r3-$label")
  ( cd "$r" && git init -q . && git add -A && git commit -qm base ) >/dev/null 2>&1
  ( cd "$r" && "$script" "$wflag" ) >/dev/null 2>&1
  [ -f "$r/$path" ] || { bad "RN-3 $label: the renderer wrote no $path to force-add"; return; }
  # force it into git PAST the ignore rule — the stale-branch / `git add -f` shape
  ( cd "$r" && git add -f -- "$path" && git commit -qm "the contested cell, back" ) >/dev/null 2>&1
  out=$( cd "$r" && "$script" "$cflag" 2>&1 ); rc=$?
  [ "$rc" != 0 ] && ok || bad "RN-3 $label: $script $cflag accepted a TRACKED $path (rc 0)"
  grep -qi 'tracked' <<<"$out" \
    && ok || bad "RN-3 $label: the refusal does not say the file is tracked: $(head -2 <<<"$out" | tr '\n' ' ')"
  grep -qF "$path" <<<"$out" \
    && ok || bad "RN-3 $label: the refusal does not name $path"
}
rn3 lanes bin/lanes-build.sh        --write --check catalog/lanes.json
rn3 env   bin/render-env-example.sh --write --check env-templates/global.env.example
rn3 cron  bin/render-cron.sh        --all   --check cron/hub.cron

# ── RN-4 ...and dropping the ignore line does not switch the gate off ───────
R4=$(scratch_repo r4)
( cd "$R4" && git init -q . && git add -A && git commit -qm base ) >/dev/null 2>&1
( cd "$R4" && bin/lanes-build.sh --write ) >/dev/null 2>&1
# delete the ignore rule AND commit the render: the PR that switches its own gate off
grep -v 'catalog/lanes\.json' "$R4/.gitignore" > "$R4/.gitignore.new" 2>/dev/null \
  && mv "$R4/.gitignore.new" "$R4/.gitignore"
( cd "$R4" && git add -A && git commit -qm "drop the ignore line and commit the render" ) >/dev/null 2>&1
O4=$( cd "$R4" && bin/lanes-build.sh --check 2>&1 ); RC4=$?
[ "$RC4" != 0 ] && ok || bad "RN-4 --check passed on a tracked registry once .gitignore stopped covering it (rc 0) — a PR can switch its own gate off"

# ── RN-5 --check proves the render is DETERMINISTIC ─────────────────────────
# Positive: the real sources render to the same bytes twice, through --check.
for PAIR in "lanes-build.sh:--check" "render-env-example.sh:--check" "render-cron.sh:--check"; do
  S=${PAIR%%:*}; F=${PAIR#*:}
  O=$( cd "$DIR" && "bin/$S" "$F" 2>&1 ); RC=$?
  [ "$RC" = 0 ] && ok || bad "RN-5 bin/$S $F refused this repo's own sources (rc $RC): $(head -3 <<<"$O" | tr '\n' ' ')"
done
# Negative: a source that renders differently on each run must be REFUSED, or
# "deterministic" is a word and not a check. The non-determinism is put in the
# SOURCE (a lane file whose id changes per read is impossible, so the probe is a
# topic file that the renderer reads twice) — a renderer that only ever reads
# once would pass this trivially, which is why the probe names the render itself.
# A SOURCE THAT DOES NOT READ THE SAME TWICE. The first cut used a named pipe,
# and it proved nothing: rf_fragments lists a fragment dir with `[ -f "$f" ]`,
# a FIFO is not a regular file, so the probe was skipped entirely and both
# renders came out identical — `--check` passed and the case reported a pass it
# had not earned (caught red, first run).
#
# So the non-determinism goes where the renderer actually reads bytes: `cat`.
# A shim on PATH passes everything through to the real cat except one probe
# topic file, for which it prints a counter that advances on every call. The
# renderer concatenates its topics once per render and `--check` renders twice,
# so render 1 and render 2 differ by exactly that line, with no timing, no
# background writer and nothing to hang on.
if [ "$HAVE_TIMEOUT" = 0 ]; then
  echo "registry-no-commit: RN-5 SKIPPED — no \`timeout\` on this host (GNU coreutils); run it on Linux or the Fly test host."
else
R5=$(scratch_repo r5)
printf '# ---- zz nondeterministic probe ----\n#ZZ_NONDET=0\n' \
  > "$R5/env-templates/lanes/998-zz-nondet.env.example"
mkdir -p "$T/shim"
REAL_CAT=$(command -v cat)
cat > "$T/shim/cat" <<SHIM
#!/bin/bash
for a in "\$@"; do
  case "\$a" in
    *998-zz-nondet.env.example)
      n=\$(cat "$T/nondet.count" 2>/dev/null || echo 0); n=\$((n+1))
      printf '%s\\n' "\$n" > "$T/nondet.count"
      printf '#ZZ_NONDET=%s\\n' "\$n"
      exit 0 ;;
  esac
done
exec "$REAL_CAT" "\$@"
SHIM
chmod +x "$T/shim/cat"
rm -f "$T/nondet.count"
O5=$( cd "$R5" && PATH="$T/shim:$PATH" timeout 60 bin/render-env-example.sh --check 2>&1 ); RC5=$?
# The shim must actually have fired, or this case is green for the old reason.
N5=$(cat "$T/nondet.count" 2>/dev/null || echo 0)
[ "${N5:-0}" -ge 2 ] && ok \
  || bad "RN-5 the non-determinism probe was never read (count=${N5:-0}) — --check cannot have rendered twice"
[ "$RC5" != 0 ] && ok \
  || bad "RN-5 --check accepted a source that does not render to the same bytes twice (rc 0): $(head -2 <<<"$O5" | tr '\n' ' ')"
grep -qi 'twice\|deterministic\|same bytes' <<<"$O5" \
  && ok || bad "RN-5 the refusal does not say what was wrong: $(head -2 <<<"$O5" | tr '\n' ' ')"
fi

# ── RN-6 --check-committed still answers the OLD question, both ways ────────
R6=$(scratch_repo r6)
( cd "$R6" && bin/lanes-build.sh --write ) >/dev/null 2>&1
( cd "$R6" && bin/lanes-build.sh --check-committed ) >/dev/null 2>&1 \
  && ok || bad "RN-6 --check-committed refused a registry it had just written"
jq '.version = "zz-stale"' "$R6/catalog/lanes.json" > "$R6/catalog/lanes.json.tmp" \
  && mv "$R6/catalog/lanes.json.tmp" "$R6/catalog/lanes.json"
( cd "$R6" && bin/lanes-build.sh --check-committed ) >/dev/null 2>&1 \
  && bad "RN-6 --check-committed accepted a STALE committed registry" || ok
rm -f "$R6/catalog/lanes.json"
( cd "$R6" && bin/lanes-build.sh --check-committed ) >/dev/null 2>&1 \
  && bad "RN-6 --check-committed accepted a MISSING committed registry" || ok

# ── RN-7 THE TICKET: two branches, two lanes, one clean merge, no attribute ──
R7=$(scratch_repo r7)
G="git -C $R7"
( cd "$R7" && git init -q . && git add -A && git commit -qm base ) >/dev/null 2>&1
# Every one of the twelve must be absent from the fixture's HEAD, or the merge
# below is clean for the wrong reason.
STILL=""
for P in $GENERATED; do
  [ -n "$($G ls-files -- "$P" 2>/dev/null)" ] && STILL="$STILL $P"
done
[ -z "${STILL// /}" ] && ok \
  || bad "RN-7 the fixture still commits:$STILL — the clean merge below would prove nothing"

add_lane() { # <repo> <id> <minute>
  local r="$1" id="$2" min="$3"
  jq -n --arg i "$id" --arg c "$min * * * *" '{
      id: $i, name: $i, scope: "box", script: ("bin/" + $i + ".sh"), cadence: $c,
      boxes: ["project-4"], switch: {kind: "flag", name: ("lane-off-" + $i), aliases: []},
      wired: false, knobs: [], stats: {cost_stage: null, cost_project_filter: null,
      lanes_row: false, log: ("logs/" + $i + ".log")}}' > "$r/catalog/lanes.d/$id.json"
  printf '%s * * * * /root/harness/bin/%s.sh >/dev/null 2>&1\n' "$min" "$id" \
    > "$r/cron/lanes/615-$id.cron"
  printf '\n# ---- %s ----\n#%s_CAP=1\n' "$id" "$(printf '%s' "$id" | tr 'a-z-' 'A-Z_')" \
    > "$r/env-templates/lanes/900-$id.env.example"
}
$G checkout -q -b lane-a
add_lane "$R7" zz-lane-a 7
$G add -A && $G commit -qm "lane a" >/dev/null
$G checkout -q main
$G checkout -q -b lane-b
add_lane "$R7" zz-lane-b 9
$G add -A && $G commit -qm "lane b" >/dev/null
if $G merge --no-edit lane-a >"$T/m7" 2>&1; then ok
else bad "RN-7 two branches each adding a lane CONFLICTED: $(head -3 "$T/m7" | tr '\n' ' ')"; fi
# and the render over the merged tree carries both, with nothing hand-resolved
( cd "$R7" && bin/lanes-build.sh --write && bin/render-cron.sh --all ) >"$T/o7" 2>&1 \
  && ok || bad "RN-7 the merged tree would not render: $(head -3 "$T/o7" | tr '\n' ' ')"
[ "$(jq -r '[.lanes[]|select(.id|startswith("zz-lane-"))]|length' "$R7/catalog/lanes.json" 2>/dev/null)" = 2 ] \
  && ok || bad "RN-7 the merged registry does not carry both lanes"
[ "$(grep -c 'zz-lane-[ab]\.sh' "$R7/cron/project-4.cron" 2>/dev/null)" = 2 ] \
  && ok || bad "RN-7 the merged crontab does not carry both lanes"

# ── RN-8 no merge attribute survives on any of the twelve ───────────────────
# An attribute for a path git never sees is a rule with no subject that comes
# back into force the moment somebody re-adds the file (BH-1175, GT-3).
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  ATTRS=""
  for P in $GENERATED; do
    A=$(git -C "$DIR" check-attr merge -- "$P" 2>/dev/null | sed 's/.*: merge: //')
    [ "$A" = unspecified ] || ATTRS="$ATTRS $P=$A"
  done
  [ -z "${ATTRS// /}" ] && ok \
    || bad "RN-8 a merge attribute survives on a path git no longer tracks:$ATTRS"
else
  echo "registry-no-commit: RN-8 skipped (no git dir)"; ok
fi

# ── RN-9 THE CONSUMERS render before they read ──────────────────────────────
# The two paths a box installs a crontab through, in a tree that carries NO
# cron/<box>.cron — which is every fresh checkout from here on.
R9=$(scratch_repo r9)
[ ! -f "$R9/cron/hub.cron" ] && ok || bad "RN-9 the fixture still carries a committed cron/hub.cron"
O9=$( cd "$R9" && bin/render-crontab.sh hub 2>"$T/e9" ); RC9=$?
[ "$RC9" = 0 ] && ok || bad "RN-9 render-crontab.sh hub failed with no committed base (rc $RC9): $(head -3 "$T/e9" | tr '\n' ' ')"
# A failure here USED to say only "not the real render", which names the
# symptom and none of the causes: the render can lose the gate because the
# fragments were not there to render from (so the base came from a file, or from
# nothing), because the registry gave hub no hub-lanes lane, or because the
# marker pass did not fire. BH-1554: the message carries all three, plus the
# renderer's own stderr. One red run of this case on a shared runner
# (2026-09-23) cost a whole fix round to attribute because none of that was in
# the log, and the case is not reproducible after the fact.
# BH-1913: that red was this line itself. `printf "$O9" | grep -q` under
# pipefail fails whenever grep exits on its early match before printf has
# written the ~25 KB render: printf takes SIGPIPE (141) and the `if` reads a
# gate that IS there as absent. The here-string has no pipe to break. The
# pattern is the gate itself, `hub-lease.sh check && `: the bare script name
# also matches the ungated `hub-lease.sh renew` lane, which renders whether or
# not a single lane is gated, so it passed a render with no gate at all.
if grep -q '/root/harness/bin/hub-lease\.sh check && ' <<<"$O9"; then ok; else
  bad "RN-9 the rendered hub crontab carries no hub-lease gate — it is not the real render.
  fragments: $( [ -d "$R9/cron/lanes" ] && echo "cron/lanes/ present, $(ls -1 "$R9"/cron/lanes/*.cron 2>/dev/null | grep -c .) fragment(s), $(grep -l '^# @hub-lanes$' "$R9"/cron/lanes/*.cron 2>/dev/null | grep -c .) marked @hub-lanes" || echo "cron/lanes/ MISSING — render-crontab.sh took its base from a file, not a render")
  registry: $( ( cd "$R9" && bin/lanes-build.sh --to "$T/r9.json" >/dev/null 2>&1 \
                 && jq -r '[.lanes[]|select((.boxes//[])|index("hub"))]|length' "$T/r9.json" 2>/dev/null ) || echo "?" ) lane(s) list box hub
  BEGIN hub-lanes in the render: $(printf '%s\n' "$O9" | grep -c '^# BEGIN hub-lanes')
  render stderr: $(head -3 "$T/e9" | tr '\n' ' ')
  first 5 lines: $(printf '%s\n' "$O9" | grep . | head -5 | tr '\n' ' ')"
fi
[ "$(printf '%s\n' "$O9" | grep -c .)" -gt 20 ] \
  && ok || bad "RN-9 the rendered hub crontab is $(printf '%s\n' "$O9" | grep -c .) lines — a base that rendered empty"
# box-name.sh reads the same file to name the box to the fleet. With no
# committed copy it must render one, or every box reports its hostname into the
# jobs ledger (the BH-1132 box column) — silently.
mkdir -p "$T/bn-harness/state"
printf 'hub\n' > "$T/bn-harness/state/box-id"
N9=$( HARNESS="$T/bn-harness" CHECKOUT="$R9" BOX_NAME= "$R9/bin/box-name.sh" 2>/dev/null )
[ -n "$N9" ] && [ "$N9" != "$(hostname 2>/dev/null)" ] \
  && ok || bad "RN-9 box-name.sh fell back to the hostname with no committed cron file (got '${N9:-}')"

# ── RN-10 the loader renders, caches, and re-renders on a change ────────────
R10=$(scratch_repo r10)
# shellcheck source=../bin/lib/lanes-registry.sh
. "$R10/bin/lib/lanes-registry.sh" || bad "RN-10 bin/lib/lanes-registry.sh would not source"
[ ! -f "$R10/catalog/lanes.json" ] && ok || bad "RN-10 the fixture already carries a registry"
P10=$(lanes_json_path "$R10"); RC10=$?
[ "$RC10" = 0 ] && [ -n "$P10" ] && [ -s "$P10" ] \
  && ok || bad "RN-10 lanes_json_path rendered nothing (rc $RC10, path '${P10:-}')"
jq -e '.lanes|length > 50' "$P10" >/dev/null 2>&1 \
  && ok || bad "RN-10 the rendered registry does not carry the fleet's lanes: $(jq -r '.lanes|length' "$P10" 2>&1)"
# stable: a second call returns the same path and does not rewrite the file
S1=$(cksum < "$P10"); M1=$(cat "$P10")
P10B=$(lanes_json_path "$R10")
[ "$P10B" = "$P10" ] && ok || bad "RN-10 a second call returned a different path ($P10B vs $P10)"
[ "$(cat "$P10")" = "$M1" ] && [ "$(cksum < "$P10")" = "$S1" ] \
  && ok || bad "RN-10 the second call rewrote an unchanged registry"
# ...and it RE-RENDERS when a lane file changes, or a kill switch reads yesterday
jq -n '{id:"zz-loader-probe",name:"zz",scope:"box",script:"bin/zz.sh",cadence:"5 * * * *",
  boxes:["project-4"],switch:{kind:"flag",name:"lane-off-zz-loader-probe",aliases:[]},wired:false,
  knobs:[],stats:{cost_stage:null,cost_project_filter:null,lanes_row:false,log:"logs/zz.log"}}' \
  > "$R10/catalog/lanes.d/zz-loader-probe.json"
P10C=$(lanes_json_path "$R10")
jq -e '.lanes[]|select(.id=="zz-loader-probe")' "$P10C" >/dev/null 2>&1 \
  && ok || bad "RN-10 the loader served a STALE registry after a lane file was added"
# an explicit LANE_REGISTRY still wins, unchanged — suites drive fixtures through it
printf '{"version":"fixture","note":"","lanes":[]}' > "$T/fixture-registry.json"
[ "$(LANE_REGISTRY="$T/fixture-registry.json" lanes_json_path "$R10")" = "$T/fixture-registry.json" ] \
  && ok || bad "RN-10 LANE_REGISTRY no longer wins over the render"

# ── RN-11 the reviewable diff is paid back ──────────────────────────────────
# Uncommitting the renders takes "what will this box actually run" out of the
# PR diff. bin/render-diff.sh puts it back: it renders at the base and at HEAD
# and prints the difference, which is the thing a reviewer was reading.
R11=$(scratch_repo r11)
( cd "$R11" && git init -q . && git add -A && git commit -qm base \
  && git update-ref refs/remotes/origin/main HEAD ) >/dev/null 2>&1
O11=$( cd "$R11" && bin/render-diff.sh origin/main 2>&1 ); RC11=$?
[ "$RC11" = 0 ] && ok || bad "RN-11 render-diff.sh failed on an unchanged tree (rc $RC11): $(head -3 <<<"$O11" | tr '\n' ' ')"
grep -qi 'no change\|identical\|unchanged' <<<"$O11" \
  && ok || bad "RN-11 an unchanged tree must say so plainly. Got: $(head -3 <<<"$O11" | tr '\n' ' ')"
add_lane "$R11" zz-diff-probe 11
( cd "$R11" && git add -A && git commit -qm "add a lane" ) >/dev/null 2>&1
O11B=$( cd "$R11" && bin/render-diff.sh origin/main 2>&1 ); RC11B=$?
[ "$RC11B" = 0 ] && ok || bad "RN-11 render-diff.sh failed on a real lane addition (rc $RC11B): $(head -5 <<<"$O11B" | tr '\n' ' ')"
grep -q 'zz-diff-probe' <<<"$O11B" \
  && ok || bad "RN-11 the diff does not show the crontab line the box would gain"
grep -q 'cron/project-4.cron' <<<"$O11B" \
  && ok || bad "RN-11 the diff does not name the box file that changed"
grep -q 'catalog/lanes.json' <<<"$O11B" \
  && ok || bad "RN-11 the diff does not cover the lane registry"

# ── RN-12 THE LOADER WRITES NOTHING INTO THE TREE BUT THE RENDER ───────────
# Its staleness stamp used to sit at catalog/.lanes.json.stamp, beside the
# render. bin/publish-share.sh renders the twelve before sanitizing,
# bin/share/sanitize.py copies the tree by WALKING it, and bin/share/leakcheck.py
# refuses any file with an un-auditable extension — so the public mirror stopped
# publishing, on every push, saying nothing. That is the 2026-09-13 freeze shape
# (BH-1247 review, B1). The rule that replaces it is stated as a test, because
# "we moved that one file" is not a rule: after a render, the ONLY path the
# loader may have added to the tree is catalog/lanes.json.
# THE CLAIM IS A DELTA, NOT AN ABSOLUTE SET. The first cut asserted that
# `git status --porcelain --ignored` equalled exactly catalog/lanes.json after
# the render, and that is a statement about the whole checkout rather than about
# the loader: this repo TRACKED locks-worker/.wrangler/cache/cf.json (until BH-5518 C2) while
# .gitignore ignores .wrangler/, so a git-archive fixture reports
# `!! locks-worker/.wrangler/` before the loader has run at all and the case
# failed in every real checkout (CI shard 1: 51/1). It went green only in a
# scratch whose own `git add -A` had already dropped that directory — a false
# green that hid nothing but itself. Snapshot BEFORE, snapshot AFTER, and assert
# what the loader ADDED.
R12=$(scratch_repo r12)
( cd "$R12" && git init -q . && git add -A && git commit -qm base ) >/dev/null 2>&1
ign12() { ( cd "$R12" && git status --porcelain --ignored 2>/dev/null | awk '{print $2}' | grep -v '^$' | LC_ALL=C sort ); }
BEFORE12=$(ign12)
# shellcheck source=../bin/lib/lanes-registry.sh
. "$R12/bin/lib/lanes-registry.sh" || bad "RN-12 the loader would not source"
lanes_json_path "$R12" >/dev/null || bad "RN-12 the loader did not render"
ADDED=$( comm -13 <(printf '%s\n' "$BEFORE12") <(ign12) | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' )
[ "$(printf '%s' "$ADDED" | tr -d ' ')" = "catalog/lanes.json" ] && ok \
  || bad "RN-12 the loader added more than the render to the tree — every extra path reaches the public mirror and leakcheck refuses it (BH-1247 B1). Added:${ADDED:- <nothing>}"

# ── RN-13 A STALE ON-DISK cron/<box>.cron MUST NOT WIN OVER THE RENDER ──────
# The file is git-ignored now, so a copy left by one `bin/render-cron.sh --all`
# in a box checkout is invisible to git status, is never deleted by a pull, and
# would be the base for every future install while the fragments move under it
# (BH-1247 review, I1). Nothing automated plants one — but the Generated-files
# table and cron/README.md both tell a human to run exactly that command.
R13=$(scratch_repo r13)
( cd "$R13" && bin/render-cron.sh --all ) >/dev/null 2>&1
[ -s "$R13/cron/hub.cron" ] && ok || bad "RN-13 --all wrote no cron/hub.cron to go stale"
printf '17 * * * * /root/harness/bin/zz-stale-probe.sh\n' > "$R13/cron/boxes/hub.d/990-zz-stale-probe.cron"
[ "$( cd "$R13" && bin/render-cron.sh hub 2>/dev/null | grep -c zz-stale-probe )" = 1 ] \
  && ok || bad "RN-13 a fresh render does not carry the new fragment — the probe is wrong, not the code"
[ "$( cd "$R13" && bin/render-crontab.sh hub 2>/dev/null | grep -c zz-stale-probe )" = 1 ] \
  && ok || bad "RN-13 the INSTALLED crontab still comes from the stale on-disk cron/hub.cron — the fragment added after it is not in what the box would run"

# ── RN-14 A RENDERER CHANGE MOVES THE LOADER'S ANSWER ───────────────────────
# The staleness key digests catalog/lanes.d/ AND bin/lanes-build.sh. Without the
# renderer a change to the COMPOSITION leaves every source byte untouched, so
# the key does not move and a box keeps serving the previous composition until
# some unrelated lane file changes (BH-1247 review, I2).
R14=$(scratch_repo r14)
P14=$(lanes_json_path "$R14")
[ -n "$P14" ] && ok || bad "RN-14 the loader rendered nothing to begin with"
NOTE_BEFORE=$(jq -r '.note // ""' "$P14" 2>/dev/null)
sed -i.bak 's/note: \$hdr\[0\].note/note: ("ZZ-RENDERER-CHANGED " + $hdr[0].note)/' "$R14/bin/lanes-build.sh" \
  && rm -f "$R14/bin/lanes-build.sh.bak"
grep -q 'ZZ-RENDERER-CHANGED' "$R14/bin/lanes-build.sh" && ok \
  || bad "RN-14 the renderer mutation did not apply — the probe is wrong, not the code"
P14B=$(lanes_json_path "$R14")
NOTE_AFTER=$(jq -r '.note // ""' "$P14B" 2>/dev/null)
case "$NOTE_AFTER" in
  ZZ-RENDERER-CHANGED*) ok ;;
  *) bad "RN-14 the loader served the OLD composition after bin/lanes-build.sh changed (note before='$NOTE_BEFORE' after='$NOTE_AFTER') — the renderer is not in the staleness key" ;;
esac

done_
