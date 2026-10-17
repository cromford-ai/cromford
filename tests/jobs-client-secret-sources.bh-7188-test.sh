#!/bin/bash
# BH-7188 (TOC lever 5a): the jobs client finds HARNESS_SECRET (and the worker
# URL) off the hub: env, env/global.env, the macOS keychain item
# cromford/<NAME>, then a 0600 file named by HARNESS_SECRET_FILE. A secret
# found in the keychain or the file never reaches curl's argv and is never
# printed. A fake `security` and a fake `curl` stand in for both.
set -u
. "$(dirname "$0")/lib/scratch.sh" || exit 1
HERE=$(cd "$(dirname "$0")/.." && pwd)
scratch_install_closure bin/jobs-client.sh "$T" >/dev/null || { echo "FAIL: closure install"; exit 1; }
FB="$T/fakebin"; mkdir -p "$FB" "$T/env" "$T/logs" "$T/flags" "$T/home"
SECRET="fixture-sek-7188-0123456789abcdef"; URL="https://jobs.keychain.invalid"
# Fake security: answers the cromford items from files under $KC_DIR/<NAME>.
cat > "$FB/security" <<'SH'
#!/bin/bash
[ "$1" = find-generic-password ] || exit 1
svc=""; acct=""; w=0
while [ $# -gt 0 ]; do case "$1" in -s) svc=$2; shift;; -a) acct=$2; shift;; -w) w=1;; esac; shift; done
[ "$svc" = cromford ] && [ -r "$KC_DIR/$acct" ] || exit 44
[ "$w" = 1 ] && cat "$KC_DIR/$acct"
exit 0
SH
# Fake curl: logs argv, reads any -H @file into a headers log, answers 200.
cat > "$FB/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_ARGV"
last=""
while [ $# -gt 0 ]; do
  case "$1" in
    -H) shift
        case "$1" in @*) cat "${1#@}" >> "$CURL_HDRS";; *) printf '%s\n' "$1" >> "$CURL_HDRS";; esac ;;
  esac
  last=$1; shift
done
printf '%s\n' "$last" >> "$CURL_URLS"
printf '{"ok":true}\n200'
SH
chmod +x "$FB/security" "$FB/curl"
pass=0; fail=0
ok() { pass=$((pass+1)); }; bad() { fail=$((fail+1)); echo "FAIL: $1"; }
reset() {
  : > "$T/argv"; : > "$T/hdrs"; : > "$T/urls"; : > "$T/env/global.env"
  scratch_rm "$T/kc"; mkdir -p "$T/kc"
  scratch_rm "$T/secret-file"
}
# run VAR=val... : prints _jobs_req's stdout, then "|rc=N".
run() {
  env -i HOME="$T/home" PATH="$FB:$PATH" HARNESS="$T" HARNESS_DEPLOYMENT_FILE="$HERE/bin/lib/deployment.sh" \
    KC_DIR="$T/kc" CURL_ARGV="$T/argv" CURL_HDRS="$T/hdrs" CURL_URLS="$T/urls" "$@" \
    bash -c ". \"$T/bin/jobs-client.sh\" >/dev/null 2>&1; _jobs_req GET /api/x 2>/dev/null; echo \"|rc=\$?\""
}
# leaks <stdout> : names where the secret showed up (argv, stdout); empty if nowhere.
leaks() {
  if grep -qF "$SECRET" "$T/argv"; then echo argv; fi
  if [[ "$1" == *"$SECRET"* ]]; then echo stdout; fi
  return 0
}

# 1. keychain answers the secret -> bearer sent, no leak
reset; printf '%s\n' "$SECRET" > "$T/kc/HARNESS_SECRET"
out=$(run JOBS_URL=https://jobs.example.invalid)
[ "$out" = '{"ok":true}|rc=0' ] && ok || bad "keychain: _jobs_req did not succeed (got '$out')"
grep -qxF "authorization: Bearer $SECRET" "$T/hdrs" && ok || bad "keychain: bearer not sent"
[ -z "$(leaks "$out")" ] && ok || bad "keychain: secret leaked to $(leaks "$out")"

# 2. a 0600 HARNESS_SECRET_FILE does the same
reset; printf '%s\n' "$SECRET" > "$T/secret-file"; chmod 600 "$T/secret-file"
out=$(run JOBS_URL=https://jobs.example.invalid HARNESS_SECRET_FILE="$T/secret-file")
[ "$out" = '{"ok":true}|rc=0' ] && ok || bad "file: _jobs_req did not succeed (got '$out')"
grep -qxF "authorization: Bearer $SECRET" "$T/hdrs" && ok || bad "file: bearer not sent"
[ -z "$(leaks "$out")" ] && ok || bad "file: secret leaked to $(leaks "$out")"

# 3. a group/world-readable secret file is refused
reset; printf '%s\n' "$SECRET" > "$T/secret-file"; chmod 644 "$T/secret-file"
out=$(run JOBS_URL=https://jobs.example.invalid HARNESS_SECRET_FILE="$T/secret-file")
[ "$out" = '|rc=1' ] && ok || bad "0644 file should be refused (got '$out')"
[ ! -s "$T/hdrs" ] && ok || bad "0644 file: a request still went out"

# 4. env beats global.env beats keychain beats file
reset; printf 'fixture-other-kc\n' > "$T/kc/HARNESS_SECRET"
printf 'HARNESS_SECRET=fixture-from-global\n' > "$T/env/global.env"
run JOBS_URL=https://jobs.example.invalid >/dev/null
grep -qxF 'authorization: Bearer fixture-from-global' "$T/hdrs" && ok || bad "global.env should beat the keychain"
: > "$T/hdrs"; run JOBS_URL=https://jobs.example.invalid HARNESS_SECRET=fixture-from-env >/dev/null
grep -qxF 'authorization: Bearer fixture-from-env' "$T/hdrs" && ok || bad "env should beat global.env"
: > "$T/env/global.env"; : > "$T/hdrs"; printf 'fixture-from-file\n' > "$T/secret-file"; chmod 600 "$T/secret-file"
run JOBS_URL=https://jobs.example.invalid HARNESS_SECRET_FILE="$T/secret-file" >/dev/null
grep -qxF 'authorization: Bearer fixture-other-kc' "$T/hdrs" && ok || bad "keychain should beat the file"

# 5. nothing anywhere -> refuse, no request
reset
out=$(run JOBS_URL=https://jobs.example.invalid)
{ [ "$out" = '|rc=1' ] && [ ! -s "$T/hdrs" ]; } && ok || bad "no source should refuse without a request (got '$out')"

# 6. worker URL from the keychain when JOBS_URL is unset; a caller value wins
reset; printf '%s\n' "$SECRET" > "$T/kc/HARNESS_SECRET"; printf '%s\n' "$URL" > "$T/kc/JOBS_URL"
run >/dev/null
grep -qxF "$URL/api/x" "$T/urls" && ok || bad "keychain JOBS_URL not used (urls: $(cat "$T/urls"))"
: > "$T/urls"; run JOBS_URL=https://caller.invalid >/dev/null
grep -qxF 'https://caller.invalid/api/x' "$T/urls" && ok || bad "caller JOBS_URL should win"
echo "jobs-client-secret-sources.bh-7188-test: $pass pass, $fail fail"
[ "$fail" -eq 0 ]
