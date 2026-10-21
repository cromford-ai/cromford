# The tick wrapper loses its two one-shots, measured before and after (BH-7433)

Doc: BUILD-CONCURRENCY, OPERATOR-SETUP

## What changed

`bin/fly-pool-tick.sh` no longer carries `retire_legacy_cap` or
`retire_builder_record`. Both came in on 2026-09-14 (pool autoscale, BH-660)
and both ran on every pool project.

- The legacy cap one-shot emptied a number in `flags/fly-pool-<p>` once per
  project and wrote `state/fly-pool/legacy-caps.<p>`. Since 2026-09-14
  `bin/fly-pool-rollout.sh` writes an empty flag unless the operator sets
  `POOL_CAP`. So the one-shot could only hit a deliberate `POOL_CAP` on a new
  project, and then it wiped it. A number in the flag is now a cap, and the
  tick leaves it alone.
- The builder record one-shot moved a top-level `machine_id` in
  `state/fly/<p>.json` under `builder_retired` and sent one ALERTS line.
  `bin/fly-pool-rollout.sh` never writes a `machine_id`, so on the pool route it
  had nothing left to do. `bin/fleet-fly-block.sh` still reads
  `builder_retired` records and does not publish them as a builder.

Old values stay on the hub: `state/fly-pool/legacy-caps.<p>` and
`builder_retired` in `state/fly/<p>.json`. Nothing else in the wrapper changed:
the `pool-cap.sh --autoscale` read, the `POOL_AUTOSCALE=0` sequential branch,
the hang check, the bounded wait, the rows preflight, the onboard drain and the
budget pass are as before.

Suite: `tests/fly-pool-tick-trim.bh-7433-test.sh`.

## Wrapper cost before and after

Method. `measure-tick.sh` (text below) builds a scratch harness under
`/tmp/bh7433-measure/<variant>/h` on this build box. It installs the wrapper and
its libs from the variant's tree (main = origin/main 9b5e2840, branch = this
change). It stubs `bin/fly-pool.sh`, `bin/fly-pool-rows-parity.sh`,
`bin/pool-budget.sh` and `bin/fly-onboard.sh` with `exit 0`, so the numbers are
the wrapper's own cost. It seeds 13 fixture projects in the hub's steady state
(empty flag, app flag, a `builder_retired` record, a `legacy-caps` file, all 13
queued for onboarding and routed). It runs `env -i`, with no `JOBS_URL`, as box
`box-hub` (the hub name, so the onboard drain runs). One warm-up run,
then 5 measured runs. `forks` is the `/proc/stat` `processes` delta, which is
system-wide; `noise` is the same delta in an idle window of the same length;
`net_forks` = forks - noise. `cpu_s` is user+sys of the reaped wrapper.

This is a scratch copy on a build box with `fly-pool.sh` stubbed. It is not a
hub measurement.

Before (origin/main):

| variant | run | wall_s | cpu_s | forks | noise | net_forks |
|---|---|---|---|---|---|---|
| main | 1 | 0.617 | 0.701 | 744 | 2 | 742 |
| main | 2 | 0.584 | 0.668 | 744 | 3 | 741 |
| main | 3 | 0.643 | 0.731 | 744 | 2 | 742 |
| main | 4 | 0.666 | 0.756 | 744 | 9 | 735 |
| main | 5 | 0.631 | 0.720 | 742 | 2 | 740 |
| main | median | 0.631 | 0.720 | 744 | 2 | 741 |

After (this change):

| variant | run | wall_s | cpu_s | forks | noise | net_forks |
|---|---|---|---|---|---|---|
| branch | 1 | 0.518 | 0.588 | 677 | 2 | 675 |
| branch | 2 | 0.570 | 0.647 | 677 | 2 | 675 |
| branch | 3 | 0.598 | 0.679 | 669 | 2 | 667 |
| branch | 4 | 0.611 | 0.693 | 669 | 43 | 626 |
| branch | 5 | 0.645 | 0.730 | 759 | 34 | 725 |
| branch | median | 0.598 | 0.679 | 677 | 2 | 675 |

Medians, per tick, 13 projects:

| metric | before | after | delta |
|---|---|---|---|
| wall_s | 0.631 | 0.598 | -0.033 |
| cpu_s | 0.720 | 0.679 | -0.041 |
| forks | 744 | 677 | -67 |

The fork count is the stable number: 744 before, 677 after (median of 5 runs
each; after run 5 is an outlier, and its noise window also saw other load on
the box). Wall and CPU drop by about 5%, which is inside the run-to-run spread.

Per component (`measure-components.sh`, text below, forks per call, median of
5, in the "before" scratch tree; the baseline row is `env` + `bash`):

| component | forks_median |
|---|---|
| baseline: env -i bash -c : | 2 |
| bin/fly-lock-guard.sh | 295 |
| bin/pool-cap.sh --autoscale | 8 |
| project loop, no one-shots (13) | 2 |
| project loop + both one-shots (13) | 67 |

So the two one-shots cost 65 forks per tick on 13 projects (5 per project:
one `jq` and its subshell, one `cat | tr` and its subshell). That matches the
67-fork drop above. `bin/fly-lock-guard.sh` is the largest single cost, about
290 forks per tick. The ticket keeps it out of scope.

## What stays on #7433

- Move the autoscale decision to the lane-fleet autoscaler (#6881 S6). That
  needs S5 (#7432, mechanism in PR #7515) on main. The `pool-cap.sh --autoscale`
  read and the `POOL_AUTOSCALE=0` sequential branch stay until then.
- Metric "hub processes per pool tick 14 to 1". Needs S5. This note reports the
  measured fork count only.
- Not measured here: the wrapper's cost on the hub.

## measure-tick.sh

```bash
#!/bin/bash
# measure-tick.sh <main|branch> — the wrapper's OWN cost per tick (BH-7433).
#
# Builds a scratch harness under /tmp/bh7433-measure/<variant>/h from one tree
# (main = origin/main via git archive, branch = this worktree), stubs every
# child the wrapper launches (fly-pool.sh, rows-parity, pool-budget,
# fly-onboard) with `exit 0`, seeds 13 fixture projects in the hub's steady
# state, and runs bin/fly-pool-tick.sh 1 warm-up + 5 measured times.
# Per run: wall_s (date +%s.%N), cpu_s (bash `times`, children user+sys
# delta), forks (/proc/stat `processes` delta, system-wide), noise (forks in an
# idle window of the same length, same box) and net = forks - noise.
# Output: TSV, one line per run, then one median line.
set -uo pipefail
V="${1:?usage: measure-tick.sh <main|branch>}"
WT=/root/worktrees/cromford-bh-7433
BASE=/tmp/bh7433-measure
R="$BASE/$V"; HROOT="$R/h"
case "$HROOT" in "$BASE"/*) ;; *) echo "refusing HARNESS outside $BASE" >&2; exit 2 ;; esac
rm -rf "$R"; mkdir -p "$R/src" "$HROOT"

case "$V" in
  main)   git -C "$WT" archive origin/main bin | tar -x -C "$R/src" || exit 3 ;;
  branch) cp -rp "$WT/bin" "$R/src/" || exit 3 ;;   # the working tree, before its commit
  *) echo "variant must be main or branch" >&2; exit 2 ;;
esac

# The wrapper's closure, as the plan lists it, from the variant's own tree.
mkdir -p "$HROOT/bin/lib"
for f in fly-pool-tick.sh pool-cap.sh fly-lock-guard.sh alert-line.sh jobs-client.sh box-name.sh; do
  cp -p "$R/src/bin/$f" "$HROOT/bin/" || exit 4
done
cp -rp "$R/src/bin/lib/." "$HROOT/bin/lib/" || exit 4
# The children whose cost is NOT the wrapper's.
for f in fly-pool.sh fly-pool-rows-parity.sh pool-budget.sh fly-onboard.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$HROOT/bin/$f"; chmod +x "$HROOT/bin/$f"
done

mkdir -p "$HROOT/flags" "$HROOT/logs" "$HROOT/locks" "$HROOT/env" "$HROOT/fly" \
         "$HROOT/state/fly" "$HROOT/state/fly-pool"
: > "$HROOT/env/global.env"
: > "$HROOT/fly/onboard-queue.conf"
for i in $(seq -w 1 13); do
  p="proj$i"
  : > "$HROOT/flags/fly-pool-$p"
  : > "$HROOT/flags/builder-fly-$p"
  printf 'pool-%s\n' "$p" > "$HROOT/flags/fly-pool-app-$p"
  printf '{"app":"builder-%s","builder_retired":{"machine_id":"m-fixture-%s","region":"iad","retired_at":"2026-09-14T00:00:00Z","retired_by":"bin/fly-pool-tick.sh (BH-660)"}}\n' "$p" "$i" \
    > "$HROOT/state/fly/$p.json"
  printf '10 retired 2026-09-14T00:00:00Z by bin/fly-pool-tick.sh (2026-09-14 pool autoscale)\n' \
    > "$HROOT/state/fly-pool/legacy-caps.$p"
  printf '%s 2026-09-14T00:00:00Z\n' "$p" >> "$HROOT/fly/onboard-queue.conf"
done

forks() { awk '/^processes/{print $2}' /proc/stat; }
# `times` must run in the shell that reaped the wrapper, never inside $(...):
# a command substitution is a new subshell and reports its own (empty) children.
cpu_children() { times > "$R/times.txt"; }
cpu_children_read() { # user+sys of reaped children, seconds, from the last cpu_children
  sed -n 2p "$R/times.txt" | awk '{
    split($1,a,"m"); u=a[1]*60+substr(a[2],1,length(a[2])-1);
    split($2,b,"m"); s=b[1]*60+substr(b[2],1,length(b[2])-1); printf "%.3f\n", u+s }'
}
run_once() {
  local f0 f1 t0 t1 c0 c1 n0 n1 wall
  cpu_children; c0=$(cpu_children_read); f0=$(forks); t0=$(date +%s.%N)
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$R" HARNESS="$HROOT" BOX_NAME=box-hub \
      FLY_LOCK_GUARD_LOG="$HROOT/logs/fly-lock-guard.log" \
      bash "$HROOT/bin/fly-pool-tick.sh" >/dev/null 2>&1
  t1=$(date +%s.%N); f1=$(forks); cpu_children; c1=$(cpu_children_read)
  wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
  # Noise floor: forks on this box in an idle window of the same length.
  n0=$(forks); sleep "$wall"; n1=$(forks)
  printf '%s\t%s\t%s\t%s\t%s\n' "$wall" \
    "$(awk -v a="$c0" -v b="$c1" 'BEGIN{printf "%.3f", b-a}')" \
    "$((f1 - f0))" "$((n1 - n0))" "$(( (f1 - f0) - (n1 - n0) ))"
}
median() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

run_once >/dev/null   # warm-up
printf 'variant\trun\twall_s\tcpu_s\tforks\tnoise\tnet_forks\n'
OUT=""
for k in 1 2 3 4 5; do
  L=$(run_once); OUT+="$L"$'\n'
  printf '%s\t%s\t%s\n' "$V" "$k" "$L"
done
printf '%s\tmedian\t%s\t%s\t%s\t%s\t%s\n' "$V" \
  "$(printf %s "$OUT" | cut -f1 | median)" "$(printf %s "$OUT" | cut -f2 | median)" \
  "$(printf %s "$OUT" | cut -f3 | median)" "$(printf %s "$OUT" | cut -f4 | median)" \
  "$(printf %s "$OUT" | cut -f5 | median)"
```

## measure-components.sh

```bash
#!/bin/bash
# measure-components.sh — forks per component of the tick wrapper (BH-7433).
# Runs inside the scratch tree measure-tick.sh main left in
# /tmp/bh7433-measure/main/h (13 fixture projects). 5 runs each, median.
set -uo pipefail
H=/tmp/bh7433-measure/main/h
[ -x "$H/bin/fly-pool-tick.sh" ] || { echo "run measure-tick.sh main first" >&2; exit 2; }
forks() { awk '/^processes/{print $2}' /proc/stat; }
median() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }
E=(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/tmp/bh7433-measure HARNESS="$H" BOX_NAME=box-hub)
# The two one-shots, taken verbatim from main's wrapper, run over the 13 projects.
sed -n '/^retire_legacy_cap() {/,/^}/p;/^retire_builder_record() {/,/^}/p' "$H/bin/fly-pool-tick.sh" > /tmp/bh7433-measure/oneshots.sh
cat > /tmp/bh7433-measure/oneshots-run.sh <<'R'
H="$HARNESS"; . /tmp/bh7433-measure/oneshots.sh
for f in "$H"/flags/fly-pool-*; do
  [ -f "$f" ] || continue
  case "$f" in *fly-pool-app-*) continue;; esac
  P="${f##*fly-pool-}"
  retire_builder_record "$P"; retire_legacy_cap "$f" "$P"
done
R
cat > /tmp/bh7433-measure/empty-loop.sh <<'R'
H="$HARNESS"
for f in "$H"/flags/fly-pool-*; do
  [ -f "$f" ] || continue
  case "$f" in *fly-pool-app-*) continue;; esac
  P="${f##*fly-pool-}"
done
R
measure() { # measure <label> <cmd...>
  local label="$1" k f0 f1 out=""; shift
  for k in 1 2 3 4 5; do
    f0=$(forks); "${E[@]}" "$@" >/dev/null 2>&1; f1=$(forks)
    out+="$((f1 - f0))"$'\n'
  done
  printf '%s\t%s\n' "$label" "$(printf %s "$out" | median)"
}
printf 'component\tforks_median\n'
measure 'baseline: env -i bash -c :' bash -c :
measure 'bin/fly-lock-guard.sh' bash -c "$H/bin/fly-lock-guard.sh; :"
measure 'bin/pool-cap.sh --autoscale' bash -c "$H/bin/pool-cap.sh --autoscale; :"
measure 'project loop, no one-shots (13)' bash /tmp/bh7433-measure/empty-loop.sh
measure 'project loop + both one-shots (13)' bash /tmp/bh7433-measure/oneshots-run.sh
```
