#!/bin/bash
# tests/lib/tracker-contract-c13.bh-7922.sh — contract cases C13 (tracker_create,
# the new form) and C14 (tracker_search), BH-7922. Adapter-agnostic, like
# tests/lib/tracker-contract-c12.bh-7920.sh; tests/tracker-create-search.bh-7922-test.sh
# runs both once per adapter.
#
#   tracker_contract_c13 <adapter>
#   tracker_contract_c14 <adapter>
#
# The suite provides, per adapter (the name with - as _):
#   tc13_setup_<a>   loads the adapter and its context, resets the stub, sets
#                    C13_PARENT, C13_BLOCKER (refs the stub knows), C13_LABEL
#                    (empty = no --label: the board takes no labels)
#   tc14_setup_<a>   the same, and seeds the stub's search answer with four
#                    rows WHATEVER the request asks: two titles that hold the
#                    word "revenue" (C14_MATCH, space-separated ids), one row
#                    whose body only holds it, one other row
# and these stub hooks:
#   c13_writes       the write requests the stub received, one per line
#   c13_creates      how many create requests the stub received
#   c13_create_title the title of the newest create request
#   c13_create_body  the body text of the newest create request (footers incl.)
#   c14_saw          rc 0 when the stub saw the adapter's own search request
# Counts go into TC_PASS / TC_FAIL.

TC_PASS=${TC_PASS:-0}; TC_FAIL=${TC_FAIL:-0}
_c13_ok()  { TC_PASS=$((TC_PASS+1)); }
_c13_bad() { TC_FAIL=$((TC_FAIL+1)); echo "FAIL [${C13_A:-?}] $1"; }

tracker_contract_c13() {
  local C13_A="$1" out rc tf bf n body
  local -a fl
  "tc13_setup_${C13_A//-/_}" || { _c13_bad "C13 setup failed"; return 1; }
  tf=$(mktemp "${TMPDIR:-/tmp}/c13-title.XXXXXX"); bf=$(mktemp "${TMPDIR:-/tmp}/c13-body.XXXXXX")
  printf 'Fix the revenue total\n' > "$tf"
  printf 'The revenue total double counts refunds.\n' > "$bf"
  fl=(--parent "$C13_PARENT" --blocked-by "$C13_BLOCKER")
  [ -n "${C13_LABEL:-}" ] && fl+=(--label "$C13_LABEL")

  # (d) first: a dry run sends no write and prints DRYRUN lines, no object
  out=$(TRK_DRY=1 tracker_create "$tf" "$bf" "${fl[@]}"); rc=$?
  [ "$rc" = 0 ] && _c13_ok || _c13_bad "C13(d) a dry run is rc 0 (got $rc)"
  grep -q '^DRYRUN ' <<<"$out" && ! grep -qv '^DRYRUN ' <<<"$out" && _c13_ok || _c13_bad "C13(d) a dry run prints DRYRUN lines only: [$out]"
  [ "$(c13_writes | grep -c .)" = 0 ] && _c13_ok || _c13_bad "C13(d) a dry run wrote: $(c13_writes)"

  # (a) the create: rc 0, the normalized object plus relationErrors
  out=$(tracker_create "$tf" "$bf" "${fl[@]}"); rc=$?
  [ "$rc" = 0 ] && _c13_ok || _c13_bad "C13(a) create rc 0 (got $rc)"
  printf '%s' "$out" | jq -e --arg t "Fix the revenue total" '
      type == "object" and (.id | type == "string" and length > 0) and (.key | type == "string" and length > 0)
      and .title == $t and .state == "open" and has("labels") and has("url") and has("body")
      and .relationErrors == []' >/dev/null 2>&1 \
    && _c13_ok || _c13_bad "C13(a) stdout is the normalized ticket with relationErrors []: $out"
  C13_OUT="$out"

  # (b) exactly one create, with the title and the body + each footer once
  n=$(c13_creates)
  [ "$n" = 1 ] && _c13_ok || _c13_bad "C13(b) exactly one create request (got $n)"
  [ "$(c13_create_title)" = "Fix the revenue total" ] && _c13_ok || _c13_bad "C13(b) the create title: $(c13_create_title)"
  body=$(c13_create_body)
  grep -qF 'The revenue total double counts refunds.' <<<"$body" && _c13_ok || _c13_bad "C13(b) the body is sent: [$body]"
  [ "$(grep -cx "Part of $C13_PARENT" <<<"$body")" = 1 ] && _c13_ok || _c13_bad "C13(b) 'Part of $C13_PARENT' once: [$body]"
  [ "$(grep -cx "Blocked-by: $C13_BLOCKER" <<<"$body")" = 1 ] && _c13_ok || _c13_bad "C13(b) 'Blocked-by: $C13_BLOCKER' once: [$body]"

  # a bad argument: rc 1, one stderr line, nothing sent
  n=$(c13_writes | grep -c .)
  out=$(tracker_create "$tf" "$bf" --parent 12 2>&1 >/dev/null); rc=$?
  [ "$rc" = 1 ] && [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] && _c13_ok || _c13_bad "C13 a bare 12 parent is rc 1 with one stderr line (rc=$rc err=[$out])"
  [ "$(c13_writes | grep -c .)" = "$n" ] && _c13_ok || _c13_bad "C13 a refused argument sent a write"
  rm -f "$tf" "$bf"
  return 0
}

tracker_contract_c14() {
  local C13_A="$1" out rc want
  "tc14_setup_${C13_A//-/_}" || { _c13_bad "C14 setup failed"; return 1; }
  out=$(tracker_search revenue); rc=$?
  [ "$rc" = 0 ] && _c13_ok || _c13_bad "C14 search rc 0 (got $rc)"
  want=$(printf '%s\n' $C14_MATCH | jq -Rsc 'split("\n") | map(select(. != "")) | sort')
  [ "$(printf '%s' "$out" | jq -c '[.[].id] | sort' 2>/dev/null)" = "$want" ] \
    && _c13_ok || _c13_bad "C14 exactly the two title matches $want: $out"
  printf '%s' "$out" | jq -e 'all(.[]; has("id") and has("key") and has("title") and has("status") and has("state")
      and has("labels") and has("waitingOn") and has("triageVerdict") and has("url") and has("updatedAt") and has("commentCount"))' >/dev/null 2>&1 \
    && _c13_ok || _c13_bad "C14 every row has the tracker_list row keys: $out"
  c14_saw && _c13_ok || _c13_bad "C14 the stub did not see the adapter's own search request"
  [ "$(c13_writes | grep -c .)" = 0 ] && _c13_ok || _c13_bad "C14 a search wrote: $(c13_writes)"
  return 0
}
