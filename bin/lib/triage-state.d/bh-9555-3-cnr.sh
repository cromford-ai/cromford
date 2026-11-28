# shellcheck shell=bash
# bin/lib/triage-state.d/bh-9555-3-cnr.sh — SOURCED by bin/lib/triage-state.sh.
# A could-not-read seam of the BH-9555 contract (BH-9594). # owner: BH-9555.3
#
# _ts_cnr_skip <session-out> <key>
#   Called first in _ts_record_run, for a triage shard only (one key). rc 0
#   means "this session's verdict is a could-not-read skip": the caller writes
#   no decision row and no hash stamp, so the next tick asks again. rc 1 means
#   "a decision": record it as today.
#
# THIS IS THE PLACEHOLDER: rc 1 always, so every verdict is recorded as before.
_ts_cnr_skip() {
  return 1
}
