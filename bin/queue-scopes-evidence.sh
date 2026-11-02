#!/bin/bash
# bin/queue-scopes-evidence.sh <repo> — the conductor's Mergify scopes PUT
# results for one repo, read from the hub's own log. The live-probe lane runs
# it as `queue-scopes-uploads` (catalog/live-probes.tsv), so a queue_mode flip
# PR can cite a real upload answer (BH-8052, the BH-1000 gating rule).
#
#   <repo>  the conf basename: config/mergify/repos/<repo>.conf (no `/`)
#
# READS ONLY: the conf (slug=, queue_mode=), logs/merge-conductor.log (the
# `PARTITION <slug>#<n>: scopes uploaded on …` and `scopes not uploaded on …`
# lines bin/lib/queue-partition.sh qp_enqueue_step writes) and the count of
# scopes ledger files. It never reads the key, calls the network or writes.
#
# Output: line 1
#   queue-scopes <slug>: queue_mode=<m> ok=<n> failed=<k> ledger=<j> newest=<v>
# then every result line, in log order. <v> is the newest result line:
#   ok           an `HTTP 2xx` upload, or a ledger hit (`already uploaded`)
#                with an `HTTP 2xx` line somewhere in the log
#   ok-unproven  a ledger hit, and no `HTTP 2xx` line in the log
#   failed       `scopes not uploaded`, or an upload line with any other answer
#   none         no result line for this slug
# Exit: 0 newest=ok; 1 any other newest; 2 a bad argument, an unreadable
# conf or log, or a conf with no slug= line.
set -uo pipefail
H="${HARNESS:-$(cd "$(dirname "$0")/.." && pwd)}"
repo="${1:-}"
[[ "$repo" =~ ^[A-Za-z0-9._-]+$ ]] && [[ "$repo" != *..* ]] \
  || { echo "queue-scopes: usage: $0 <repo> (a conf basename, no /)"; exit 2; }
conf="$H/config/mergify/repos/$repo.conf"
log="$H/logs/merge-conductor.log"
[ -r "$conf" ] || { echo "queue-scopes: conf $conf unreadable"; exit 2; }
slug=$(sed -n 's/^slug=\([^[:space:]]*\)[[:space:]]*$/\1/p' "$conf" | tail -1)
[ -n "$slug" ] || { echo "queue-scopes: $conf has no slug= line"; exit 2; }
[ -r "$log" ] || { echo "queue-scopes: log $log unreadable"; exit 2; }
qmode=$(sed -n 's/^queue_mode=\([a-z]*\)[[:space:]]*$/\1/p' "$conf" | tail -1)
ledger=0
for f in "$H/state/merge-conductor/queue-partition/${slug//\//_}_"*; do [ -f "$f" ] && ledger=$((ledger + 1)); done

# Each result line is "<stamp> PARTITION <slug>#<n>: scopes [not ]uploaded on
# <head12> (<why>)…". The slug is matched as a fixed string, then `#<digits>:`.
res=$(awk -v p="PARTITION $slug#" '
  { i = index($0, p); if (!i) next
    rest = substr($0, i + length(p))
    if (rest !~ /^[0-9]+: scopes (not )?uploaded on /) next
    if (rest ~ /^[0-9]+: scopes not uploaded on /) k = "failed"
    else if (rest ~ /^[0-9]+: scopes uploaded on [0-9a-f]+ \(HTTP 2[0-9][0-9]\)$/) k = "ok2xx"
    else if (rest ~ /^[0-9]+: scopes uploaded on [0-9a-f]+ \(already uploaded\)$/) k = "ledger"
    else k = "failed"
    print k "\t" $0 }' "$log")

okn=0; failn=0; has2xx=0; last=none
while IFS=$'\t' read -r k _; do
  case "$k" in
    ok2xx) okn=$((okn + 1)); has2xx=1; last=ok ;;
    ledger) okn=$((okn + 1)); last=ledger ;;
    failed) failn=$((failn + 1)); last=failed ;;
  esac
done <<<"$res"
[ "$last" = ledger ] && { [ "$has2xx" = 1 ] && last=ok || last=ok-unproven; }

echo "queue-scopes $slug: queue_mode=${qmode:-none} ok=$okn failed=$failn ledger=$ledger newest=$last"
[ -n "$res" ] && cut -f2- <<<"$res"
[ "$last" = ok ]
