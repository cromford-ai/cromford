#!/bin/bash
# tests/lib/claude-cli-pin-fakes.sh — BH-9911 test fakes, sourced (never run) by
# tests/claude-cli-pin.bh-9911-test.sh and tests/claude-cli-smoke.bh-9911-test.sh.
#
# ccpf_new <dir>  builds, under <dir>:
#   fakebin/curl   a file-backed fake of the harness-jobs worker. It answers the
#                  routes the BH-9911 scripts call, in the jobs client's wire
#                  format (payload, newline, HTTP status):
#                    GET  /api/settings/<key>   <dir>/w/settings/<key>, else 404
#                    PUT  /api/settings         writes <dir>/w/settings/<key>
#                    POST /api/claude-cli/smoke appends rows (PK dedup) to
#                                               <dir>/w/smoke.jsonl
#                    GET  /api/claude-cli/smoke box + version filter, at DESC
#                    GET  /api/model-routes/<r> <dir>/w/routes/<r> as rung 0
#                    GET  /api/boxes            <dir>/w/boxes.json
#                    anything else              {} 200
#                  Every request is one line in <dir>/w/req.log. Fault seams
#                  (files, so a child process sees them): w/down (every request
#                  fails at transport), w/fail-smoke-post, w/fail-smoke-get,
#                  w/fail-boxes, w/fail-settings-put; w/refuse-smoke-post
#                  answers the smoke POST 400 (a row the worker refuses).
#   fakebin/npm    prints <dir>/w/npm-view (npm view only)
# ccpf_set <dir> <key> <value>  seeds a settings row; ccpf_get <dir> <key>.
# ccpf_row <dir> <box> <version> <run_id> <step> <ok> <at>  seeds a smoke row.
# Zero network: the fake curl never opens a socket.

ccpf_new() {
  local d="$1"
  mkdir -p "$d/fakebin" "$d/w/settings" "$d/w/routes"
  : > "$d/w/smoke.jsonl"; : > "$d/w/req.log"
  echo '{"boxes":[]}' > "$d/w/boxes.json"
  cat > "$d/fakebin/curl" <<'CURL'
#!/bin/bash
W="$CCPF_W"
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) METHOD="$2"; shift 2 ;; --data-binary) BODY="$2"; shift 2 ;; *) shift ;; esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}") ;; esac
P="${URL#*://*/}"; P="/${P}"
echo "$METHOD $P" >> "$W/req.log"
[ -e "$W/down" ] && exit 7
reply() { printf '%s\n%s\n' "$1" "$2"; exit 0; }
case "$METHOD $P" in
  "GET /api/settings/"*)
    k="${P#/api/settings/}"
    [ -f "$W/settings/$k" ] || reply '{}' 404
    reply "$(jq -nc --arg v "$(cat "$W/settings/$k")" '{setting:{value:$v}}')" 200 ;;
  "PUT /api/settings")
    [ -e "$W/fail-settings-put" ] && reply '{"error":"refused"}' 500
    k=$(jq -r '.key' <<<"$BODY"); v=$(jq -r '.value' <<<"$BODY")
    printf '%s' "$v" > "$W/settings/$k"; echo "$k=$v" >> "$W/settings-put.log"
    reply '{"ok":true}' 200 ;;
  "POST /api/claude-cli/smoke")
    [ -e "$W/fail-smoke-post" ] && reply '{"error":"down"}' 503
    [ -e "$W/refuse-smoke-post" ] && reply '{"error":"row 0: detail <= 300 chars"}' 400
    n=0
    while IFS= read -r r; do
      key=$(jq -r '[.box,.version,.run_id,.step]|join("|")' <<<"$r")
      grep -qF "\"_k\":\"$key\"" "$W/smoke.jsonl" && continue
      jq -c --arg k "$key" '. + {_k:$k}' <<<"$r" >> "$W/smoke.jsonl"; n=$((n+1))
    done < <(jq -c '.rows[]' <<<"$BODY")
    reply "{\"inserted\":$n}" 200 ;;
  "GET /api/claude-cli/smoke?"*)
    [ -e "$W/fail-smoke-get" ] && reply '{"error":"down"}' 503
    q="${P#*\?}"; box=""; ver=""; lim=100
    IFS='&' read -r -a kv <<<"$q"
    for x in "${kv[@]}"; do case "$x" in box=*) box="${x#box=}" ;; version=*) ver="${x#version=}" ;; limit=*) lim="${x#limit=}" ;; esac; done
    reply "$(jq -sc --arg b "$box" --arg v "$ver" --argjson l "$lim" \
      '{rows: ([.[] | select(.box==$b and .version==$v) | del(._k)] | sort_by(.at) | reverse | .[:$l])}' "$W/smoke.jsonl")" 200 ;;
  "GET /api/model-routes/"*)
    role="${P#/api/model-routes/}"; role="${role%%\?*}"
    [ -f "$W/routes/$role" ] || reply '{"ladder":[]}' 200
    reply "$(jq -nc --arg m "$(cat "$W/routes/$role")" '{ladder:[{position:0,model:$m,runner:"claude"}]}')" 200 ;;
  "GET /api/boxes")
    [ -e "$W/fail-boxes" ] && reply '{"error":"down"}' 503
    reply "$(cat "$W/boxes.json")" 200 ;;
esac
reply '{}' 200
CURL
  cat > "$d/fakebin/npm" <<'NPM'
#!/bin/bash
echo "npm $*" >> "$CCPF_W/npm.log"
[ "$1" = view ] && { cat "$CCPF_W/npm-view" 2>/dev/null; exit "$(cat "$CCPF_W/npm-rc" 2>/dev/null || echo 0)"; }
exit 0
NPM
  chmod +x "$d/fakebin/curl" "$d/fakebin/npm"
}
ccpf_set() { printf '%s' "$3" > "$1/w/settings/$2"; }
ccpf_get() { cat "$1/w/settings/$2" 2>/dev/null; }
ccpf_row() { # ccpf_row <dir> <box> <version> <run_id> <step> <ok> <at>
  jq -nc --arg b "$2" --arg v "$3" --arg r "$4" --arg s "$5" --argjson ok "$6" --arg at "$7" \
    '{box:$b,version:$v,run_id:$r,step:$s,ok:$ok,rc:0,ms:10,detail:"",at:$at,_k:([$b,$v,$r,$s]|join("|"))}' >> "$1/w/smoke.jsonl"
}
