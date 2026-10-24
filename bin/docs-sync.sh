#!/bin/bash
# bin/docs-sync.sh — rebuild the git-ignored doc indexes of the harness
# checkout, off the sync's critical path (BH-6806).
#
#   HARNESS=<live> HARNESS_CHECKOUT=<checkout> bin/docs-sync.sh
#
# bin/harness-sync.sh launches this DETACHED, after its rsyncs, its worker
# phase and its success stamp, so a slow or failed doc build never holds back
# code. It renders three files nothing in a sync or a worker deploy reads:
#   docs/LLM_CALL_SITES.md          (bin/llm-sites-build.sh, BH-1268)
#   docs/notes/INDEX.md             (bin/render-doc-index.sh, BH-8254; about
#                                    4 s, rendered every run, no key stamp)
#   docs/verification-map/README.md (bin/verification-map-build.sh, BH-1175;
#                                    bin/verification-map.sh renders primers
#                                    from it)
#
# The verification-map build is skipped when its input key (the git ids of
# entries/, index/ and the generator at HEAD) equals state/verification-map-built,
# the README exists, and those inputs have no uncommitted edit. The key is
# stamped only after a good build, so a failed or killed build is retried by the
# next sync. A held locks/docs-sync.lock means a build is running: exit 0, and
# the next sync launches again.
#
# Output: generator output and the skip line go to stdout (the caller's
# logs/docs-sync.log). One line per real build goes to logs/update-runners.log,
# with its duration, so a slow build is visible.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
CK="${HARNESS_CHECKOUT:-/root/harness-checkout}"
LOG="$HARNESS/logs/update-runners.log"
KEYSTAMP="$HARNESS/state/verification-map-built"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

mkdir -p "$HARNESS/locks" "$HARNESS/state" "$HARNESS/logs" 2>/dev/null
exec 9>"$HARNESS/locks/docs-sync.lock" || exit 0
flock -n 9 || exit 0

if [ -x "$CK/bin/llm-sites-build.sh" ]; then
  nice -n 10 "$CK/bin/llm-sites-build.sh" --repo "$CK" \
    || echo "$(STAMP) harness sync: docs/LLM_CALL_SITES.md could not be regenerated" >> "$LOG"
fi

if [ -x "$CK/bin/render-doc-index.sh" ]; then
  nice -n 10 "$CK/bin/render-doc-index.sh" "$CK/docs/notes" "$CK/docs/notes/INDEX.md" >/dev/null \
    || echo "$(STAMP) harness sync: docs/notes/INDEX.md could not be regenerated" >> "$LOG"
fi

[ -x "$CK/bin/verification-map-build.sh" ] || exit 0

KEY=
if k1=$(git -C "$CK" rev-parse --verify -q HEAD:docs/verification-map/entries) \
   && k2=$(git -C "$CK" rev-parse --verify -q HEAD:docs/verification-map/index) \
   && k3=$(git -C "$CK" rev-parse --verify -q HEAD:bin/verification-map-build.sh); then
  KEY="$k1 $k2 $k3"
fi
README="$CK/docs/verification-map/README.md"

if [ -n "$KEY" ] && [ -f "$README" ] && [ "$(cat "$KEYSTAMP" 2>/dev/null)" = "$KEY" ] \
   && dirty=$(git -C "$CK" status --porcelain -- docs/verification-map/entries \
                docs/verification-map/index bin/verification-map-build.sh) \
   && [ -z "$dirty" ]; then
  echo "$(STAMP) docs-sync: verification-map index skipped (inputs unchanged ${KEY:0:12})"
  exit 0
fi

T0=$(date +%s)
nice -n 10 "$CK/bin/verification-map-build.sh" --repo "$CK"
RC=$?
D=$(( $(date +%s) - T0 ))
if [ "$RC" = 0 ]; then
  echo "$(STAMP) harness sync: verification-map index built in ${D}s (inputs ${KEY:0:12})" >> "$LOG"
  if [ -n "$KEY" ] && [ -f "$README" ]; then
    printf '%s\n' "$KEY" > "$KEYSTAMP.tmp.$$" && mv -f "$KEYSTAMP.tmp.$$" "$KEYSTAMP"
  fi
else
  echo "$(STAMP) harness sync: verification-map index could not be regenerated rc=$RC after ${D}s (primers keep the last good copy, or render it ABSENT)" >> "$LOG"
fi
exit 0
