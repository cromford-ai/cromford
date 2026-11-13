#!/bin/bash
# tests/lead-authority-client-mode.bh-9625-test.sh — BH-9625: lead_authority_mode=client.
# project-3's decision maker must approve every project-3 change that members see or
# receive. Under client a PR that touches a lead_protected_paths glob is WITHHELD
# (la_decide rc 1) until a --source human MERGE stands on the head; a PR that
# touches none merges on the lane as under lane. Driven on the real
# bin/lib/lead-authority.sh and the real catalog/lead-protected-paths.seed.tsv:
# the stubbed worker answers no rows, so the seed floor is the glob set.
#   C1 client: src/app/member/x.tsx is withheld (rc 1, hit, member-facing reason)
#   C2 client: src/app/backstage/x.tsx only is not (rc 0, no protected path)
#   C3 client: a backstage + member PR is withheld; the hit names the member file
#   C4 client: every sender class is withheld (sms, email, reminders, cron, migration, comms),
#      and the CI and queue config (.github/**, .mergify.yml)
#   C5 lane (no row): the member PR is reported, not withheld (rc 0, hit)
#   C6 client: source human is rc 0; conductor is rc 0 only on a standing human MERGE
#   C7 client: a rename OUT of a member path counts (previous_filename)
#   C8 an unreadable mode row holds (rc 2)
#   C9 client on the GLOBAL key holds every repo (rc 2): client is per repo only
#   C10 lr_clear_context: a client repo clears on harness-verdict only, even on a human MERGE
#   C11 the real bin/lead-verdict.sh post --source human on a client repo: no https
#       link = refused before any POST; with one = posted
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-authority-client-mode.bh-9625-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

REPO=example-org/project-3
KEY=example-org.project-3
HEAD=aaaaaaaa11111111111111111111111111111111
mkdir -p "$T/catalog" "$T/set" "$T/tmp"
cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$T/catalog/"
export TMPDIR="$T/tmp"

# The seams lead-authority.sh calls: the jobs worker, the settings rows, GitHub
# REST and the verdict ledger. 0 network calls.
_jobs_req() { printf '{"rows":[]}'; }
setting_get() { [ -f "$T/set/$1" ] || return 2; [ -e "$T/set/$1.fail" ] && return 1; cat "$T/set/$1"; }
gh_rest() {
  case "$2" in
    *"/files?"*"page=1") cat "$T/files.json" ;;
    *"/files?"*) echo '[]' ;;
    *) printf '{"head":{"sha":"%s"}}' "$HEAD" ;;
  esac
}
vd_standing() { [ -f "$T/human" ] || return 1; printf 'MERGE\thuman\n'; }

HARNESS="$T"
# shellcheck source=bin/lib/lead-authority.sh
. "$DIR/bin/lib/lead-authority.sh" || { echo "FAIL: the lib did not load"; exit 1; }

files() { local a="" f; for f in "$@"; do a="${a:+$a,}{\"filename\":\"$f\"}"; done; printf '[%s]' "$a" > "$T/files.json"; }
mode() { if [ -n "${1:-}" ]; then printf '%s' "$1" > "$T/set/lead_authority_mode.$KEY"; else rm -f "$T/set/lead_authority_mode.$KEY"; fi; }
decide() { local rc=0; la_memo_reset; la_decide "$REPO" 7 "$HEAD" "${1:-lead}" || rc=$?; printf 'rc=%s hit=%s reason=%s' "$rc" "${LA_PROTECTED_HIT:-}" "$LA_REASON"; }

# C1
mode client; files src/app/member/x.tsx
R=$(decide)
case "$R" in "rc=1 hit=1 reason=touches member-facing paths: src/app/member/x.tsx; withheld until the client decision maker approves"*) ok ;; *) bad "C1 member path under client must be withheld: $R" ;; esac
echo "C1 $R"

# C2
files src/app/backstage/x.tsx
R=$(decide)
[ "$R" = "rc=0 hit= reason=no protected path" ] && ok || bad "C2 backstage-only PR must not be withheld: $R"
echo "C2 $R"

# C3
files src/app/backstage/a.tsx src/components/member/card.tsx
R=$(decide)
case "$R" in "rc=1 hit=1 reason=touches member-facing paths: src/components/member/card.tsx;"*) ok ;; *) bad "C3 mixed PR: $R" ;; esac

# C4
for f in src/lib/sms.ts src/lib/email.ts src/lib/event-reminders/dispatch.ts src/app/api/cron/event-reminders/route.ts \
         scripts/migrations/fr999-x.sql src/lib/comms/send.ts src/app/api/events/1/broadcast/route.ts src/lib/imessage/gathering.ts \
         'src/app/(checkout)/checkout/page.tsx' src/middleware.ts vercel.json .github/workflows/ci.yml .mergify.yml; do
  files "$f"; R=$(decide)
  case "$R" in rc=1\ hit=1*) ok ;; *) bad "C4 $f must be withheld: $R" ;; esac
done
for f in src/app/backstage/events/page.tsx src/components/backstage/x.tsx src/lib/db.ts src/components/ui/data-table.tsx README.md; do
  files "$f"; R=$(decide)
  [ "$R" = "rc=0 hit= reason=no protected path" ] && ok || bad "C4 $f is staff-only: $R"
done

# C5
mode ""; files src/app/member/x.tsx
R=$(decide)
case "$R" in "rc=0 hit=1 reason=touches protected paths: src/app/member/x.tsx; cleared to merge on the lead verdict (lead_authority_mode=lane)") ok ;; *) bad "C5 lane reports, not withholds: $R" ;; esac

# C6
mode client; files src/app/member/x.tsx
R=$(decide human); [ "$R" = "rc=0 hit= reason=a human verdict" ] && ok || bad "C6 source human: $R"
R=$(decide conductor); case "$R" in rc=1\ hit=1*) ok ;; *) bad "C6 conductor with no human MERGE: $R" ;; esac
: > "$T/human"
R=$(decide conductor); [ "$R" = "rc=0 hit= reason=a human verdict stands on ${HEAD:0:12}" ] && ok || bad "C6 conductor on a standing human MERGE: $R"
R=$(decide lead); case "$R" in rc=1\ hit=1*) ok ;; *) bad "C6 a lead MERGE never clears a member path: $R" ;; esac
rm -f "$T/human"

# C7
printf '[{"filename":"src/app/backstage/moved.tsx","previous_filename":"src/app/member/moved.tsx"}]' > "$T/files.json"
R=$(decide); case "$R" in rc=1\ hit=1*) ok ;; *) bad "C7 rename out of a member path: $R" ;; esac

# C8
mode client; : > "$T/set/lead_authority_mode.$KEY.fail"; files src/app/backstage/x.tsx
R=$(decide); case "$R" in rc=2*) ok ;; *) bad "C8 unreadable mode must hold: $R" ;; esac
rm -f "$T/set/lead_authority_mode.$KEY.fail"

# C9
mode ""; printf 'client' > "$T/set/lead_authority_mode"; files src/app/backstage/x.tsx
R=$(decide); case "$R" in rc=2*) ok ;; *) bad "C9 a global client row must hold: $R" ;; esac
rm -f "$T/set/lead_authority_mode"

# C10
. "$DIR/bin/lib/lead-required.sh"
lr_lead_stands() { return 0; }   # a human MERGE stands on the head
mode client; la_memo_reset; lr_clear_context "$REPO" 7 "$HEAD"
[ "$LR_CTX" = harness-verdict ] && ok || bad "C10 client repo clears on harness-verdict, got $LR_CTX"
mode ""; la_memo_reset; lr_clear_context "$REPO" 7 "$HEAD"
[ "$LR_CTX" = lead-verdict ] && ok || bad "C10 lane repo with a human MERGE keeps lead-verdict, got $LR_CTX"

# C11: the real CLI, with a fake gh (the head read) and a fake jobs worker.
H="$T/h"; FB="$T/fakebin"; mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/state" "$H/catalog" "$FB" "$T/tok" "$T/w"
scratch_install_closure bin/lead-verdict.sh "$H" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || exit 1
cp "$DIR/catalog/lead-protected-paths.seed.tsv" "$H/catalog/"
cp "$DIR/tests/lib/rest-emit.sh" "$FB/restpr"; chmod +x "$FB/restpr"
cat > "$FB/gh" <<GH
#!/bin/bash
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*) restpr OPEN "$HEAD" ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *) echo "" ;;
esac
exit 0
GH
cat > "$FB/curl" <<CURL
#!/bin/bash
m=GET; body=""; url=""; prev=""
for a in "\$@"; do
  case "\$prev" in -X) m="\$a" ;; --data-binary) body="\$a" ;; esac
  case "\$a" in http*) url="\$a" ;; esac
  prev="\$a"
done
p="\${url#https://jobs.test}"
printf '%s %s\n' "\$m" "\$p" >> "$T/w/log"
code=200; out='{}'
case "\$m \$p" in
  "GET /api/settings/lead_authority_mode.$KEY") out='{"setting":{"key":"lead_authority_mode.$KEY","value":"client"}}' ;;
  "GET /api/settings/"*) code=404; out='{"error":"no such setting"}' ;;
  "POST /api/verdicts") code=201; out=\$(jq -c '{verdict:(. + {id:21,created_at:"2026-11-12T00:00:00Z"})}' <<<"\$body") ;;
  "GET /api/lead-protected-paths"*) out='{"rows":[]}' ;;
  *) out='{"rows":[],"standing":null}' ;;
esac
printf '%s\n%s' "\$out" "\$code"
CURL
chmod +x "$FB/gh" "$FB/curl"
printf 'lead-test-token\n' > "$T/tok/lead"; printf 'human-test-token\n' > "$T/tok/human"; chmod 600 "$T/tok/"*
cli() { ( unset -f setting_get gh_rest _jobs_req vd_standing
          PATH="$FB:$PATH" HARNESS="$H" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 JOBS_BOX=t \
          LEAD_VERDICT_TOKEN_FILE="$T/tok/lead" HUMAN_VERDICT_TOKEN_FILE="$T/tok/human" GH_APP_TOKENS=0 \
          bash "$H/bin/lead-verdict.sh" "$@" ) >"$T/cli.out" 2>"$T/cli.err"; }
: > "$T/w/log"
cli post "$REPO" 7 "$HEAD" MERGE --source human --note "approved by Stephanie"; RC=$?
[ "$RC" = 1 ] && grep -q 'lead_authority_mode=client: a human MERGE needs --note' "$T/cli.err" && ok \
  || bad "C11 no https link must be refused (rc $RC): $(cat "$T/cli.err")"
grep -q '^POST /api/verdicts' "$T/w/log" && bad "C11 nothing may be posted without the link" || ok
: > "$T/w/log"
cli post "$REPO" 7 "$HEAD" MERGE --source human --note "approved by Stephanie: https://github.com/example-org/project-3/issues/1#c1"; RC=$?
grep -q '^POST /api/verdicts' "$T/w/log" && ok || bad "C11 with the link the verdict is posted (rc $RC): $(cat "$T/cli.err")"

echo "lead-authority-client-mode: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
