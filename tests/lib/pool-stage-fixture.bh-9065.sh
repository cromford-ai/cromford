#!/bin/bash
# tests/lib/pool-stage-fixture.bh-9065.sh — a scratch harness that drives bin/fly-pool.sh
# for the BH-9065 stage hand-off and soft-cap suites: spawn AND reap, with a
# fake fly that records each pushed job.json and answers each RESULT. Sourced
# after tests/lib/scratch.sh (needs $T, $DIR, $REG); never run on its own.
# ══ the driven pool (scaffold of tests/fly-pool-vm-size.bh-8318, plus a reap) ══
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/locks" "$H/env" "$H/fly" \
         "$H/state/fly" "$H/state/fly-pool/project-5" \
         "$H/state/build-queue/project-5" "$H/state/remote-results/project-5" \
         "$H/state/pool/project-5" "$H/state/build-notes/project-5" \
         "$H/state/vercel-deploys" "$H/builds" "$T/fakebin" "$T/res" "$T/brief" "$T/pushed"
printf 'FLY_API_TOKEN_project-5=tok-fixture-fly\n' > "$H/env/fly.env"
: > "$H/env/global.env"
printf 'project-5 example-org/project-5 - - 0 boxa 192.0.2.9\n' > "$H/fleet.conf"
printf '3\n' > "$H/flags/fly-pool-project-5"
printf 'pool-project-5\n' > "$H/flags/fly-pool-app-project-5"
printf '{"app":"pool-project-5"}\n' > "$H/state/fly/project-5.json"
printf 'registry.fly.io/pool-project-5:deploy-01\n' > "$H/state/fly/project-5.image"
cat > "$H/bin/lib/pool-account.sh" <<'PA'
#!/bin/bash
pool_account_lease() { echo "name=default reason=unarmed"; }
pool_account_rebind() { return 0; }
pool_account_release() { return 0; }
pool_account_others_ok() { return 1; }
pool_account_prune() { :; }
pool_account_armed() { return 1; }
pool_account_cooldown() { :; }
pool_account_unpin() { :; }
PA
cp "$DIR/bin/result-prefix-ok.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/alert-line.sh" "$DIR/bin/fly-envbundle.sh" "$H/bin/"
scratch_install_closure bin/fly-pool.sh "$H" >/dev/null || { echo "closure install of bin/fly-pool.sh failed"; exit 1; }
# The queue-row recorders QROW calls, as the bh-5025 suite stubs them.
cat > "$H/bin/jobs-client.sh" <<'JC'
queue_done() { printf 'done\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >> "$HARNESS/qrow.log"; return 0; }
queue_put()  { printf 'put\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" "${6:-}" >> "$HARNESS/qrow.log"; return 0; }
JC
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$T/fakebin/timeout"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/sleep"
cat > "$T/fakebin/ssh" <<'SSH'
#!/bin/bash
printf '===GLOBAL===\n'
printf 'CLAUDE_CODE_OAUTH_TOKEN=fixture-claude-base\nHARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.invalid\n'
printf 'OPENROUTER_API_KEY=fixture-or\nGH_TOKEN=fixture-pat\n'
printf '===PROJECT===\n'
printf 'BOARD_TOKEN=fixture-board\n'
exit 0
SSH
# fly: every call logged; a pushed job.json is decoded into $T/pushed/<mid>;
# the RESULT and brief.md of a machine come from $T/res/<mid> and $T/brief/<mid>.
cat > "$T/fakebin/fly" <<FLY
#!/bin/bash
echo "fly \$*" >> "$T/fly.txt"
M=""; C=""; prev=""
for a in "\$@"; do [ "\$prev" = --machine ] && M="\$a"; [ "\$prev" = -C ] && C="\$a"; prev="\$a"; done
U=\$(printf '%s' "\$C" | sed 's/\\\\\\(.\\)/\\1/g')
case "\$*" in
  *"secrets list"*) echo '[{"Name":"HBUNDLE_G_HARNESS_SECRET","Digest":"d1"},{"Name":"HBUNDLE_SYNCED_AT","Digest":"d2"}]' ;;
  *"secrets import"*) cat > /dev/null ;;
  *"machine status"*) echo "State: started" ;;
  *"machines list"*) echo '[]' ;;
  *"machine run"*) printf 'Machine ID: 1234567890abcd\n' ;;
  *"ssh console"*)
    if [[ "\$U" =~ echo\ ([A-Za-z0-9+/=]+)\ \|\ base64\ -d\ \>\ /run/harness/job\.json ]]; then
      printf '%s' "\${BASH_REMATCH[1]}" | base64 -d > "$T/pushed/\$M"
    fi
    case "\$U" in
      *"head -1 /run/harness/RESULT"*) [ -f "$T/res/\$M" ] && head -1 "$T/res/\$M" ;;
      *"base64 -w0 /run/harness/RESULT"*) [ -f "$T/res/\$M" ] && base64 -w0 "$T/res/\$M" ;;
      *"base64 -w0 "*"/brief.md"*) [ -f "$T/brief/\$M" ] && base64 -w0 "$T/brief/\$M" ;;
    esac ;;
esac
exit 0
FLY
cat > "$T/fakebin/gh" <<'GH'
#!/bin/bash
for a in "$@"; do case "$a" in issue) exit 0 ;; esac; done
if [[ "$*" == *"--paginate"*"issues"*"comments"* ]]; then echo '[]'; exit 0; fi
if [[ "$*" =~ issues/[0-9]+ ]] && [[ "$*" != *"-i"* ]]; then
  echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"","body":""}'; exit 0
fi
if [[ "$*" == *"-i"* ]]; then
  if [[ "$*" == *"repos/example-org/project-5"* ]] && [[ "$*" != *"/"*"/"*"/"* ]]; then
    printf 'HTTP/1.1 200 OK\n\n{"full_name":"example-org/project-5"}\n'; exit 0
  fi
  if [[ "$*" =~ git/ref/heads/ticket/bh-[0-9]+ ]]; then printf 'HTTP/1.1 200 OK\n\n{}\n'; exit 0; fi
  if [[ "$*" == *"pulls?state=open"*"head="* ]]; then printf 'HTTP/1.1 200 OK\n\n[]\n'; exit 0; fi
  printf 'HTTP/1.1 404 Not Found\n\n{}\n'; exit 0
fi
exit 0
GH
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"
printf 'GH_APP_ID=1\n' > "$H/env/github-app.env"
cat > "$H/bin/gh-token.sh" <<'GT'
#!/bin/bash
case " $* " in
  *" --installation-id "*) echo 4242 ;;
  *" --expires-at "*) echo 2026-10-28T05:00:00Z ;;
  *) echo tok-fixture-app ;;
esac
exit 0
GT
chmod +x "$H/bin"/*.sh "$T/fakebin"/*
POOLD="$H/state/fly-pool/project-5"; QD="$H/state/build-queue/project-5"; PD="$H/state/pool/project-5"
run_pool() { # run_pool [VAR=val ...]
  : > "$H/logs/fly-pool.log"; : > "$H/qrow.log"; : > "$T/fly.txt"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
           HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.invalid JOBS_BOX=hub \
           JOBS_RETRIES=0 JOBS_TIMEOUT=5 LANE_REGISTRY="$REG" \
           FLY_API_TOKEN_project-5=tok-fixture-fly FLY_BIN_DIR="$T/fakebin" "$@"
    bash "$DIR/bin/fly-pool.sh" project-5 >/dev/null 2>&1 )
}
reset_case() {
  local p
  for p in "$QD"/* "$QD"/.??* "$POOLD"/*.json "$POOLD"/.??* "$PD"/* "$H/builds"/* "$T/res"/* "$T/brief"/* "$T/pushed"/* \
           "$H/state/settings-cache.json"; do
    [ -e "$p" ] && scratch_rm "$p"
  done
  return 0
}
rows() { # rows <k=v>... -> the settings cache lane_env_apply reads (lane.fly-pool.project-5.<k>)
  local j='{}' kv
  for kv in "$@"; do j=$(jq -c --arg k "lane.fly-pool.project-5.${kv%%=*}" --arg v "${kv#*=}" '. + {($k):$v}' <<<"$j"); done
  jq -n --argjson fa "$(date -u +%s)" --argjson v "$j" '{fetched_at:$fa,values:$v,seeded:{}}' > "$H/state/settings-cache.json"
}
queued() { # queued <key> [extra-json]
  jq -nc --arg k "$1" --argjson x "${2:-{\}}" '{ticket_id:"1",key:$k,attempt:1,deferrals:0,deaths:0,enqueued_at:"2026-10-28T00:00:00Z"} + $x' > "$QD/$1.json"
}
machine() { # machine <mid> <key> <vm_class> <result> [deferrals] [deaths] [attempt]
  # One clock read: spawn_cap_ts and the .spawns line must be the same value.
  local sct; sct=$(( $(date +%s) - 1800 ))
  jq -nc --arg m "$1" --arg k "$2" --arg c "$3" --argjson d "${5:-0}" --argjson x "${6:-0}" --argjson a "${7:-1}" \
    --arg ts "$(date -u -d '30 minutes ago' '+%Y-%m-%d %H:%M:%SZ')" --arg sct "$sct" \
    '{machine:$m,key:$k,ticket_id:"1",attempt:$a,deferrals:$d,deaths:$x,spawned_at:$ts,vm_class:$c,vm_size:"shared-cpu-2x",vm_mem:"4096",spawn_cap_ts:$sct}' > "$POOLD/$1.json"
  printf '%s\nBUILD_DIR: project-5-%s-202610280000\n' "$4" "$2" > "$T/res/$1"
  printf '%s\n' "$sct" > "$PD/$2.spawns"
}
log() { cat "$H/logs/fly-pool.log" 2>/dev/null; }
runline() { grep 'fly machine run' "$T/fly.txt" | head -1; }
