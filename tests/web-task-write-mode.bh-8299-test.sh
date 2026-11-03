#!/bin/bash
# tests/web-task-write-mode.bh-8299-test.sh — write mode of the web-task lane
# (BH-8299, slice C0: the BH-7599 write gate wired into the agent and the lane).
#
# WHAT THIS SUITE PINS:
#   A  the REAL agent (bin/web-task-agent.mjs) with a REAL chromium against a
#      fixture site on 127.0.0.1 that logs every request, a scripted decide
#      command and a stub bin/lib/web-human.sh (the S5 approval; it answers by
#      env and sends nothing): read mode refuses a Save click with S1's text
#      (A1); an approved write posts once with before and after shots (A2);
#      cancel and no answer write nothing (A3, A4); a payment page is refused in
#      both modes, by click and by type (A5, A5b, A5c); a script POST after the
#      write is refused (A6); a write whose request is refused is `unknown` and
#      stops the run (A7, A7b); typing asks no approval (A8); a bad --mode is an
#      error before the browser (A9); a write on a second host is refused
#      (A10); a bad WEB_TASK_WRITE_WAIT_S stops the run (A11).
#   L  the lane through the REAL bin/web-task.sh with a stub lib for GitHub,
#      settings, the model route and artifacts: `Mode: write` in the body is a
#      write run with the write opener and a `### Writes (1)` table whose shots
#      are the first published files (L1, L3); a quoted line, a line in a
#      comment and no line are read runs (L1b, L1c); the payment allow-list
#      row reaches the agent env, and a failed read is empty (L2, L2b); a
#      payment page has its own refusal line (L4); a write shot past the cap is
#      `none` (L5).
#   D  the decide rules: WRITE mode text for WEB_TASK_MODE=write (D1); any
#      other value prints the read-only text byte for byte (D2).
#
# No vendor call: the model is the scripted decide command, Telegram and the
# jobs worker are behind the stub web-human.sh, GitHub is the stub gh_rest.
# The only network is 127.0.0.1. Playwright resolves as in
# tests/web-task-lane.bh-7594-test.sh: missing under CI is installed or a FAIL,
# missing off CI is a SKIP of the browser cases.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/web-task-write-mode.bh-8299-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=""
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node is required"; exit 1; }

for f in "$DIR/bin/web-task-agent.mjs" "$DIR/bin/web-task.sh" "$DIR/bin/lib/web-task/decide.sh" \
         "$DIR/bin/lib/web-task/guards.mjs" "$DIR/bin/lib/web-write-step.mjs"; do
  [ -f "$f" ] && ok || bad "missing: ${f#"$DIR"/}"
done

# ═══════════════════════════════════════════════════════════════════════════
# D — the decide rules (no browser)
# ═══════════════════════════════════════════════════════════════════════════
# The read-only rules text as main printed it before BH-8299, byte for byte.
READ_RULES="$DIR/tests/fixtures/bh-8299/read-rules.txt"
[ -s "$READ_RULES" ] || { echo "FAIL: missing fixture ${READ_RULES#"$DIR"/}"; exit 1; }
rules() { ( unset WEB_TASK_MODE; [ -n "${1:-}" ] && export WEB_TASK_MODE="$1"; . "$DIR/bin/lib/web-task/decide.sh" || exit 9; _wt_rules ); }
D1=$(rules write)
grep -q '^You control a web browser in WRITE mode to do one task for a user\.' <<<"$D1" && ok || bad "D1: the write rules must open with WRITE mode: $(head -1 <<<"$D1")"
grep -qi 'read-only' <<<"$D1" && bad "D1: the write rules must carry no read-only line: $(grep -i 'read-only' <<<"$D1")" || ok
grep -qxF -- '- Each click on a submit, pay, delete, send, save or confirm control waits for a person to approve it. Make only the change the task asks for. Never retry a change that was cancelled or failed; use done and say what happened.' <<<"$D1" \
  && ok || bad "D1: the write rules must carry the approval rule line"
rules | cmp -s - "$READ_RULES" && ok || bad "D2: unset WEB_TASK_MODE must print the read-only rules byte for byte"
rules read | cmp -s - "$READ_RULES" && ok || bad "D2: WEB_TASK_MODE=read must print the read-only rules byte for byte"
rules WRITE | cmp -s - "$READ_RULES" && ok || bad "D2: WEB_TASK_MODE=WRITE (not exactly write) must print the read-only rules"

# ═══════════════════════════════════════════════════════════════════════════
# The fixture site: one per case, on its own port
# ═══════════════════════════════════════════════════════════════════════════
cat > "$T/site.mjs" <<'JS'
import { createServer } from "node:http";
import { appendFileSync, writeFileSync } from "node:fs";
const [, , log, portFile] = process.argv;
let theme = "fixture-theme-light";
const page = (t, b) => `<!doctype html><html><head><title>${t}</title></head><body>${b}</body></html>`;
const form = (action, label) => `<form method="post" action="${action}"><input name="theme" aria-label="theme" type="text"><button type="submit">${label}</button></form>`;
function route(m, p, body) {
  if (m === "GET" && p === "/settings") return [200, {}, page("Settings", `<p>Theme: ${theme}</p>${form("/settings", "Save")}`)];
  if (m === "POST" && p === "/settings") { theme = new URLSearchParams(body).get("theme") || theme; return [303, { location: "/settings" }, ""]; }
  if (m === "GET" && p === "/checkout") return [200, {}, page("Checkout", `<form method="post" action="/checkout"><input name="card" aria-label="card" autocomplete="cc-number" type="text"><button type="submit">Pay</button></form>`)];
  if (m === "POST" && p === "/checkout") return [200, {}, page("Paid", "<p>Paid</p>")];
  if (m === "GET" && p === "/beacon") return [200, {}, page("Beacon", `<p>beacon page</p><script>fetch("/beacon", {method: "POST", body: "x"}).catch(function () {});</script>`)];
  if (m === "POST" && p === "/beacon") return [200, {}, "ok"];
  if (m === "GET" && p === "/offform") return [200, {}, page("Off form", form("http://offlist.invalid/x", "Save"))];
  if (m === "GET" && p === "/form307") return [200, {}, page("Form 307", form("/r307", "Save"))];
  if (m === "POST" && p === "/r307") return [307, { location: "http://offlist.invalid/y" }, ""];
  return [404, {}, page("Not found", "not found")];
}
const server = createServer((req, res) => {
  let body = "";
  req.on("data", (c) => { body += c; });
  req.on("end", () => {
    const p = new URL(req.url, "http://127.0.0.1").pathname;
    const [code, hdrs, out] = route(req.method, p, body);
    appendFileSync(log, `${req.method} ${p} ${code}\n`);
    res.writeHead(code, { "content-type": "text/html", ...hdrs });
    res.end(out);
  });
});
server.listen(0, "127.0.0.1", () => { writeFileSync(portFile, String(server.address().port)); });
setTimeout(() => process.exit(0), 300000).unref();
JS
SITE_PIDS=()
trap 'for p in "${SITE_PIDS[@]}"; do kill "$p" 2>/dev/null; done; __scratch_exit_trap' EXIT
start_site() { # start_site <name> -> SPORT, SLOG, BASE
  SLOG="$T/site-$1.log"; : > "$SLOG"; rm -f "$T/port-$1"
  node "$T/site.mjs" "$SLOG" "$T/port-$1" >/dev/null 2>&1 &
  SITE_PIDS+=("$!")
  for _i in $(seq 1 100); do [ -s "$T/port-$1" ] && break; sleep 0.05; done
  SPORT=$(cat "$T/port-$1" 2>/dev/null)
  [ -n "$SPORT" ] || bad "fixture $1: the site did not start"
  BASE="http://127.0.0.1:$SPORT"
}
posts() { grep -c "^POST $1 " "$SLOG"; }

# ── playwright, resolved as the agent resolves it ───────────────────────────
PWROOT=""
for r in $(npm root -g 2>/dev/null) /usr/local/lib/node_modules /usr/lib/node_modules \
         $(ls -td "$HOME"/.npm/_npx/*/node_modules 2>/dev/null); do
  [ -d "$r" ] || continue
  if node -e 'require(require("module").createRequire(process.argv[1] + "/")("playwright") && process.argv[1] + "/playwright")' "$r" >/dev/null 2>&1; then
    PWROOT="$r"; break
  fi
done
if [ -z "$PWROOT" ] && [ -n "${CI:-}" ]; then
  PW_PIN=$(sed -nE 's/^ARG PLAYWRIGHT_VERSION=([0-9][0-9.]*)$/\1/p' "$DIR/ci-images/base/Dockerfile" | head -1)
  PW_CACHE="${RUNNER_TEMP:-${HOME:-/tmp}/.cache}/web-task-pw-$PW_PIN"
  if [ -n "$PW_PIN" ] && mkdir -p "$PW_CACHE" \
     && { [ -d "$PW_CACHE/node_modules/playwright" ] \
          || timeout 300 npm install --prefix "$PW_CACHE" --no-save --no-audit --no-fund "playwright@$PW_PIN" > "$T/pw-install.log" 2>&1; } \
     && { timeout 600 node "$PW_CACHE/node_modules/playwright/cli.js" install --with-deps chromium >> "$T/pw-install.log" 2>&1 \
          || timeout 600 node "$PW_CACHE/node_modules/playwright/cli.js" install chromium >> "$T/pw-install.log" 2>&1; }; then
    PWROOT="$PW_CACHE/node_modules"
  else
    echo "playwright install (pin '${PW_PIN:-none}'): $(tail -5 "$T/pw-install.log" 2>/dev/null | tr '\n' ' ')"
  fi
fi
HAVE_PW=0
if [ -n "$PWROOT" ]; then HAVE_PW=1
elif [ -n "${CI:-}" ]; then
  bad "playwright: CI is set and playwright resolves from no root, and the suite could not install it (the browser cases are this ticket's acceptance proof)"
else SKIP="A1-A11 L1-L5"; fi

# ── the scripted decide command: one action per call ───────────────────────
# A line's "@<name>" ref is the ref of the element with that name in the
# observation the agent wrote. Each call records the env the agent passed on.
cat > "$T/decide-stub.sh" <<'SH'
#!/bin/bash
obs="$1"; out="$3"
n=$(cat "$STUB_N" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_N"
[ -n "${STUB_ENV:-}" ] && printf 'ALLOW_PAYMENT_SITES=%s\nWEB_TASK_MODE=%s\nWEB_TASK_ISSUE=%s\n' \
  "${ALLOW_PAYMENT_SITES-unset}" "${WEB_TASK_MODE-unset}" "${WEB_TASK_ISSUE-unset}" > "$STUB_ENV"
line=$(sed -n "${n}p" "$STUB_SCRIPT")
[ -n "$line" ] || line=$(tail -1 "$STUB_SCRIPT")
case "$line" in
  *'"@'*)
    name=$(sed -E 's/.*"@([^"]*)".*/\1/' <<<"$line")
    ref=$(jq -r --arg n "$name" '[.elements[]? | select(.name == $n) | .ref][0] // "none"' "$obs")
    line=$(sed -E "s/\"@[^\"]*\"/\"$ref\"/" <<<"$line") ;;
esac
printf '%s\n' "$line" > "$out"
exit 0
SH
chmod +x "$T/decide-stub.sh"

# The stub of S5's wh_request_human: logs each ask, answers by WH_RC (0 =
# `done`, 3 = cancel, 4 = no answer in time), sends nothing anywhere.
write_human_stub() { # write_human_stub <bin/lib dir>
  cat > "$1/web-human.sh" <<'SH'
# shellcheck shell=bash
wh_request_human() {
  local a prev="" shot=""
  for a in "$@"; do [ "$prev" = --shot ] && shot=$a; prev=$a; done
  { printf 'ask'; printf ' [%s]' "$@"; [ -s "$shot" ] && printf ' shot-ok'; printf '\n'; } >> "$WH_LOG"
  case "${WH_RC:-0}" in
    0) printf done ;;
    3) echo 'web-human: cancelled' >&2; return 3 ;;
    4) echo 'web-human: no answer' >&2; return 4 ;;
    *) echo 'web-human: refused fixture-reason' >&2; return 1 ;;
  esac
}
SH
}

# The agent runs from a scratch tree, so its web-write-step.mjs finds the stub
# web-human.sh beside it.
HA="$T/ha"; mkdir -p "$HA"
for f in bin/web-task-agent.mjs bin/lib/web-task/guards.mjs bin/lib/web-write-step.mjs; do
  scratch_install_closure "$f" "$HA" >/dev/null || bad "setup: cannot install $f"
done
write_human_stub "$HA/bin/lib"

run_agent() { # run_agent <name> <mode|-> <script lines...> -> AD ARC; env: WH_RC, A_DOMAINS, A_ENV
  local name="$1" mode="$2"; shift 2
  AD="$T/run-$name"; scratch_rm "$AD"; mkdir -p "$AD"
  printf '%s\n' "$@" > "$T/script-$name"
  printf 'Change the theme on the fixture site.\n' > "$AD/task.md"
  : > "$AD/wh.log"; rm -f "$T/n-$name"
  local margs=(); [ "$mode" = - ] || margs=(--mode "$mode")
  # shellcheck disable=SC2086
  env HARNESS_TEST_SANDBOX=1 WEB_TASK_PW_ROOT="$PWROOT" WEB_TASK_PROJECT=proj WEB_TASK_ISSUE='o/r#7' \
    WH_LOG="$AD/wh.log" WH_RC="${WH_RC:-0}" STUB_SCRIPT="$T/script-$name" STUB_N="$T/n-$name" ${A_ENV:-} \
    timeout 150 node "$HA/bin/web-task-agent.mjs" --task "$AD/task.md" --out "$AD" --domains "${A_DOMAINS:-127.0.0.1}" \
      --max-steps 10 --max-s 120 --decide "$T/decide-stub.sh" "${margs[@]}" > "$AD/agent.out" 2> "$AD/agent.err"
  ARC=$?
}
rj() { jq -r "$@" "$AD/result.json" 2>/dev/null; }
outc() { rj "[.actions[] | select(.action == \"$1\") | .outcome][${2:-0}] // \"\""; }
asks() { grep -c '^ask ' "$AD/wh.log"; }

if [ "$HAVE_PW" = 1 ]; then
  SAVE_SCRIPT() { # the settings write: goto, type, click Save, done
    printf '%s\n' "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" \
      '{"action":"type","ref":"@theme","text":"fixture-dark"}' '{"action":"click","ref":"@Save"}' '{"action":"done","answer":"saved"}'
  }

  # A1 — read mode (no --mode): the Save click is refused with S1's text
  start_site a1
  mapfile -t S < <(SAVE_SCRIPT)
  run_agent a1 - "${S[@]}"
  [ "$(rj .status)" = done ] && [ "$ARC" = 0 ] && ok || bad "A1: status '$(rj .status)' rc $ARC (want done 0): $(rj .reason) $(head -c 300 "$AD/agent.err")"
  [ "$(outc click)" = "refused: 'Save' reads as a submit or write control (read-only run)" ] && ok || bad "A1: the click outcome is '$(outc click)'"
  [ "$(rj -c '[.refusals[] | {kind, label}]')" = '[{"kind":"control","label":"Save"}]' ] && ok || bad "A1: want one control refusal of Save, got $(rj -c .refusals)"
  [ "$(posts /settings)" = 0 ] && ok || bad "A1: want 0 POST /settings, got $(posts /settings)"
  [ "$(rj -c .writes)" = '[]' ] && [ "$(rj .mode)" = read ] && ok || bad "A1: want writes [] and mode read, got $(rj -c .writes) $(rj .mode)"
  [ "$(asks)" = 0 ] && ok || bad "A1: read mode must ask no approval, got $(asks)"

  # A2 — write mode, approved: exactly one POST, the write recorded done with shots
  start_site a2
  mapfile -t S < <(SAVE_SCRIPT)
  WH_RC=0 run_agent a2 write "${S[@]}"
  [ "$(rj .status)" = done ] && [ "$ARC" = 0 ] && ok || bad "A2: status '$(rj .status)' rc $ARC (want done 0): $(rj .reason) $(head -c 300 "$AD/agent.err")"
  [ "$(posts /settings)" = 1 ] && ok || bad "A2: want exactly 1 POST /settings, got $(posts /settings): $(tr '\n' ' ' < "$SLOG")"
  [ "$(rj -c '[.writes[] | {n, status}]')" = '[{"n":1,"status":"done"}]' ] && ok || bad "A2: want writes [{n:1,status:done}], got $(rj -c .writes)"
  [ "$(rj '.writes[0].action')" = "click 'Save'" ] && ok || bad "A2: the write action is '$(rj '.writes[0].action')'"
  [ -s "$AD/before-1.png" ] && [ -s "$AD/after-1.png" ] && [ "$(rj '.writes[0].before')" = "$AD/before-1.png" ] && [ "$(rj '.writes[0].after')" = "$AD/after-1.png" ] && ok \
    || bad "A2: before-1.png and after-1.png must exist and be the write's shots: $(rj -c '.writes[0]')"
  [ "$(asks)" = 1 ] && grep -q "^ask \[proj\] \[127.0.0.1\] \[approve\] \[Approve write 1 on 127.0.0.1: click 'Save'\] \[--shot\] \[$AD/before-1.png\] \[--issue\] \[o/r#7\] shot-ok$" "$AD/wh.log" && ok \
    || bad "A2: want one approve ask with the before shot and the issue, got: $(cat "$AD/wh.log")"
  [ "$(outc click)" = "ok: write 1 done (click 'Save')" ] && ok || bad "A2: the click outcome is '$(outc click)'"
  grep -q 'Theme: fixture-dark' "$AD/obs-04.json" 2>/dev/null && ok || bad "A2: the step after the write must show the saved theme"
  [ "$(rj .mode)" = write ] && ok || bad "A2: result.json mode '$(rj .mode)' (want write)"

  # A3 — cancel: nothing written, the run stops
  start_site a3
  mapfile -t S < <(SAVE_SCRIPT)
  WH_RC=3 run_agent a3 write "${S[@]}"
  [ "$(posts /settings)" = 0 ] && ok || bad "A3: a cancel must write nothing, got $(posts /settings) POST"
  [ "$(rj .status)" = error ] && [ "$ARC" = 1 ] && ok || bad "A3: status '$(rj .status)' rc $ARC (want error 1)"
  grep -q 'write 1 cancelled; nothing written' <<<"$(rj .reason)" && ok || bad "A3: reason '$(rj .reason)'"
  [ "$(rj -c .writes)" = '[]' ] && ok || bad "A3: want writes [], got $(rj -c .writes)"
  [ "$(rj '.steps')" = 3 ] && ok || bad "A3: the run must stop at the cancelled step 3, got $(rj .steps) steps"

  # A4 — no answer in time: nothing written
  start_site a4
  mapfile -t S < <(SAVE_SCRIPT)
  WH_RC=4 run_agent a4 write "${S[@]}"
  [ "$(posts /settings)" = 0 ] && [ "$(rj .status)" = error ] && grep -q 'nothing written' <<<"$(rj .reason)" && ok \
    || bad "A4: no answer must stop with nothing written, got $(posts /settings) POST, status $(rj .status), reason '$(rj .reason)'"

  # A5 — a payment page in write mode: refused, the run stops, no ask
  pay_script() { printf '%s\n' "{\"action\":\"goto\",\"url\":\"$BASE/checkout\"}" "$1" '{"action":"done","answer":"paid"}'; }
  start_site a5
  mapfile -t S < <(pay_script '{"action":"click","ref":"@Pay"}')
  run_agent a5 write "${S[@]}"
  [ "$(rj -c '[.refusals[] | select(.kind == "payment") | .url]')" = "[\"$BASE/checkout\"]" ] && ok || bad "A5: want one payment refusal at /checkout, got $(rj -c .refusals)"
  [ "$(rj .status)" = error ] && grep -q 'refused: payment page (127.0.0.1)' <<<"$(rj .reason)" && ok || bad "A5: status '$(rj .status)' reason '$(rj .reason)'"
  [ "$(posts /checkout)" = 0 ] && [ "$(asks)" = 0 ] && ok || bad "A5: want 0 POST /checkout and 0 asks, got $(posts /checkout) and $(asks)"
  # A5b — the same page in read mode is refused the same way
  start_site a5b
  mapfile -t S < <(pay_script '{"action":"click","ref":"@Pay"}')
  run_agent a5b read "${S[@]}"
  [ "$(rj '[.refusals[] | select(.kind == "payment")] | length')" = 1 ] && [ "$(rj .status)" = error ] && [ "$(posts /checkout)" = 0 ] && ok \
    || bad "A5b: read mode must refuse the payment page too, got $(rj -c .refusals) status $(rj .status)"
  # A5c — typing into the card field is refused (a type on a payment page)
  start_site a5c
  mapfile -t S < <(pay_script '{"action":"type","ref":"@card","text":"fixture-card-1"}')
  run_agent a5c write "${S[@]}"
  [ "$(rj '[.refusals[] | select(.kind == "payment")] | length')" = 1 ] && [ "$(rj .status)" = error ] && ok \
    || bad "A5c: a type on a payment page must be refused, got $(rj -c .refusals) status $(rj .status)"

  # A5d — an allow-listed payment host: the gate lets the page through
  start_site a5d
  mapfile -t S < <(pay_script '{"action":"type","ref":"@card","text":"fixture-card"}')
  A_ENV="ALLOW_PAYMENT_SITES=127.0.0.1" run_agent a5d write "${S[@]}"
  [ "$(rj '[.refusals[] | select(.kind == "payment")] | length')" = 0 ] && [ "$(rj .status)" = done ] && ok \
    || bad "A5d: ALLOW_PAYMENT_SITES=127.0.0.1 must let the type through, got $(rj -c .refusals) status $(rj .status) $(rj .reason)"

  # A6 — after the approved write, a script POST on the next page is refused
  start_site a6
  run_agent a6 write "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" '{"action":"click","ref":"@Save"}' \
    "{\"action\":\"goto\",\"url\":\"$BASE/beacon\"}" '{"action":"done","answer":"saved"}'
  [ "$(posts /settings)" = 1 ] && [ "$(posts /beacon)" = 0 ] && ok || bad "A6: want 1 POST /settings and 0 POST /beacon, got $(posts /settings) and $(posts /beacon)"
  [ "$(rj '[.refusals[] | select(.kind == "method" and .method == "POST" and (.url | endswith("/beacon")))] | length')" = 1 ] && ok \
    || bad "A6: want one method refusal of the beacon POST, got $(rj -c .refusals)"
  [ "$(rj -c '[.writes[] | .status]')" = '["done"]' ] && [ "$(rj .status)" = done ] && ok || bad "A6: want one done write and status done, got $(rj -c .writes) $(rj .status)"

  # A7 — the form posts to an off-list host: aborted, the write is unknown
  start_site a7
  run_agent a7 write "{\"action\":\"goto\",\"url\":\"$BASE/offform\"}" '{"action":"click","ref":"@Save"}' '{"action":"done","answer":"saved"}'
  [ "$(rj -c '[.writes[] | {n, status}]')" = '[{"n":1,"status":"unknown"}]' ] && ok || bad "A7: want writes [{n:1,status:unknown}], got $(rj -c .writes)"
  [ "$(rj .status)" = error ] && grep -q 'write 1 failed (.*); not retried' <<<"$(rj .reason)" && ok || bad "A7: status '$(rj .status)' reason '$(rj .reason)'"
  [ "$(rj '[.refusals[] | select(.kind == "method" and (.url | startswith("http://offlist.invalid")))] | length')" = 1 ] && ok \
    || bad "A7: want one method refusal of the off-list POST, got $(rj -c .refusals)"
  [ "$(asks)" = 1 ] && ok || bad "A7: want the approval asked once, got $(asks)"
  # A7b — a 307 from the site to an off-list host: the repost is refused
  start_site a7b
  run_agent a7b write "{\"action\":\"goto\",\"url\":\"$BASE/form307\"}" '{"action":"click","ref":"@Save"}' '{"action":"done","answer":"saved"}'
  [ "$(posts /r307)" = 1 ] && [ "$(rj -c '[.writes[] | .status]')" = '["unknown"]' ] && [ "$(rj .status)" = error ] && ok \
    || bad "A7b: want 1 POST /r307, an unknown write and status error, got $(posts /r307), $(rj -c .writes), $(rj .status)"
  [ "$(rj '[.refusals[] | select(.kind == "redirect" and (.to | startswith("http://offlist.invalid")))] | length')" = 1 ] && ok \
    || bad "A7b: want one redirect refusal to offlist.invalid, got $(rj -c .refusals)"

  # A8 — typing is never a write: no approval, nothing posted
  start_site a8
  run_agent a8 write "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" '{"action":"type","ref":"@theme","text":"fixture-dark"}' '{"action":"done","answer":"typed"}'
  [ "$(asks)" = 0 ] && [ "$(posts /settings)" = 0 ] && [ "$(outc type)" = "ok: typed 12 characters into 'theme'" ] && [ "$(rj -c .writes)" = '[]' ] && ok \
    || bad "A8: a type must ask nothing, got $(asks) asks, $(posts /settings) POST, outcome '$(outc type)', writes $(rj -c .writes)"

  # A9 — a bad --mode is an error before the browser starts
  start_site a9
  run_agent a9 bogus "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" '{"action":"done","answer":"x"}'
  [ "$(rj .status)" = error ] && [ "$ARC" = 1 ] && grep -q -- "--mode must be read or write, got 'bogus'" <<<"$(rj .reason)" && ok \
    || bad "A9: status '$(rj .status)' rc $ARC reason '$(rj .reason)'"
  ls "$AD"/obs-*.json >/dev/null 2>&1 && bad "A9: a bad --mode must take no step" || ok
  [ -s "$SLOG" ] && bad "A9: a bad --mode must make no request: $(cat "$SLOG")" || ok

  # A10 — the gate's site is the host of the first click or type: a write on a
  # second allowed host is refused, with no ask
  start_site a10
  A_DOMAINS="127.0.0.1,localhost" run_agent a10 write "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" \
    '{"action":"type","ref":"@theme","text":"fixture-dark"}' "{\"action\":\"goto\",\"url\":\"http://localhost:$SPORT/settings\"}" \
    '{"action":"click","ref":"@Save"}' '{"action":"done","answer":"no"}'
  [ "$(outc goto 1)" = "ok: at http://localhost:$SPORT/settings" ] && ok || bad "A10: the second host must load, got '$(outc goto 1)'"
  [ "$(outc click)" = "refused: this run writes on 127.0.0.1 only" ] && [ "$(asks)" = 0 ] && [ "$(posts /settings)" = 0 ] && ok \
    || bad "A10: want the write on localhost refused with no ask, got '$(outc click)', $(asks) asks, $(posts /settings) POST"

  # A11 — a bad WEB_TASK_WRITE_WAIT_S stops the run at the first click or type
  start_site a11
  A_ENV="WEB_TASK_WRITE_WAIT_S=5" run_agent a11 write "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" \
    '{"action":"type","ref":"@theme","text":"x"}' '{"action":"done","answer":"x"}'
  [ "$(rj .status)" = error ] && grep -q 'the write gate did not start (web-write: bad WEB_TASK_WRITE_WAIT_S)' <<<"$(rj .reason)" && ok \
    || bad "A11: status '$(rj .status)' reason '$(rj .reason)'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# L — the lane end to end through the real bin/web-task.sh
# ═══════════════════════════════════════════════════════════════════════════
HL="$T/hl"; mkdir -p "$HL/logs"
for f in bin/web-task.sh bin/web-task-agent.mjs bin/lib/web-task/guards.mjs bin/lib/web-write-step.mjs bin/lane-alert.sh; do
  scratch_install_closure "$f" "$HL" >/dev/null || bad "L: cannot install $f"
done
write_human_stub "$HL/bin/lib"
cat > "$HL/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in board_prefix) echo - ;; repo) echo o/r ;; esac
SH
chmod +x "$HL/bin/fleet-conf.sh"
cat > "$T/stub-lib.sh" <<'SH'
# shellcheck shell=bash
_stub_n() { local n; n=$(cat "$STUB_DIR/n.$1" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_DIR/n.$1"; echo "$n"; }
gh_rest() {
  local m="$1" p="$2" in="" a n; shift 2
  while [ $# -gt 0 ]; do
    case "$1" in --input) in="$2"; shift 2 ;; -F) a="$2"; shift 2; case "$a" in body=@*) in="${a#body=@}" ;; esac ;; *) shift ;; esac
  done
  printf '%s %s\n' "$m" "$p" >> "$STUB_DIR/gh.rec"
  case "$m $p" in
    "GET repos/o/r/issues/7") jq -nc --arg b "$STUB_BODY" '{number:7, title:"Mode: write", body:$b}' ;;
    "GET repos/o/r/issues/7/comments"*)
      case "$p" in *page=1|*page=1\&*) if [ -n "${STUB_COMMENTS:-}" ]; then cat "$STUB_COMMENTS"; else echo '[]'; fi ;; *) echo '[]' ;; esac ;;
    "POST repos/o/r/issues/7/comments")
      n=$(_stub_n post); cp "$in" "$STUB_DIR/posted-$n.md"
      jq -nc --arg n "$n" '{id:($n|tonumber), html_url:("https://github.com/o/r/issues/7#issuecomment-" + $n)}' ;;
    "POST repos/o/r/git/blobs") n=$(_stub_n blob); jq -nc --arg n "$n" '{sha:("blob" + $n)}' ;;
    "POST repos/o/r/git/trees") cp "$in" "$STUB_DIR/tree.json"; echo '{"sha":"tree1"}' ;;
    "POST repos/o/r/git/commits") echo '{"sha":"c0ffee0000000000000000000000000000000001"}' ;;
    "PATCH repos/o/r/git/refs/heads/"*) echo '{"object":{"sha":"c0ffee0000000000000000000000000000000001"}}' ;;
    "GET repos/o/r/git/ref/heads/"*) echo '{"object":{"sha":"c0ffee0000000000000000000000000000000001"}}' ;;
    "DELETE repos/o/r/issues/7/labels/ai-build") echo '[]' ;;
    *) return 75 ;;
  esac
}
setting_get() {
  case "$1" in
    lane.web-task.proj.allowed_domains) printf '127.0.0.1' ;;
    lane.web-task.proj.allow_payment_sites)
      [ "${STUB_PAY_RC:-0}" = 0 ] || return "$STUB_PAY_RC"
      [ -n "${STUB_PAY:-}" ] || return 2
      printf '%s' "$STUB_PAY" ;;
    *) return 2 ;;
  esac
}
model_env_or_route() { printf -v "$1" '%s' model-fixture-1; }
job_artifact_put() { :; }
SH
lane() { # lane <name> <body> <script lines...> -> LS LRC LP (the posted comment) LR (result.json)
  local name="$1" body="$2"; shift 2
  LS="$T/l-$name"; scratch_rm "$LS"; mkdir -p "$LS"; : > "$LS/gh.rec"; : > "$LS/wh.log"
  printf '%s\n' "$@" > "$T/lscript-$name"; rm -f "$T/ln-$name"
  env HARNESS="$HL" HARNESS_TEST_SANDBOX=1 WEB_TASK_TEST_LIB="$T/stub-lib.sh" WEB_TASK_DECIDE_CMD="$T/decide-stub.sh" \
    WEB_TASK_PW_ROOT="$PWROOT" WEB_TASK_POST_SLEEPS="0" PL_SLUG=o/r PL_STATE_DIR="$LS/state" STUB_DIR="$LS" \
    STUB_BODY="$body" STUB_COMMENTS="${L_COMMENTS:-}" STUB_PAY="${L_PAY:-}" STUB_PAY_RC="${L_PAY_RC:-0}" \
    STUB_SCRIPT="$T/lscript-$name" STUB_N="$T/ln-$name" STUB_ENV="$LS/agent.env" WH_LOG="$LS/wh.log" WH_RC=0 \
    WEB_TASK_MAX_SHOTS="${L_MAXSHOTS:-}" timeout 200 bash "$HL/bin/web-task.sh" 7 AB-7 job-fixture-9 proj > "$LS/out" 2> "$LS/err"
  LRC=$?
  LP="$LS/posted-1.md"
  LR=$(find "$LS/state" -name result.json 2>/dev/null | head -1)
}
lrj() { jq -r "$@" "$LR" 2>/dev/null; }
line_of() { grep -n -m1 -F -- "$1" "$LP" | cut -d: -f1; }

if [ "$HAVE_PW" = 1 ]; then
  WRITE_OPENER="I ran this web task in a browser in write mode. Each change waited for an approval."
  READ_OPENER="I ran this web task in a read-only browser. Here is what I found."

  # L1 + L3 — `Mode: write` in the body: a write run, the Writes table first
  start_site l1
  mapfile -t S < <(SAVE_SCRIPT)
  lane l1 $'Mode: write\nGo to the fixture settings and save the theme fixture-dark.' "${S[@]}"
  [ "$LRC" = 0 ] && [ -s "$LP" ] && ok || bad "L1: lane rc $LRC, comment $([ -s "$LP" ] && echo yes || echo none): $(head -c 400 "$LS/err") $(cat "$LS/out")"
  [ "$(head -1 "$LP" 2>/dev/null)" = "$WRITE_OPENER" ] && ok || bad "L1: the comment must open with the write sentence, got '$(head -1 "$LP" 2>/dev/null)'"
  [ "$(lrj .mode)" = write ] && grep -qx 'WEB_TASK_MODE=write' "$LS/agent.env" && grep -qxF 'WEB_TASK_ISSUE=o/r#7' "$LS/agent.env" && ok \
    || bad "L1: the agent must run --mode write with WEB_TASK_ISSUE o/r#7, got mode '$(lrj .mode)', env $(tr '\n' ' ' < "$LS/agent.env" 2>/dev/null)"
  [ "$(posts /settings)" = 1 ] && ok || bad "L1: want 1 POST /settings, got $(posts /settings)"
  WL=$(line_of '### Writes (1)'); DL=$(line_of '### What I did')
  [ -n "$WL" ] && [ -n "$DL" ] && [ "$WL" -lt "$DL" ] && ok || bad "L1: '### Writes (1)' must come before '### What I did' (lines '$WL' '$DL')"
  # L3 — the row parses back to {n, status}, the shot links are the published URLs
  ROW=$(grep -E '^\| [0-9]+ \| ' "$LP" 2>/dev/null)
  [ "$(awk -F' \\| ' '{ sub(/^\| /, ""); print $1 " " $3 }' <<<"$ROW")" = "1 done" ] && ok || bad "L3: the Writes row must parse back to '1 done', got: $ROW"
  grep -qxE "\| 1 \| click 'Save' \| done \| \[before\]\(https://github.com/o/r/blob/c0ffee0+1/before-1\.png\?raw=true\) \| \[after\]\(https://github.com/o/r/blob/c0ffee0+1/after-1\.png\?raw=true\) \|" <<<"$ROW" && ok \
    || bad "L3: the Writes row must link the published before and after shots, got: $ROW"
  [ "$(jq -r '[.tree[].path][0:2] | join(" ")' "$LS/tree.json" 2>/dev/null)" = "before-1.png after-1.png" ] && ok \
    || bad "L3: the write shots must be the first published files, got $(jq -c '[.tree[].path]' "$LS/tree.json" 2>/dev/null)"
  [ "$(grep -c '^POST repos/o/r/git/commits$' "$LS/gh.rec")" = 1 ] && ok || bad "L3: want ONE publish (1 commit), got $(grep -c 'git/commits' "$LS/gh.rec")"
  grep -qE '^!\[step [0-9]+\]\(https://github.com/o/r/blob/c0ffee0+1/shot-[0-9]+\.jpg\?raw=true\)$' "$LP" && ok \
    || bad "L3: the step images must follow the write shots in the URL list: $(grep '^!\[' "$LP")"
  [ "$(tail -1 "$LP")" = '<!-- web-task-result:AB-7 -->' ] && ok || bad "L1: a done write run must end with the result marker"

  # L1b — a quoted `> Mode: write` is a read run, byte for byte S1's opener
  start_site l1b
  mapfile -t S < <(SAVE_SCRIPT)
  lane l1b $'> Mode: write\nGo to the fixture settings and save the theme fixture-dark.' "${S[@]}"
  [ "$(head -1 "$LP" 2>/dev/null)" = "$READ_OPENER" ] && ok || bad "L1b: a quoted Mode line must give the read opener, got '$(head -1 "$LP" 2>/dev/null)'"
  [ "$(lrj .mode)" = read ] && [ "$(posts /settings)" = 0 ] && ok || bad "L1b: want mode read and 0 POST, got '$(lrj .mode)' and $(posts /settings)"
  grep -q '^### Writes' "$LP" && bad "L1b: a read run must print no Writes block" || ok
  grep -qxF -- "- step 3: a click on 'Save', which reads as a submit or write control" "$LP" && grep -qxF '### What the read-only guard refused' "$LP" && ok \
    || bad "L1b: the read refusal lines must be S1's: $(grep -A3 'guard refused' "$LP")"
  [ -s "$LS/wh.log" ] && bad "L1b: a read run must ask nothing: $(cat "$LS/wh.log")" || ok

  # L1c — `Mode: write` only in a comment (and in the title) is a read run
  start_site l1c
  printf '[{"body":"Mode: write"}]\n' > "$T/l1c-comments.json"
  L_COMMENTS="$T/l1c-comments.json" lane l1c 'Go to the fixture settings and read the theme.' \
    "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" '{"action":"done","answer":"light"}'
  [ "$(lrj .mode)" = read ] && grep -qx 'WEB_TASK_MODE=read' "$LS/agent.env" && [ "$(head -1 "$LP" 2>/dev/null)" = "$READ_OPENER" ] && ok \
    || bad "L1c: a Mode line in a comment or the title must be a read run, got '$(lrj .mode)', $(tr '\n' ' ' < "$LS/agent.env" 2>/dev/null)"

  # L2 — the payment allow-list row reaches the agent env
  start_site l2
  L_PAY="pay.example" lane l2 'Read the theme.' "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" '{"action":"done","answer":"light"}'
  grep -qx 'ALLOW_PAYMENT_SITES=pay.example' "$LS/agent.env" && ok || bad "L2: want ALLOW_PAYMENT_SITES=pay.example in the agent env, got $(tr '\n' ' ' < "$LS/agent.env" 2>/dev/null)"
  # L2b — a failed read is empty (every payment page refused), and it is logged
  start_site l2b
  L_PAY="pay.example" L_PAY_RC=75 lane l2b 'Read the theme.' "{\"action\":\"goto\",\"url\":\"$BASE/settings\"}" '{"action":"done","answer":"light"}'
  grep -qx 'ALLOW_PAYMENT_SITES=' "$LS/agent.env" && grep -q 'allow_payment_sites unreadable (rc 75)' "$HL/logs/web-task.log" && ok \
    || bad "L2b: a failed row read must give an empty ALLOW_PAYMENT_SITES and a log line, got $(tr '\n' ' ' < "$LS/agent.env" 2>/dev/null)"

  # L4 — a payment page in a write run: its refusal line, Writes (0), not done
  start_site l4
  lane l4 $'Mode: write\nPay on the fixture checkout.' "{\"action\":\"goto\",\"url\":\"$BASE/checkout\"}" '{"action":"click","ref":"@Pay"}' '{"action":"done","answer":"paid"}'
  [ "$(head -1 "$LP" 2>/dev/null)" = "I ran this web task in a browser in write mode, but it did not finish. Each change waited for an approval." ] && ok \
    || bad "L4: a stopped write run must open with the did-not-finish write sentence, got '$(head -1 "$LP" 2>/dev/null)'"
  grep -qxF -- "- step 2: a payment page, refused in every mode: '$BASE/checkout'" "$LP" && grep -qxF '### What the guard refused' "$LP" && ok \
    || bad "L4: want the payment refusal line under 'What the guard refused': $(grep -A3 'guard refused' "$LP")"
  grep -qxF '### Writes (0)' "$LP" && grep -qxF 'No write was made.' "$LP" && [ "$(posts /checkout)" = 0 ] && ok \
    || bad "L4: want 'Writes (0)' and 'No write was made.' and 0 POST, got $(posts /checkout) POST: $(grep -A2 'Writes' "$LP")"

  # L5 — WEB_TASK_MAX_SHOTS=1: the before shot is published, the after shot is none
  start_site l5
  mapfile -t S < <(SAVE_SCRIPT)
  L_MAXSHOTS=1 lane l5 $'Mode: write\nSave the theme fixture-dark.' "${S[@]}"
  grep -qxE "\| 1 \| click 'Save' \| done \| \[before\]\(https://github.com/o/r/blob/c0ffee0+1/before-1\.png\?raw=true\) \| none \|" "$LP" && ok \
    || bad "L5: a write shot past the cap must be none, got: $(grep -E '^\| 1 ' "$LP")"
  grep -qxF 'The step screenshots are past the cap of 1 (WEB_TASK_MAX_SHOTS). The write screenshots are in the Writes table.' "$LP" && ! grep -q '^!\[step' "$LP" && ok \
    || bad "L5: with the cap used by the write shots, the screenshot section must say so: $(grep -A2 '### Screenshots' "$LP")"
fi

[ -n "$SKIP" ] && echo "SKIP: $SKIP (playwright not found; CI is not set)"
echo "web-task-write-mode.bh-8299: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
